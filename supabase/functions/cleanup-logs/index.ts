import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin } from "../_shared/supabase-client.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Default retention window in days.
 * Rows older than this are eligible for deletion by the `cleanup_old_logs` RPC.
 * Must match the default parameter declared in the SQL function signature so
 * callers that omit the argument get consistent behaviour.
 */
const DEFAULT_RETENTION_DAYS = 7;

/**
 * Service-role key used for the cron gate check.
 * Supabase cron jobs invoke Edge Functions with the service_role key in the
 * `apikey` header; we reject any request that does not supply it.
 */
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface CleanupRpcResult {
  deleted_notification_log_rows: number;
  deleted_event_outbox_rows: number;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight — required even for cron-only functions because Supabase
  // dashboard "Test" calls go through the browser.
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Accept POST (Supabase cron) and GET (manual health-check / dashboard test).
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Service-role gate ---
  // Supabase cron jobs attach the service_role key as the `apikey` header.
  // Reject any request that does not carry the correct key so this function
  // cannot be triggered by arbitrary callers.
  const apikey = req.headers.get("apikey") ?? "";
  if (!apikey || apikey !== SERVICE_ROLE_KEY) {
    console.warn("[cleanup-logs] Rejected request — service_role key missing or invalid");
    return new Response(
      JSON.stringify({ error: "Forbidden" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[cleanup-logs] Starting log cleanup (retention=${DEFAULT_RETENTION_DAYS} days)`
  );

  const supabase = getSupabaseAdmin();

  // --- Call cleanup RPC ---
  // The `cleanup_old_logs` PostgreSQL function deletes rows from
  // `notification_log` and `event_outbox` (completed/failed) that are older
  // than `retention_days` and returns the counts of deleted rows.
  const { data, error } = await supabase.rpc("cleanup_old_logs", {
    retention_days: DEFAULT_RETENTION_DAYS,
  });

  if (error) {
    console.error("[cleanup-logs] RPC cleanup_old_logs failed:", error.message);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // The RPC returns a single row; supabase-js wraps it as an array.
  const result = (Array.isArray(data) ? data[0] : data) as CleanupRpcResult | null;

  const deletedNotificationLogRows = result?.deleted_notification_log_rows ?? 0;
  const deletedEventOutboxRows = result?.deleted_event_outbox_rows ?? 0;
  const totalDeleted = deletedNotificationLogRows + deletedEventOutboxRows;

  console.log(
    `[cleanup-logs] Cleanup complete — ` +
    `notification_log=${deletedNotificationLogRows} ` +
    `event_outbox=${deletedEventOutboxRows} ` +
    `total=${totalDeleted}`
  );

  return new Response(
    JSON.stringify({
      success: true,
      data: {
        retention_days: DEFAULT_RETENTION_DAYS,
        deleted_notification_log_rows: deletedNotificationLogRows,
        deleted_event_outbox_rows: deletedEventOutboxRows,
        total_deleted: totalDeleted,
      },
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
