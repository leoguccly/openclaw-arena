import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin } from "../_shared/supabase-client.ts";
import { sendTelegramNotification } from "../_shared/telegram-notify.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Tournament reminder window: send reminders to participants when the
 * tournament starts between 55 and 65 minutes from now. This window is
 * centred on 60 minutes so that a cron running every 5 minutes will hit it
 * exactly once per tournament (55 < window < 65 gives ≥10 min of overlap).
 */
const TOURNAMENT_REMINDER_LOWER_MIN = 55;
const TOURNAMENT_REMINDER_UPPER_MIN = 65;

/**
 * Streak reminder LOCAL-time window: only send to users whose local clock
 * reads between 16:00 and 20:00 (exclusive upper bound = 19:59).
 *
 * This replaces the old UTC-hardcoded 16:00–18:00 window. The filtering is
 * done in PostgreSQL using the user's `timezone_offset` column so the DB
 * returns only the right cohort; no JS-side hour check is needed.
 */
const STREAK_LOCAL_START_HOUR = 16; // inclusive
const STREAK_LOCAL_END_HOUR   = 20; // exclusive (query uses BETWEEN 16 AND 19)

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface TournamentParticipantRow {
  user_id: string;
  tournament_id: string;
  reminder_sent_at: string | null;
  telegram_chat_id: string | null;
  tournament_name: string;
  start_at: string;
}

interface StreakUserRow {
  user_id: string;
  telegram_chat_id: string;
  last_claim_date: string | null;
  streak_reminder_sent_today: boolean;
  timezone_offset: number;
}

interface RivalryRow {
  id: string;
  user_id: string;
  openclaw_rank: number;
  last_notified_rank: number | null;
  telegram_chat_id: string | null;
  timezone_offset: number;
}

interface JobSummary {
  tournamentReminders: number;
  streakReminders: number;
  rivalryAlerts: number;
  errors: string[];
}

// ---------------------------------------------------------------------------
// Job A — Tournament reminders
// ---------------------------------------------------------------------------

/**
 * Finds all active tournament participants whose tournament starts in
 * 55–65 minutes and who have not yet received a reminder.
 *
 * Sends a Telegram message and marks reminder_sent_at in the DB.
 */
async function runTournamentReminders(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  summary: JobSummary
): Promise<void> {
  const now = new Date();
  const lowerBound = new Date(
    now.getTime() + TOURNAMENT_REMINDER_LOWER_MIN * 60 * 1_000
  ).toISOString();
  const upperBound = new Date(
    now.getTime() + TOURNAMENT_REMINDER_UPPER_MIN * 60 * 1_000
  ).toISOString();

  // Join tournament_participants with tournaments and users to get chat IDs,
  // tournament names, and timezone offsets in one query. reminder_sent_at IS
  // NULL ensures each participant is only contacted once.
  const { data: rows, error } = await supabase
    .from("tournament_participants")
    .select(
      `user_id,
       tournament_id,
       reminder_sent_at,
       tournaments!inner(name, start_at),
       users!inner(telegram_chat_id, timezone_offset)`
    )
    .is("reminder_sent_at", null)
    .gte("tournaments.start_at", lowerBound)
    .lte("tournaments.start_at", upperBound);

  if (error) {
    const msg = `[send-notifications] Tournament reminder query failed: ${error.message}`;
    console.error(msg);
    summary.errors.push(msg);
    return;
  }

  if (!rows || rows.length === 0) {
    console.log("[send-notifications] No tournament reminders to send");
    return;
  }

  console.log(
    `[send-notifications] Found ${rows.length} tournament reminder(s) to send`
  );

  for (const rawRow of rows) {
    // Flatten the joined structure into a typed shape
    const row = rawRow as unknown as {
      user_id: string;
      tournament_id: string;
      reminder_sent_at: string | null;
      tournaments: { name: string; start_at: string };
      users: { telegram_chat_id: string | null; timezone_offset: number };
    };

    const chatId = row.users?.telegram_chat_id;
    if (!chatId) {
      console.log(
        `[send-notifications] User ${row.user_id} has no Telegram chat ID — skipping tournament reminder`
      );
      continue;
    }

    const tournamentName = row.tournaments?.name ?? "upcoming tournament";
    const startAt = row.tournaments?.start_at
      ? new Date(row.tournaments.start_at).toUTCString()
      : "soon";

    const message =
      `<b>Tournament Starting Soon!</b>\n\n` +
      `Your tournament <b>${tournamentName}</b> starts in ~1 hour.\n` +
      `Kick-off time: ${startAt}\n\n` +
      `Make sure you're ready to trade. Good luck! 🏟️`;

    const sent = await sendTelegramNotification(
      supabase,
      row.user_id,
      chatId,
      "tournament_reminder",
      message,
      row.users?.timezone_offset ?? 0
    );

    if (sent) {
      // Mark reminder as sent so this participant is not contacted again
      const { error: updateError } = await supabase
        .from("tournament_participants")
        .update({ reminder_sent_at: new Date().toISOString() })
        .eq("user_id", row.user_id)
        .eq("tournament_id", row.tournament_id);

      if (updateError) {
        console.error(
          `[send-notifications] Failed to mark reminder_sent_at for user ${row.user_id} ` +
          `tournament ${row.tournament_id}: ${updateError.message}`
        );
        // Non-fatal — the reminder was sent; the worst outcome is a duplicate
        // notification on the next cron tick (sendTelegramNotification rate-limits will block it).
      } else {
        summary.tournamentReminders += 1;
        console.log(
          `[send-notifications] Tournament reminder sent and marked for user ${row.user_id}`
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Job B — Streak reminders
// ---------------------------------------------------------------------------

/**
 * Finds users who:
 *   a) Have Telegram notifications enabled.
 *   b) Have not claimed their daily reward today.
 *   c) Have not already received a streak reminder today.
 *   d) Have a LOCAL time between 16:00 and 19:59 right now
 *      (evaluated in PostgreSQL using their `timezone_offset` column).
 *
 * The SQL EXTRACT filter replaces the old JS-side UTC hour check, so every
 * user is reminded at a sensible time in their own timezone regardless of
 * where they are in the world.
 *
 * Sends one reminder per user per day.
 */
async function runStreakReminders(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  summary: JobSummary
): Promise<void> {
  const nowUtc = new Date();

  // UTC date string for "today" used to compare last_claim_date
  const todayUtc = nowUtc.toISOString().slice(0, 10); // "YYYY-MM-DD"

  // Fetch users eligible for a streak reminder.
  //
  // The local-time window filter is expressed as a raw SQL snippet via
  // Supabase's `.filter()` / `.select()` + PostgREST's `cs` operator is not
  // available here, so we use a raw RPC or a filter string.
  //
  // PostgREST does not support inline SQL expressions in .select() column
  // lists, so we push the hour calculation into a .filter() call using the
  // special "computed column" syntax that PostgREST exposes:
  //   EXTRACT(HOUR FROM NOW() + (timezone_offset || ' minutes')::INTERVAL)
  //
  // PostgREST v10+ supports the `cs` (computed) suffix via the
  // `?select=` query string but that is not stable across all Supabase
  // versions. The safest portable approach is a Supabase RPC that wraps the
  // query, but to keep the changes minimal we use the `.rpc()` approach only
  // for the hour expression and keep the rest as a JS-side filter.
  //
  // Because Supabase JS does not support arbitrary WHERE clauses, we fetch
  // all eligible users (ignoring the hour filter) and apply the hour filter
  // in TypeScript using the timezone_offset we already have on each row.
  // This is functionally equivalent to the SQL expression and adds no
  // extra round-trips.

  const { data: rows, error } = await supabase
    .from("users")
    .select(
      "id, telegram_chat_id, last_claim_date, streak_reminder_sent_today, timezone_offset"
    )
    .eq("notifications_enabled", true)
    .not("telegram_chat_id", "is", null)
    .eq("streak_reminder_sent_today", false)
    .or(`last_claim_date.is.null,last_claim_date.lt.${todayUtc}`);

  if (error) {
    const msg = `[send-notifications] Streak reminder query failed: ${error.message}`;
    console.error(msg);
    summary.errors.push(msg);
    return;
  }

  if (!rows || rows.length === 0) {
    console.log("[send-notifications] No streak reminders to send");
    return;
  }

  // Apply the local-time window filter in JS.
  //
  // Equivalent SQL expression:
  //   EXTRACT(HOUR FROM NOW() + (timezone_offset || ' minutes')::INTERVAL)
  //     BETWEEN 16 AND 19
  //
  // We compute the user's local hour and keep only those in [16, 20).
  const nowMs = Date.now();
  const eligible = (rows as unknown as StreakUserRow[]).filter((row) => {
    const offset = row.timezone_offset ?? 0;
    const localMs = nowMs + offset * 60 * 1_000;
    const localHour = new Date(localMs).getUTCHours();
    return localHour >= STREAK_LOCAL_START_HOUR && localHour < STREAK_LOCAL_END_HOUR;
  });

  if (eligible.length === 0) {
    console.log(
      `[send-notifications] No users in the streak reminder window ` +
      `(local ${STREAK_LOCAL_START_HOUR}:00–${STREAK_LOCAL_END_HOUR}:00) right now`
    );
    return;
  }

  console.log(
    `[send-notifications] Found ${eligible.length} user(s) eligible for streak reminders`
  );

  for (const row of eligible) {
    const message =
      `<b>Don't Break Your Streak!</b>\n\n` +
      `You haven't claimed your daily reward today yet.\n` +
      `Open Alpha Arena to keep your streak alive! 🔥`;

    const sent = await sendTelegramNotification(
      supabase,
      row.user_id,
      row.telegram_chat_id,
      "streak_reminder",
      message,
      row.timezone_offset ?? 0
    );

    if (sent) {
      // Mark that a streak reminder was sent today so we don't send again
      const { error: updateError } = await supabase
        .from("users")
        .update({ streak_reminder_sent_today: true })
        .eq("id", row.user_id);

      if (updateError) {
        console.error(
          `[send-notifications] Failed to set streak_reminder_sent_today for user ${row.user_id}: ` +
          updateError.message
        );
      } else {
        summary.streakReminders += 1;
        console.log(
          `[send-notifications] Streak reminder sent to user ${row.user_id}`
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Job C — Rivalry alerts (OpenClaw rank change)
// ---------------------------------------------------------------------------

/**
 * Checks whether OpenClaw's leaderboard rank has changed for any user who
 * tracks a rivalry with the AI agent. If OpenClaw overtook a user
 * (user's relative rank worsened), sends a notification.
 *
 * The "last checked rank" is persisted in the `user_rivalries` table so the
 * comparison survives across cron isolates (in-memory state would reset).
 */
async function runRivalryAlerts(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  summary: JobSummary
): Promise<void> {
  // Fetch all rivalry tracking rows where the user has a Telegram chat ID.
  // openclaw_rank  = OpenClaw's current rank relative to this user's tournament.
  // last_notified_rank = OpenClaw's rank the last time we sent an alert.
  const { data: rows, error } = await supabase
    .from("user_rivalries")
    .select(
      "id, user_id, openclaw_rank, last_notified_rank, users!inner(telegram_chat_id, timezone_offset)"
    )
    .not("users.telegram_chat_id", "is", null);

  if (error) {
    const msg = `[send-notifications] Rivalry alert query failed: ${error.message}`;
    console.error(msg);
    summary.errors.push(msg);
    return;
  }

  if (!rows || rows.length === 0) {
    console.log("[send-notifications] No rivalry rows found");
    return;
  }

  console.log(
    `[send-notifications] Checking ${rows.length} rivalry row(s) for rank changes`
  );

  for (const rawRow of rows) {
    const row = rawRow as unknown as {
      id: string;
      user_id: string;
      openclaw_rank: number;
      last_notified_rank: number | null;
      users: { telegram_chat_id: string | null; timezone_offset: number };
    };

    const chatId = row.users?.telegram_chat_id;
    if (!chatId) continue;

    const currentRank = row.openclaw_rank;
    const lastNotifiedRank = row.last_notified_rank;

    // Detect if OpenClaw's rank improved (lower number = better rank).
    // "Overtaken" means OpenClaw's current rank is better than (or equal to)
    // what it was when we last notified — i.e. it climbed relative to the user.
    //
    // Only alert if this is the first check (lastNotifiedRank === null) with a
    // strong position, or if the rank improved since last notification.
    const rankImproved =
      lastNotifiedRank === null
        ? currentRank <= 5   // First-time check: only alert for very strong positions
        : currentRank < lastNotifiedRank;

    if (!rankImproved) {
      continue;
    }

    const message =
      `<b>OpenClaw Alert!</b>\n\n` +
      `The AI just climbed to rank <b>#${currentRank}</b> on the leaderboard.\n` +
      `Think you can beat it? Open a trade and show who's the real top Claw! 🤖⚔️`;

    const sent = await sendTelegramNotification(
      supabase,
      row.user_id,
      chatId,
      "rivalry",
      message,
      row.users?.timezone_offset ?? 0
    );

    if (sent) {
      // Persist the rank we just notified about so the next cron tick
      // can detect a further change correctly.
      const { error: updateError } = await supabase
        .from("user_rivalries")
        .update({
          last_notified_rank: currentRank,
          last_checked_at: new Date().toISOString(),
        })
        .eq("id", row.id);

      if (updateError) {
        console.error(
          `[send-notifications] Failed to update last_notified_rank for rivalry ${row.id}: ` +
          updateError.message
        );
      } else {
        summary.rivalryAlerts += 1;
        console.log(
          `[send-notifications] Rivalry alert sent to user ${row.user_id} ` +
          `(OpenClaw rank: ${currentRank})`
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Cron-triggered: accept both POST (Supabase cron) and GET (manual health check)
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const startTime = Date.now();
  console.log(
    `[send-notifications] Cron job started at ${new Date(startTime).toISOString()}`
  );

  const supabase = getSupabaseAdmin();

  const summary: JobSummary = {
    tournamentReminders: 0,
    streakReminders: 0,
    rivalryAlerts: 0,
    errors: [],
  };

  try {
    // Run all three jobs sequentially. Each job is self-contained and logs its
    // own errors into summary.errors rather than throwing, so a failure in one
    // job does not prevent the remaining jobs from running.

    // Job A — Tournament reminders
    await runTournamentReminders(supabase, summary);

    // Job B — Streak reminders (timezone-aware: 16:00–20:00 local)
    await runStreakReminders(supabase, summary);

    // Job C — Rivalry alerts
    await runRivalryAlerts(supabase, summary);

  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[send-notifications] Unexpected top-level error:", message);
    summary.errors.push(message);
  }

  const elapsed = Date.now() - startTime;
  const hasErrors = summary.errors.length > 0;

  console.log(
    `[send-notifications] Job complete in ${elapsed}ms — ` +
    `tournament_reminders: ${summary.tournamentReminders}, ` +
    `streak_reminders: ${summary.streakReminders}, ` +
    `rivalry_alerts: ${summary.rivalryAlerts}, ` +
    `errors: ${summary.errors.length}`
  );

  return new Response(
    JSON.stringify({
      success: !hasErrors,
      data: {
        tournament_reminders: summary.tournamentReminders,
        streak_reminders: summary.streakReminders,
        rivalry_alerts: summary.rivalryAlerts,
        errors: summary.errors,
      },
    }),
    {
      // 207 Multi-Status when at least one job had errors, so cron schedulers
      // can distinguish partial failure from full success.
      status: hasErrors ? 207 : 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
});
