import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin } from "../_shared/supabase-client.ts";
import { sendTelegramNotification } from "../_shared/telegram-notify.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Maximum number of outbox rows to process per invocation.
 * Keeping this small bounds per-invocation latency and avoids timeout risks
 * on functions that run every 30 seconds.
 */
const BATCH_SIZE = 10;

/**
 * Service-role key used to authenticate the internal call to check-achievements.
 * The function validates apikey === SUPABASE_SERVICE_ROLE_KEY.
 */
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface OutboxRow {
  id: string;
  event_type: "check_achievements" | "send_notification";
  payload: Record<string, unknown>;
  attempts: number;
  max_attempts: number;
}

interface ProcessSummary {
  processed: number;
  completed: number;
  failed_permanently: number;
  retrying: number;
  errors: string[];
}

// ---------------------------------------------------------------------------
// Dispatcher: check_achievements
// ---------------------------------------------------------------------------

/**
 * Calls the check-achievements Edge Function with the payload from the outbox
 * row. Uses the service_role key in the apikey header, which is the
 * authentication mechanism expected by that function's service-role gate.
 *
 * Throws on non-2xx responses so the caller can record the failure and
 * decide whether to retry.
 */
async function dispatchCheckAchievements(
  payload: Record<string, unknown>
): Promise<void> {
  const url = `${SUPABASE_URL}/functions/v1/check-achievements`;

  console.log(
    `[process-outbox] Dispatching check_achievements: ` +
    `user=${payload.user_id} trigger=${payload.trigger_event}`
  );

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      // check-achievements validates that apikey === SUPABASE_SERVICE_ROLE_KEY
      "apikey": SERVICE_ROLE_KEY,
      "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "(unreadable)");
    throw new Error(
      `check-achievements returned HTTP ${res.status}: ${body}`
    );
  }

  const json = await res.json().catch(() => null);
  console.log(
    `[process-outbox] check_achievements completed for user=${payload.user_id} ` +
    `newly_earned=${JSON.stringify(
      (json as { data?: { newly_earned?: unknown[] } } | null)?.data?.newly_earned ?? []
    )}`
  );
}

// ---------------------------------------------------------------------------
// Dispatcher: send_notification
// ---------------------------------------------------------------------------

/**
 * Delivers a Telegram notification described by the outbox row's payload.
 *
 * Expected payload fields (all written by `checkPriceAlerts` in
 * manage-price-alerts/index.ts):
 *
 *   chat_id           {string}  — Telegram chat ID of the recipient
 *   user_id           {string}  — Supabase user UUID (for rate-limit checks)
 *   message           {string}  — Pre-formatted HTML message body
 *   notification_type {string}  — e.g. "price_alert"
 *   timezone_offset   {number}  — User's UTC offset in minutes (for quiet hours)
 *
 * The function calls `sendTelegramNotification` directly rather than
 * forwarding to another Edge Function, eliminating an extra HTTP hop on the
 * critical notification path.
 *
 * Rate limiting and quiet-hours enforcement are handled inside
 * `sendTelegramNotification` — if the notification is gated, the function
 * returns false but does NOT throw. We treat a skipped notification as a
 * successful dispatch (no retry) because the gate is intentional, and
 * retrying would just hit the same gate again until the row permanently fails.
 *
 * Throws only on hard errors (missing required payload fields) so the outbox
 * state machine can decide whether to retry.
 */
async function dispatchSendNotification(
  payload: Record<string, unknown>
): Promise<void> {
  const chatId = typeof payload.chat_id === "string" ? payload.chat_id : null;
  const userId = typeof payload.user_id === "string" ? payload.user_id : null;
  const message = typeof payload.message === "string" ? payload.message : null;
  const notificationType =
    typeof payload.notification_type === "string"
      ? payload.notification_type
      : "price_alert";
  const timezoneOffset =
    typeof payload.timezone_offset === "number" ? payload.timezone_offset : 0;

  if (!chatId || !userId || !message) {
    throw new Error(
      `send_notification payload missing required fields — ` +
      `chat_id=${chatId ?? "MISSING"} user_id=${userId ?? "MISSING"} ` +
      `message=${message ? "(present)" : "MISSING"}`
    );
  }

  console.log(
    `[process-outbox] Dispatching send_notification: ` +
    `user=${userId} type=${notificationType} chat=${chatId}`
  );

  const supabase = getSupabaseAdmin();

  const sent = await sendTelegramNotification(
    supabase,
    userId,
    chatId,
    notificationType,
    message,
    timezoneOffset
  );

  if (sent) {
    console.log(
      `[process-outbox] send_notification delivered: user=${userId} type=${notificationType}`
    );
  } else {
    // Rate-limited or quiet hours — log but do not throw so the outbox row is
    // marked completed rather than retried (the gate would block it again).
    console.log(
      `[process-outbox] send_notification skipped (rate-limited or quiet hours): ` +
      `user=${userId} type=${notificationType}`
    );
  }
}

// ---------------------------------------------------------------------------
// Dispatch table
// ---------------------------------------------------------------------------

const DISPATCHERS: Record<
  OutboxRow["event_type"],
  (payload: Record<string, unknown>) => Promise<void>
> = {
  check_achievements: dispatchCheckAchievements,
  send_notification:  dispatchSendNotification,
};

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 1. Service-role gate ---
  // process-outbox is triggered by a Supabase cron job using the service_role
  // key. Reject any request that does not supply it.
  const apikey = req.headers.get("apikey") ?? "";
  if (!apikey || apikey !== SERVICE_ROLE_KEY) {
    console.warn("[process-outbox] Rejected request — service_role key missing or invalid");
    return new Response(
      JSON.stringify({ error: "Forbidden" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log("[process-outbox] Starting outbox processing cycle");

  const supabase = getSupabaseAdmin();

  const summary: ProcessSummary = {
    processed: 0,
    completed: 0,
    failed_permanently: 0,
    retrying: 0,
    errors: [],
  };

  // --- 2. Claim a batch of pending rows ---
  // We SELECT the rows, then immediately UPDATE each one to 'processing' in a
  // separate statement. This is not a true atomic claim (that would require a
  // CTE with UPDATE … RETURNING in raw SQL), but it is safe enough for a
  // single-instance cron with a 30-second interval: even if two invocations
  // overlap, the worst outcome is duplicate dispatch of idempotent functions.
  // check-achievements uses ON CONFLICT DO NOTHING for award inserts, making
  // double-dispatch harmless.
  const { data: pendingRows, error: fetchError } = await supabase
    .from("event_outbox")
    .select("id, event_type, payload, attempts, max_attempts")
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(BATCH_SIZE);

  if (fetchError) {
    console.error("[process-outbox] Failed to fetch pending rows:", fetchError.message);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const rows = (pendingRows ?? []) as OutboxRow[];

  if (rows.length === 0) {
    console.log("[process-outbox] No pending events — nothing to do");
    return new Response(
      JSON.stringify({ success: true, data: summary }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[process-outbox] Claimed ${rows.length} pending row(s)`);

  // --- 3. Mark each row as 'processing' before dispatching ---
  // This is an optimistic lock: if the cron overlaps (rare), the second
  // invocation will also claim and dispatch, but the downstream functions
  // are idempotent so the duplicate is harmless.
  const rowIds = rows.map((r) => r.id);
  await supabase
    .from("event_outbox")
    .update({ status: "processing" })
    .in("id", rowIds);

  // --- 4. Dispatch each row ---
  for (const row of rows) {
    summary.processed++;

    const dispatcher = DISPATCHERS[row.event_type];
    if (!dispatcher) {
      // Unknown event_type — this should not happen given the CHECK constraint,
      // but guard defensively. Mark failed immediately (no retry useful).
      const errMsg = `Unknown event_type: ${row.event_type}`;
      console.error(`[process-outbox] Row ${row.id}: ${errMsg}`);
      summary.errors.push(`${row.id}: ${errMsg}`);

      await supabase
        .from("event_outbox")
        .update({
          status: "failed",
          attempts: row.attempts + 1,
          error_message: errMsg,
        })
        .eq("id", row.id);

      summary.failed_permanently++;
      continue;
    }

    try {
      await dispatcher(row.payload);

      // Success: mark completed
      await supabase
        .from("event_outbox")
        .update({
          status: "completed",
          attempts: row.attempts + 1,
          processed_at: new Date().toISOString(),
          error_message: null,
        })
        .eq("id", row.id);

      console.log(`[process-outbox] Row ${row.id} (${row.event_type}) completed`);
      summary.completed++;

    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      const newAttempts = row.attempts + 1;

      console.error(
        `[process-outbox] Row ${row.id} (${row.event_type}) dispatch failed ` +
        `(attempt ${newAttempts}/${row.max_attempts}): ${message}`
      );

      summary.errors.push(`${row.id}: ${message}`);

      if (newAttempts >= row.max_attempts) {
        // Exhausted retries — mark as permanently failed for alerting/replay
        await supabase
          .from("event_outbox")
          .update({
            status: "failed",
            attempts: newAttempts,
            error_message: message,
          })
          .eq("id", row.id);

        console.error(
          `[process-outbox] Row ${row.id} permanently failed after ${newAttempts} attempt(s)`
        );
        summary.failed_permanently++;
      } else {
        // Reset to 'pending' so the next cron cycle retries
        await supabase
          .from("event_outbox")
          .update({
            status: "pending",
            attempts: newAttempts,
            error_message: message,
          })
          .eq("id", row.id);

        console.log(
          `[process-outbox] Row ${row.id} reset to pending for retry ` +
          `(${newAttempts}/${row.max_attempts} attempts used)`
        );
        summary.retrying++;
      }
    }
  }

  console.log(
    `[process-outbox] Cycle complete — ` +
    `processed=${summary.processed} ` +
    `completed=${summary.completed} ` +
    `retrying=${summary.retrying} ` +
    `permanently_failed=${summary.failed_permanently}`
  );

  return new Response(
    JSON.stringify({ success: true, data: summary }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
