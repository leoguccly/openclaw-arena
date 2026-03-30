import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { getServerSidePrice } from "../_shared/price-feed.ts";
import { SYMBOL_TO_BINANCE } from "../_shared/symbols.ts";
import { computePnl, computeSettlement } from "../_shared/trade-math.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface CloseTradeRequest {
  trade_id: string;
}

interface OpenTradeRow {
  id: string;
  user_id: string;
  symbol: string;
  direction: "long" | "short";
  leverage: number;
  margin: number;
  entry_price: number;
  liquidation_price: number;
  quantity: number;
  status: "open";
}

interface CloseTradeResult {
  trade_id: string;
  symbol: string;
  direction: "long" | "short";
  entry_price: number;
  exit_price: number;
  quantity: number;
  margin: number;
  realised_pnl: number;
  settlement: number;
  updated_at: string;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isValidUUID(value: string): boolean {
  return UUID_REGEX.test(value);
}

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

  // --- 1. Authentication ---
  const user = await getUserFromAuth(req.headers.get("Authorization"), req);
  if (!user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 2. Parse request body ---
  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (typeof rawBody !== "object" || rawBody === null) {
    return new Response(
      JSON.stringify({ error: "Request body must be a JSON object" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const body = rawBody as Record<string, unknown>;

  // --- 3. Validate trade_id ---
  if (typeof body.trade_id !== "string" || !body.trade_id.trim()) {
    return new Response(
      JSON.stringify({ error: "trade_id is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const tradeId = body.trade_id.trim();

  if (!isValidUUID(tradeId)) {
    return new Response(
      JSON.stringify({ error: "trade_id must be a valid UUID" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 4. Fetch real-time exit price SERVER-SIDE via atomic RPC path ---
  // We first read the trade to discover the symbol, then fetch the price.
  // The actual close happens inside the RPC (or fallback) to keep atomicity.

  const supabase = getSupabaseAdmin();

  // Peek at the trade to get the symbol (read-only, no lock yet).
  const { data: peekTrade, error: peekError } = await supabase
    .from("trades")
    .select("symbol, direction, entry_price, quantity, margin, status, user_id")
    .eq("id", tradeId)
    .single();

  if (peekError || !peekTrade) {
    // Could be not found, or a DB error.
    if ((peekError as { code?: string })?.code === "PGRST116") {
      return new Response(
        JSON.stringify({ error: "Trade not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    console.error("[close-trade] Peek query error:", peekError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Ownership check before touching the price feed.
  if (peekTrade.user_id !== user.id) {
    return new Response(
      JSON.stringify({ error: "Trade not found" }), // Intentionally vague — no info leak
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (peekTrade.status !== "open") {
    return new Response(
      JSON.stringify({ error: "Trade is already closed or liquidated" }),
      { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 5. Fetch server-side exit price ---
  const binanceSymbol = SYMBOL_TO_BINANCE[peekTrade.symbol];
  if (!binanceSymbol) {
    console.error(`[close-trade] Unknown symbol mapping for: ${peekTrade.symbol}`);
    return new Response(
      JSON.stringify({ error: "Unsupported trading symbol" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  let exitPrice: number;
  try {
    const priceData = await getServerSidePrice(binanceSymbol);
    exitPrice = priceData.price;
    console.log(
      `[close-trade] Server-side exit price for ${peekTrade.symbol}: ${exitPrice}`
    );
  } catch {
    return new Response(
      JSON.stringify({ error: "Price feed unavailable. Cannot close trade." }),
      { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 6. Compute PnL and settlement ---
  const entryPrice = parseFloat(String(peekTrade.entry_price));
  const quantity = parseFloat(String(peekTrade.quantity));
  const margin = parseFloat(String(peekTrade.margin));
  const direction = peekTrade.direction as "long" | "short";

  const realisedPnl = computePnl(direction, quantity, entryPrice, exitPrice);
  const settlement = computeSettlement(margin, realisedPnl);

  console.log(
    `[close-trade] User ${user.id} closing trade ${tradeId} | ` +
    `direction=${direction} | entry=${entryPrice} | exit=${exitPrice} | ` +
    `qty=${quantity} | margin=${margin} | pnl=${realisedPnl.toFixed(4)} | settlement=${settlement.toFixed(4)}`
  );

  // --- 7. Execute atomically via RPC (preferred path) ---
  const { data: rpcResult, error: rpcError } = await supabase.rpc(
    "close_trade_txn",
    {
      p_trade_id: tradeId,
      p_user_id: user.id,
      p_exit_price: exitPrice,
      p_realised_pnl: realisedPnl,
      p_settlement: settlement,
    }
  );

  if (rpcError) {
    const pgCode = (rpcError as { code?: string }).code ?? "";
    const pgMessage = rpcError.message ?? "";

    // Trade not found or wrong owner inside the locked transaction
    if (pgMessage.includes("trade_not_found")) {
      return new Response(
        JSON.stringify({ error: "Trade not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // RPC does not exist (migration not applied).
    // FAIL HARD in production — only fall back with explicit env var.
    if (pgCode === "42883" || pgMessage.includes("does not exist")) {
      const allowFallback = Deno.env.get("ALLOW_UNSAFE_FALLBACK") === "true";
      if (allowFallback) {
        console.warn(
          "[close-trade] close_trade_txn RPC not found. ALLOW_UNSAFE_FALLBACK=true, using non-atomic fallback."
        );
        return await fallbackMultiStep(
          supabase,
          user.id,
          tradeId,
          exitPrice,
          realisedPnl,
          settlement
        );
      }
      console.error(
        "[close-trade] FATAL: close_trade_txn RPC not found. Apply migration 002 before deploying."
      );
      return new Response(
        JSON.stringify({ error: "Service temporarily unavailable. Please try again later." }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.error("[close-trade] RPC error:", rpcError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!rpcResult || typeof (rpcResult as Record<string, unknown>).id !== "string") {
    console.error("[close-trade] Unexpected RPC result shape:", rpcResult);
    return new Response(
      JSON.stringify({ error: "An error occurred." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[close-trade] Trade ${tradeId} closed successfully via RPC`);

  const result: CloseTradeResult = {
    trade_id: tradeId,
    symbol: peekTrade.symbol,
    direction,
    entry_price: entryPrice,
    exit_price: exitPrice,
    quantity,
    margin,
    realised_pnl: realisedPnl,
    settlement,
    updated_at: new Date().toISOString(),
    ...(rpcResult as object),
  };

  return new Response(
    JSON.stringify({ success: true, data: result }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});

// ---------------------------------------------------------------------------
// Fallback multi-step path (no atomic RPC)
// ---------------------------------------------------------------------------
// WARNING: Same caveats as execute-trade fallback. Use only in development.
// The DB-level CHECK (balance >= 0) is the last line of defence here.

async function fallbackMultiStep(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  tradeId: string,
  exitPrice: number,
  realisedPnl: number,
  settlement: number
): Promise<Response> {
  // Lock and re-read the trade row (simulates FOR UPDATE as best we can
  // without a raw pg connection — Supabase client does not expose FOR UPDATE).
  const { data: trade, error: tradeError } = await supabase
    .from("trades")
    .select("*")
    .eq("id", tradeId)
    .eq("user_id", userId)
    .eq("status", "open")
    .single();

  if (tradeError || !trade) {
    if ((tradeError as { code?: string })?.code === "PGRST116") {
      return new Response(
        JSON.stringify({ error: "Trade not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    console.error("[close-trade] Re-read trade failed:", tradeError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Update trade to closed
  const { error: tradeUpdateError } = await supabase
    .from("trades")
    .update({
      status: "closed",
      exit_price: exitPrice,
      realised_pnl: realisedPnl,
    })
    .eq("id", tradeId)
    .eq("status", "open"); // guard: only update if still open

  if (tradeUpdateError) {
    console.error("[close-trade] Trade update failed:", tradeUpdateError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Read current balance to compute new ROI
  const { data: userData, error: userReadError } = await supabase
    .from("users")
    .select("balance")
    .eq("id", userId)
    .single();

  if (userReadError || !userData) {
    console.error(
      `[close-trade] CRITICAL: Trade ${tradeId} closed but could not read user balance:`,
      userReadError
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const currentBalance = parseFloat(String(userData.balance));
  const newBalance = currentBalance + settlement;
  // ROI = (current_balance - initial_balance) / initial_balance
  // Initial balance is 10000 per schema default.
  const INITIAL_BALANCE = 10_000;
  const newRoi = (newBalance - INITIAL_BALANCE) / INITIAL_BALANCE;

  const { error: userUpdateError } = await supabase
    .from("users")
    .update({
      balance: newBalance,
      roi: newRoi,
    })
    .eq("id", userId);

  if (userUpdateError) {
    console.error(
      `[close-trade] CRITICAL: Trade ${tradeId} closed but balance update failed:`,
      userUpdateError
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[close-trade] Fallback path: trade ${tradeId} closed. ` +
    `New balance: ${newBalance.toFixed(4)} | ROI: ${newRoi.toFixed(6)}`
  );

  const margin = parseFloat(String(trade.margin));

  const result: CloseTradeResult = {
    trade_id: tradeId,
    symbol: trade.symbol,
    direction: trade.direction,
    entry_price: parseFloat(String(trade.entry_price)),
    exit_price: exitPrice,
    quantity: parseFloat(String(trade.quantity)),
    margin,
    realised_pnl: realisedPnl,
    settlement,
    updated_at: new Date().toISOString(),
  };

  return new Response(
    JSON.stringify({ success: true, data: result }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}
