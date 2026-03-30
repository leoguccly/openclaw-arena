import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Maximum number of active price alerts a single user may hold at one time. */
const MAX_ACTIVE_ALERTS = 5;

/** Symbols we accept for price alerts — must match the trading symbol allowlist. */
const ALLOWED_SYMBOLS = new Set(["BTC/USDT", "ETH/USDT"]);

/** Alert direction values. */
const ALLOWED_DIRECTIONS = new Set(["above", "below"]);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type AlertDirection = "above" | "below";

interface PriceAlertRow {
  id: string;
  user_id: string;
  symbol: string;
  direction: AlertDirection;
  target_price: number;
  is_active: boolean;
  created_at: string;
  triggered_at: string | null;
}

interface CreateAlertRequest {
  symbol: string;
  direction: AlertDirection;
  target_price: number;
}

// ---------------------------------------------------------------------------
// Exported price alert checker — imported by scan-liquidations
// ---------------------------------------------------------------------------

/**
 * Scans active price alerts for `symbol` that are breached by `currentPrice`,
 * deactivates each one with an optimistic lock, then enqueues a
 * `send_notification` event in `event_outbox` for every triggered alert.
 *
 * No Telegram API calls are made inline. The `process-outbox` cron (runs every
 * 30 seconds) drains the outbox and delivers the actual notifications.
 *
 * Query strategy: instead of fetching all active alerts and filtering in
 * application code, we issue two index-friendly queries — one per direction —
 * so only already-breached rows are returned.
 *
 *   "above" alerts: target_price <= currentPrice  (price rose past target)
 *   "below" alerts: target_price >= currentPrice  (price fell past target)
 *
 * This keeps the fetch set minimal and takes advantage of a composite index on
 * (symbol, direction, target_price, is_active).
 *
 * Idempotency guarantee: the UPDATE uses WHERE is_active = TRUE so that a
 * concurrent execution of scan-liquidations cannot double-trigger the same
 * alert. Only the execution that successfully flips is_active to FALSE will
 * proceed to insert an outbox row.
 *
 * @param supabase     - Admin Supabase client (service_role)
 * @param symbol       - Display symbol, e.g. "BTC/USDT"
 * @param currentPrice - The current market price for the symbol
 * @returns An object reporting how many alerts were staged and any errors.
 */
export async function checkPriceAlerts(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  symbol: string,
  currentPrice: number
): Promise<{ triggered: number; errors: string[] }> {
  const errors: string[] = [];
  let triggered = 0;

  // --- 1. Fetch only alerts whose price condition is already met ---
  // Two targeted queries avoid scanning every active alert for the symbol.

  const [aboveResult, belowResult] = await Promise.all([
    // "above" alert fires when price >= target → fetch rows where target <= currentPrice
    supabase
      .from("price_alerts")
      .select("id, user_id, symbol, direction, target_price")
      .eq("symbol", symbol)
      .eq("direction", "above")
      .eq("is_active", true)
      .lte("target_price", currentPrice),

    // "below" alert fires when price <= target → fetch rows where target >= currentPrice
    supabase
      .from("price_alerts")
      .select("id, user_id, symbol, direction, target_price")
      .eq("symbol", symbol)
      .eq("direction", "below")
      .eq("is_active", true)
      .gte("target_price", currentPrice),
  ]);

  if (aboveResult.error) {
    const msg = `Failed to fetch "above" price_alerts for ${symbol}: ${aboveResult.error.message}`;
    console.error(`[manage-price-alerts] ${msg}`);
    errors.push(msg);
  }

  if (belowResult.error) {
    const msg = `Failed to fetch "below" price_alerts for ${symbol}: ${belowResult.error.message}`;
    console.error(`[manage-price-alerts] ${msg}`);
    errors.push(msg);
  }

  // Abort early if both queries failed
  if (aboveResult.error && belowResult.error) {
    return { triggered, errors };
  }

  const breachedAlerts: PriceAlertRow[] = [
    ...((aboveResult.data ?? []) as PriceAlertRow[]),
    ...((belowResult.data ?? []) as PriceAlertRow[]),
  ];

  if (breachedAlerts.length === 0) {
    return { triggered, errors };
  }

  console.log(
    `[manage-price-alerts] ${breachedAlerts.length} breached alert(s) for ` +
    `${symbol} @ ${currentPrice} — staging outbox entries`
  );

  // --- 2. Deactivate each breached alert and insert an outbox event ---
  const triggeredAt = new Date().toISOString();

  for (const alert of breachedAlerts) {
    const targetPrice = parseFloat(String(alert.target_price));

    // --- 2a. Optimistic lock: deactivate only if still active ---
    // Concurrent scan-liquidations invocations may race here. Only the
    // execution that wins the UPDATE (rowsAffected > 0) should proceed.
    const { data: updateData, error: updateError } = await supabase
      .from("price_alerts")
      .update({ is_active: false, triggered_at: triggeredAt })
      .eq("id", alert.id)
      .eq("is_active", true)   // optimistic lock
      .select("id")
      .maybeSingle();

    if (updateError) {
      const msg =
        `Failed to deactivate alert ${alert.id} for user ${alert.user_id}: ${updateError.message}`;
      console.error(`[manage-price-alerts] ${msg}`);
      errors.push(msg);
      continue;
    }

    if (!updateData) {
      // Another concurrent execution won the race — this alert is already
      // deactivated. The outbox row will be inserted by that execution.
      console.log(
        `[manage-price-alerts] Alert ${alert.id} already deactivated by concurrent execution — skipping`
      );
      continue;
    }

    // --- 2b. Fetch user notification preferences for the outbox payload ---
    // We look up the user here so process-outbox can send the notification
    // without an additional DB round-trip.
    const { data: userData, error: userError } = await supabase
      .from("users")
      .select("telegram_chat_id, timezone_offset, display_name")
      .eq("id", alert.user_id)
      .maybeSingle<{ telegram_chat_id: string | null; timezone_offset: number | null; display_name: string | null }>();

    if (userError) {
      const msg =
        `Failed to fetch user ${alert.user_id} for alert ${alert.id}: ${userError.message}`;
      console.error(`[manage-price-alerts] ${msg}`);
      errors.push(msg);
      // Alert is already deactivated — log the error but do not re-activate.
      // A missing outbox row means the user won't receive a notification, which
      // is preferable to sending a duplicate on a future retry.
      continue;
    }

    if (!userData?.telegram_chat_id) {
      console.log(
        `[manage-price-alerts] User ${alert.user_id} has no telegram_chat_id — ` +
        `alert ${alert.id} deactivated but no outbox entry inserted`
      );
      triggered++;
      continue;
    }

    // --- 2c. Build the notification message ---
    const directionEmoji = alert.direction === "above" ? "📈" : "📉";
    const directionLabel = alert.direction === "above" ? "rose above" : "fell below";
    const displayName = userData.display_name ?? "Trader";
    const timezoneOffset = userData.timezone_offset ?? 0;

    const message =
      `${directionEmoji} <b>Price Alert Triggered</b>\n\n` +
      `Hey ${displayName}!\n\n` +
      `<b>${symbol}</b> has ${directionLabel} your target price of ` +
      `<b>${targetPrice.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDT</b>.\n\n` +
      `Current price: <b>${currentPrice.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDT</b>\n\n` +
      `<i>This alert has been deactivated. Set a new one to keep tracking.</i>`;

    // --- 2d. Insert outbox event — NO inline TG call ---
    const { error: outboxError } = await supabase
      .from("event_outbox")
      .insert({
        event_type: "send_notification",
        payload: {
          user_id: alert.user_id,
          chat_id: userData.telegram_chat_id,
          notification_type: "price_alert",
          message,
          timezone_offset: timezoneOffset,
          // Metadata for observability / debugging
          alert_id: alert.id,
          symbol,
          direction: alert.direction,
          target_price: targetPrice,
          current_price: currentPrice,
          triggered_at: triggeredAt,
        },
      });

    if (outboxError) {
      const msg =
        `Failed to insert outbox entry for alert ${alert.id}: ${outboxError.message}`;
      console.error(`[manage-price-alerts] ${msg}`);
      errors.push(msg);
      // Alert is already deactivated. A missing outbox row is still better than
      // an unhandled duplicate notification.
      continue;
    }

    triggered++;
    console.log(
      `[manage-price-alerts] Alert ${alert.id} staged in outbox | ` +
      `user=${alert.user_id} | ${symbol} ${alert.direction} ${targetPrice} | ` +
      `currentPrice=${currentPrice}`
    );
  }

  console.log(
    `[manage-price-alerts] checkPriceAlerts complete for ${symbol} | ` +
    `triggered=${triggered} errors=${errors.length}`
  );

  return { triggered, errors };
}

// ---------------------------------------------------------------------------
// CRUD handlers
// ---------------------------------------------------------------------------

/**
 * GET — list the authenticated user's active price alerts.
 */
async function handleGet(
  req: Request,
  userId: string,
  supabase: ReturnType<typeof getSupabaseAdmin>
): Promise<Response> {
  const { data, error } = await supabase
    .from("price_alerts")
    .select("id, symbol, direction, target_price, is_active, created_at, triggered_at")
    .eq("user_id", userId)
    .eq("is_active", true)
    .order("created_at", { ascending: false });

  if (error) {
    console.error(
      `[manage-price-alerts] GET failed for user ${userId}:`,
      error.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const alerts = (data ?? []) as PriceAlertRow[];

  console.log(`[manage-price-alerts] GET user ${userId} — ${alerts.length} active alert(s)`);

  // req is unused in this handler but included to keep the signature uniform
  void req;

  return new Response(
    JSON.stringify({ success: true, data: { alerts } }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}

/**
 * POST — create a new price alert for the authenticated user.
 */
async function handlePost(
  req: Request,
  userId: string,
  supabase: ReturnType<typeof getSupabaseAdmin>
): Promise<Response> {
  // --- Parse body ---
  let body: CreateAlertRequest;
  try {
    body = await req.json() as CreateAlertRequest;
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Validate symbol ---
  if (!body.symbol || typeof body.symbol !== "string") {
    return new Response(
      JSON.stringify({ error: "symbol is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const symbol = body.symbol.toUpperCase().trim();

  if (!ALLOWED_SYMBOLS.has(symbol)) {
    return new Response(
      JSON.stringify({
        error: `symbol must be one of: ${[...ALLOWED_SYMBOLS].join(", ")}`,
      }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Validate direction ---
  if (!body.direction || typeof body.direction !== "string") {
    return new Response(
      JSON.stringify({ error: "direction is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!ALLOWED_DIRECTIONS.has(body.direction)) {
    return new Response(
      JSON.stringify({
        error: `direction must be one of: ${[...ALLOWED_DIRECTIONS].join(", ")}`,
      }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Validate target_price ---
  if (body.target_price === undefined || body.target_price === null) {
    return new Response(
      JSON.stringify({ error: "target_price is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const targetPrice = parseFloat(String(body.target_price));

  if (isNaN(targetPrice) || targetPrice <= 0) {
    return new Response(
      JSON.stringify({ error: "target_price must be a positive number" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Check max active alert limit ---
  const { count, error: countError } = await supabase
    .from("price_alerts")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("is_active", true);

  if (countError) {
    console.error(
      `[manage-price-alerts] POST count query failed for user ${userId}:`,
      countError.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if ((count ?? 0) >= MAX_ACTIVE_ALERTS) {
    return new Response(
      JSON.stringify({
        error: `Maximum of ${MAX_ACTIVE_ALERTS} active alerts allowed. Please delete an existing alert first.`,
      }),
      { status: 422, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Insert the alert ---
  const { data: insertData, error: insertError } = await supabase
    .from("price_alerts")
    .insert({
      user_id: userId,
      symbol,
      direction: body.direction,
      target_price: targetPrice,
      is_active: true,
    })
    .select("id, symbol, direction, target_price, is_active, created_at, triggered_at")
    .single();

  if (insertError) {
    console.error(
      `[manage-price-alerts] POST insert failed for user ${userId}:`,
      insertError.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[manage-price-alerts] POST user ${userId} — created alert ${insertData.id} | ` +
    `${symbol} ${body.direction} ${targetPrice}`
  );

  return new Response(
    JSON.stringify({ success: true, data: { alert: insertData } }),
    { status: 201, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}

/**
 * DELETE — deactivate a price alert by ID for the authenticated user.
 * Uses soft-delete (is_active = false) rather than physical DELETE so that
 * triggered alert history is preserved.
 */
async function handleDelete(
  req: Request,
  userId: string,
  supabase: ReturnType<typeof getSupabaseAdmin>
): Promise<Response> {
  // Extract alert ID from URL path OR request body (frontend sends it in body).
  const url = new URL(req.url);
  const pathParts = url.pathname.split("/").filter(Boolean);
  let alertId = pathParts[pathParts.length - 1];

  // If the last path segment is the function name, try reading from body instead
  if (!alertId || alertId === "manage-price-alerts" || alertId === "v1") {
    try {
      const body = await req.json();
      alertId = typeof body.alert_id === "string" ? body.alert_id : "";
    } catch {
      alertId = "";
    }
  }

  if (!alertId) {
    return new Response(
      JSON.stringify({ error: "Alert ID is required (in URL path or body.alert_id)" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Validate UUID format to avoid leaking query errors on malformed input.
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidRegex.test(alertId)) {
    return new Response(
      JSON.stringify({ error: "Invalid alert ID format" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Soft-delete: set is_active = false.
  // The WHERE user_id = userId clause ensures users can only delete their own
  // alerts (row-level ownership check without relying solely on RLS).
  const { data: updatedData, error: updateError } = await supabase
    .from("price_alerts")
    .update({ is_active: false })
    .eq("id", alertId)
    .eq("user_id", userId)  // ownership check
    .eq("is_active", true)  // only deactivate if currently active
    .select("id")
    .maybeSingle();

  if (updateError) {
    console.error(
      `[manage-price-alerts] DELETE update failed for alert ${alertId} user ${userId}:`,
      updateError.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!updatedData) {
    // Either alert does not exist, does not belong to this user, or is already inactive.
    // Return 404 — this is safe to reveal since we also check ownership.
    return new Response(
      JSON.stringify({ error: "Alert not found or already inactive" }),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[manage-price-alerts] DELETE user ${userId} — deactivated alert ${alertId}`
  );

  return new Response(
    JSON.stringify({ success: true, data: { deactivated_id: alertId } }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const method = req.method;

  if (method !== "GET" && method !== "POST" && method !== "DELETE") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 1. Authentication (required for all methods) ---
  const user = await getUserFromAuth(req.headers.get("Authorization"), req);
  if (!user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[manage-price-alerts] ${method} request from user ${user.id}`);

  // --- 2. Rate limiting ---
  const rateLimitResult = checkRateLimit(user.id, "manage-price-alerts");
  if (!rateLimitResult.allowed) {
    return new Response(
      JSON.stringify({
        error: "Too many requests. Please wait before trying again.",
        retryAfter: rateLimitResult.retryAfter,
      }),
      {
        status: 429,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Retry-After": String(rateLimitResult.retryAfter ?? 10),
        },
      }
    );
  }

  const supabase = getSupabaseAdmin();

  // --- 3. Dispatch to method handler ---
  try {
    if (method === "GET") {
      return await handleGet(req, user.id, supabase);
    }

    if (method === "POST") {
      return await handlePost(req, user.id, supabase);
    }

    // DELETE
    return await handleDelete(req, user.id, supabase);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[manage-price-alerts] ${method} handler threw for user ${user.id}:`, message);

    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
