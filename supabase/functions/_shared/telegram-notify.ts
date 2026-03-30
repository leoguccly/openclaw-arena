import { getSupabaseAdmin } from "./supabase-client.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN");

const TELEGRAM_API_BASE = "https://api.telegram.org";

/**
 * Per-type notification quotas and priority tiers.
 *
 * Tier 1 — Critical: independent quota; NOT subject to the global daily cap.
 *           These notifications must reach the user even when lower-priority
 *           types have already consumed most of the global budget.
 *
 * Tier 2 — Engagement: standard quota; subject to global caps.
 *
 * Tier 3 — Nudge: lowest priority; subject to global caps and dropped first
 *           when any cap is reached.
 */
const NOTIFICATION_TIERS = {
  liquidation:          { max_per_hour: 2, max_per_day: 10, tier: 1 },
  tournament_reminder:  { max_per_hour: 2, max_per_day: 4,  tier: 1 },

  rivalry:              { max_per_hour: 1, max_per_day: 2,  tier: 2 },
  achievement:          { max_per_hour: 1, max_per_day: 3,  tier: 2 },

  streak_reminder:      { max_per_hour: 1, max_per_day: 1,  tier: 3 },
} as const;

type NotificationType = keyof typeof NOTIFICATION_TIERS;

/**
 * Global caps applied on top of per-type limits.
 * Tier 1 notifications bypass the global DAILY cap but still respect the
 * global HOURLY cap (to prevent burst spam even for critical events).
 */
const GLOBAL_MAX_PER_HOUR = 3;
const GLOBAL_MAX_PER_DAY = 8;

/** Minimum gap (ms) that must have elapsed since the last sent message. */
const MIN_GAP_MS = 10 * 60 * 1_000; // 10 minutes

/**
 * Quiet hours in the user's LOCAL time: 00:00–08:00.
 * Notifications are blocked during this window to avoid disturbing users.
 */
const QUIET_HOUR_START = 0;  // inclusive
const QUIET_HOUR_END   = 8;  // exclusive

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface NotificationPayload {
  chat_id: string;
  message: string;
  parse_mode?: "HTML" | "MarkdownV2";
}

interface NotificationLogRow {
  sent_at: string;
  notification_type: string;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Resolves the per-type config for a given notification type.
 * Falls back to a permissive Tier 2 config for unknown types so that new
 * notification types are never silently dropped before their config is added.
 */
function getTierConfig(notificationType: string): {
  max_per_hour: number;
  max_per_day: number;
  tier: number;
} {
  if (notificationType in NOTIFICATION_TIERS) {
    return NOTIFICATION_TIERS[notificationType as NotificationType];
  }
  // Unknown type: treat as Tier 2 with conservative defaults
  console.log(
    `[telegram-notify] Unknown notification type "${notificationType}" — using Tier 2 defaults`
  );
  return { max_per_hour: 1, max_per_day: 3, tier: 2 };
}

/**
 * Returns true if the user's local hour falls inside quiet hours (00:00–08:00).
 *
 * @param timezoneOffsetMinutes - The user's UTC offset in minutes
 *   (positive = east, e.g. +480 for UTC+8; negative = west, e.g. -300 for UTC-5).
 */
function isQuietHours(timezoneOffsetMinutes: number): boolean {
  const nowUtcMs = Date.now();
  const localMs = nowUtcMs + timezoneOffsetMinutes * 60 * 1_000;
  // Derive the local hour from the offset-adjusted timestamp
  const localHour = new Date(localMs).getUTCHours();
  return localHour >= QUIET_HOUR_START && localHour < QUIET_HOUR_END;
}

// ---------------------------------------------------------------------------
// Rate-limit check — queries notification_log
// ---------------------------------------------------------------------------

/**
 * Checks whether a notification of `notificationType` may be sent to `userId`.
 *
 * Gate order (all must pass):
 *   1. Per-type hourly cap    — counted from notification_log filtered by type.
 *   2. Per-type daily cap     — counted from notification_log filtered by type.
 *   3. Global hourly cap      — counted across all types.
 *   4. Global daily cap       — counted across all types (SKIPPED for Tier 1).
 *   5. Minimum gap            — time elapsed since the user's last notification (any type).
 *   6. Quiet hours            — derived from the user's timezone_offset column.
 *
 * Returns true if the notification may be sent, false if it should be dropped.
 */
async function canSendNotification(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  notificationType: string,
  timezoneOffsetMinutes: number
): Promise<boolean> {
  const config = getTierConfig(notificationType);
  const now = Date.now();
  const oneHourAgo = new Date(now - 60 * 60 * 1_000).toISOString();
  const oneDayAgo  = new Date(now - 24 * 60 * 60 * 1_000).toISOString();

  // ── Fetch all of the user's notifications from the last 24 h in one query ──
  // We need both type-specific and global counts, so fetching all rows for the
  // last day and filtering in memory saves us multiple round-trips.
  const { data: recentRows, error } = await supabase
    .from("notification_log")
    .select("sent_at, notification_type")
    .eq("user_id", userId)
    .gte("sent_at", oneDayAgo)
    .order("sent_at", { ascending: false });

  if (error) {
    // Fail open: better to let a message through than to permanently silence a
    // user because of a DB connectivity issue.
    console.error(
      `[telegram-notify] canSendNotification DB error for user ${userId}:`,
      error.message
    );
    return true;
  }

  const rows = (recentRows ?? []) as NotificationLogRow[];

  // Split into type-specific and global slices --------------------------------
  const typeRows = rows.filter((r) => r.notification_type === notificationType);
  const typeRowsLastHour = typeRows.filter(
    (r) => new Date(r.sent_at).getTime() >= now - 60 * 60 * 1_000
  );
  const globalRowsLastHour = rows.filter(
    (r) => new Date(r.sent_at).getTime() >= now - 60 * 60 * 1_000
  );

  // ── Gate 1: per-type hourly cap ────────────────────────────────────────────
  if (typeRowsLastHour.length >= config.max_per_hour) {
    console.log(
      `[telegram-notify] User ${userId} rate-limited: per-type hourly cap for ` +
      `"${notificationType}" (${config.max_per_hour}/h) reached`
    );
    return false;
  }

  // ── Gate 2: per-type daily cap ─────────────────────────────────────────────
  if (typeRows.length >= config.max_per_day) {
    console.log(
      `[telegram-notify] User ${userId} rate-limited: per-type daily cap for ` +
      `"${notificationType}" (${config.max_per_day}/d) reached`
    );
    return false;
  }

  // ── Gate 3: global hourly cap ──────────────────────────────────────────────
  if (globalRowsLastHour.length >= GLOBAL_MAX_PER_HOUR) {
    console.log(
      `[telegram-notify] User ${userId} rate-limited: global hourly cap ` +
      `(${GLOBAL_MAX_PER_HOUR}/h) reached`
    );
    return false;
  }

  // ── Gate 4: global daily cap (Tier 1 bypasses this) ───────────────────────
  if (config.tier > 1 && rows.length >= GLOBAL_MAX_PER_DAY) {
    console.log(
      `[telegram-notify] User ${userId} rate-limited: global daily cap ` +
      `(${GLOBAL_MAX_PER_DAY}/d) reached — "${notificationType}" is Tier ${config.tier}`
    );
    return false;
  }

  // ── Gate 5: minimum gap between any two notifications ──────────────────────
  if (rows.length > 0) {
    const lastSentAt = new Date(rows[0].sent_at).getTime();
    if (now - lastSentAt < MIN_GAP_MS) {
      console.log(
        `[telegram-notify] User ${userId} rate-limited: minimum gap (10 min) not elapsed`
      );
      return false;
    }
  }

  // ── Gate 6: quiet hours in user's local time ──────────────────────────────
  if (isQuietHours(timezoneOffsetMinutes)) {
    const localMs = now + timezoneOffsetMinutes * 60 * 1_000;
    const localHour = new Date(localMs).getUTCHours();
    console.log(
      `[telegram-notify] User ${userId} is in quiet hours ` +
      `(local hour: ${localHour}, offset: ${timezoneOffsetMinutes} min) — skipping`
    );
    return false;
  }

  return true;
}

// ---------------------------------------------------------------------------
// Telegram API call
// ---------------------------------------------------------------------------

async function postToTelegram(payload: NotificationPayload): Promise<boolean> {
  if (!BOT_TOKEN) {
    console.error("[telegram-notify] TELEGRAM_BOT_TOKEN env var is not set");
    return false;
  }

  const url = `${TELEGRAM_API_BASE}/bot${BOT_TOKEN}/sendMessage`;

  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: payload.chat_id,
        text: payload.message,
        parse_mode: payload.parse_mode ?? "HTML",
      }),
      signal: AbortSignal.timeout(8_000),
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[telegram-notify] Telegram API fetch failed: ${message}`);
    return false;
  }

  if (!response.ok) {
    const body = await response.text().catch(() => "(unreadable)");
    console.error(
      `[telegram-notify] Telegram API returned HTTP ${response.status}: ${body}`
    );
    return false;
  }

  return true;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Sends a Telegram message to `chatId` on behalf of `userId`.
 *
 * The function is fire-and-forget by design:
 *   - It never throws.
 *   - All errors are swallowed after being logged.
 *   - Rate limits are enforced per-type and globally before sending.
 *   - Quiet hours are respected using the caller-supplied timezone offset.
 *   - Successful sends are recorded in notification_log for future checks.
 *
 * @param timezoneOffsetMinutes - The user's UTC offset in minutes.
 *   Pass 0 if unknown; quiet-hour logic will then operate in UTC.
 *
 * Returns true if the message was dispatched, false if it was skipped or failed.
 */
export async function sendTelegramNotification(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  chatId: string,
  notificationType: string,
  message: string,
  timezoneOffsetMinutes = 0
): Promise<boolean> {
  try {
    // --- Rate-limit and quiet-hours gate ---
    const allowed = await canSendNotification(
      supabase,
      userId,
      notificationType,
      timezoneOffsetMinutes
    );
    if (!allowed) {
      return false;
    }

    // --- Send via Telegram Bot API ---
    const sent = await postToTelegram({ chat_id: chatId, message });
    if (!sent) {
      return false;
    }

    // --- Log the successful send ---
    const { error: logError } = await supabase.from("notification_log").insert({
      user_id: userId,
      notification_type: notificationType,
      payload: { chat_id: chatId, message },
      sent_at: new Date().toISOString(),
      delivered: true,
    });

    if (logError) {
      // Non-fatal: the message was already sent; a missing log row only
      // affects future rate-limit accuracy. Log and continue.
      console.error(
        `[telegram-notify] Failed to write notification_log for user ${userId}:`,
        logError.message
      );
    }

    console.log(
      `[telegram-notify] Sent ${notificationType} notification to user ${userId} (chat ${chatId})`
    );
    return true;
  } catch (err: unknown) {
    // Top-level safety net — this function must never propagate an exception.
    const msg = err instanceof Error ? err.message : String(err);
    console.error(
      `[telegram-notify] Unexpected error for user ${userId}:`,
      msg
    );
    return false;
  }
}
