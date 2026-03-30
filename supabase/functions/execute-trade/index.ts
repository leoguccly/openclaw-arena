import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";
import { getServerSidePrice } from "../market-oracle/index.ts";
import { SYMBOL_TO_BINANCE, TRADING_SYMBOLS } from "../_shared/symbols.ts";
import { computeLiquidationPrice, computeQuantity } from "../_shared/trade-math.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ExecuteTradeRequest {
  symbol: string;
  direction: "long" | "short";
  leverage: number;
  margin: number;
}

interface TradeRecord {
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
  created_at: string;
  updated_at: string;
}

// ---------------------------------------------------------------------------
// Validation constants
// ---------------------------------------------------------------------------

/**
 * The frontend uses slash notation ('BTC/USDT') while Binance uses run-together
 * notation ('BTCUSDT'). Both maps are maintained so validation is unambiguous.
 */
const ALLOWED_SYMBOLS_DISPLAY = new Set(TRADING_SYMBOLS);

const MIN_MARGIN = 10;
const MIN_LEVERAGE = 1;
const MAX_LEVERAGE = 100;

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------

interface ValidationError {
  field: string;
  message: string;
}

function validateRequest(body: unknown): {
  data: ExecuteTradeRequest | null;
  errors: ValidationError[];
} {
  const errors: ValidationError[] = [];

  if (typeof body !== "object" || body === null) {
    return { data: null, errors: [{ field: "body", message: "Request body must be a JSON object" }] };
  }

  const raw = body as Record<string, unknown>;

  // symbol
  if (typeof raw.symbol !== "string" || !ALLOWED_SYMBOLS_DISPLAY.has(raw.symbol)) {
    errors.push({
      field: "symbol",
      message: `symbol must be one of: ${[...ALLOWED_SYMBOLS_DISPLAY].join(", ")}`,
    });
  }

  // direction
  if (raw.direction !== "long" && raw.direction !== "short") {
    errors.push({ field: "direction", message: "direction must be 'long' or 'short'" });
  }

  // leverage — must be an integer in [1, 100]
  if (
    typeof raw.leverage !== "number" ||
    !Number.isInteger(raw.leverage) ||
    raw.leverage < MIN_LEVERAGE ||
    raw.leverage > MAX_LEVERAGE
  ) {
    errors.push({
      field: "leverage",
      message: `leverage must be an integer between ${MIN_LEVERAGE} and ${MAX_LEVERAGE}`,
    });
  }

  // margin
  if (typeof raw.margin !== "number" || raw.margin < MIN_MARGIN) {
    errors.push({
      field: "margin",
      message: `margin must be a number >= ${MIN_MARGIN}`,
    });
  }

  if (errors.length > 0) {
    return { data: null, errors };
  }

  return {
    data: {
      symbol: raw.symbol as string,
      direction: raw.direction as "long" | "short",
      leverage: raw.leverage as number,
      margin: raw.margin as number,
    },
    errors: [],
  };
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

  // --- 2. Rate limit (per user, not per IP — this is an authenticated action) ---
  const rateLimitResult = checkRateLimit(user.id, "execute-trade");
  if (!rateLimitResult.allowed) {
    console.log(
      `[execute-trade] Rate limit hit for user ${user.id}. Retry after ${rateLimitResult.retryAfter}s`
    );
    return new Response(
      JSON.stringify({
        error: "Too many requests. Please wait before placing another trade.",
        retryAfter: rateLimitResult.retryAfter,
      }),
      {
        status: 429,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Retry-After": String(rateLimitResult.retryAfter ?? 5),
        },
      }
    );
  }

  // --- 3. Parse and validate request body ---
  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const { data: tradeInput, errors: validationErrors } = validateRequest(rawBody);
  if (validationErrors.length > 0 || tradeInput === null) {
    return new Response(
      JSON.stringify({ error: "Validation failed", details: validationErrors }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 4. Fetch real-time price SERVER-SIDE ---
  // The client NEVER provides the price. This is non-negotiable.
  const binanceSymbol = SYMBOL_TO_BINANCE[tradeInput.symbol];
  let entryPrice: number;
  try {
    const priceData = await getServerSidePrice(binanceSymbol);
    entryPrice = priceData.price;
    console.log(
      `[execute-trade] Server-side entry price for ${tradeInput.symbol}: ${entryPrice}`
    );
  } catch {
    return new Response(
      JSON.stringify({ error: "Price feed unavailable. Cannot execute trade." }),
      { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 5. Compute derived fields ---
  const liquidationPrice = computeLiquidationPrice(
    entryPrice,
    tradeInput.direction,
    tradeInput.leverage
  );
  const quantity = computeQuantity(
    tradeInput.margin,
    tradeInput.leverage,
    entryPrice
  );

  console.log(
    `[execute-trade] User ${user.id} opening ${tradeInput.direction} ` +
    `${tradeInput.symbol} x${tradeInput.leverage} | margin=${tradeInput.margin} ` +
    `| entry=${entryPrice} | liq=${liquidationPrice.toFixed(8)} | qty=${quantity.toFixed(8)}`
  );

  // --- 6. Execute atomically via PostgreSQL transaction ---
  // We use a Postgres function via rpc() to keep the entire critical section
  // inside a single round-trip. The function acquires a FOR UPDATE row lock on
  // users, validates balance, inserts the trade, and decrements the balance —
  // all in one atomic transaction.
  //
  // Because Supabase Edge Functions do not expose raw pg connections, we
  // perform the transaction through sequential admin client calls inside a
  // database function. The `execute_trade_txn` RPC encapsulates the atomicity.
  //
  // If that RPC is not available (e.g., during local dev), we fall back to a
  // best-effort multi-step approach with documented race-condition caveats.

  const supabase = getSupabaseAdmin();

  // Attempt the transaction via RPC (preferred path — atomic, race-safe).
  const { data: rpcResult, error: rpcError } = await supabase.rpc(
    "execute_trade_txn",
    {
      p_user_id: user.id,
      p_symbol: tradeInput.symbol,
      p_direction: tradeInput.direction,
      p_leverage: tradeInput.leverage,
      p_margin: tradeInput.margin,
      p_entry_price: entryPrice,
      p_liquidation_price: liquidationPrice,
      p_quantity: quantity,
    }
  );

  if (rpcError) {
    const pgCode = (rpcError as { code?: string }).code ?? "";
    const pgMessage = rpcError.message ?? "";

    // Unique partial index violation → duplicate open position for this symbol
    if (pgCode === "23505") {
      console.log(
        `[execute-trade] Duplicate open position rejected for user ${user.id} symbol ${tradeInput.symbol}`
      );
      return new Response(
        JSON.stringify({
          error: `You already have an open ${tradeInput.symbol} position. Close it before opening a new one.`,
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Balance check failed inside the transaction
    if (pgMessage.includes("insufficient_balance")) {
      return new Response(
        JSON.stringify({ error: "Insufficient balance to cover the required margin." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // RPC does not exist (migration not applied).
    // FAIL HARD — do NOT fall back to the non-atomic path in production.
    // The fallback is kept below for local development ONLY.
    if (pgCode === "42883" || pgMessage.includes("does not exist")) {
      const allowFallback = Deno.env.get("ALLOW_UNSAFE_FALLBACK") === "true";
      if (allowFallback) {
        console.warn(
          "[execute-trade] execute_trade_txn RPC not found. ALLOW_UNSAFE_FALLBACK=true, using non-atomic fallback."
        );
        return await fallbackMultiStep(supabase, user.id, tradeInput, entryPrice, liquidationPrice, quantity);
      }
      console.error(
        "[execute-trade] FATAL: execute_trade_txn RPC not found. Apply migration 002 before deploying."
      );
      return new Response(
        JSON.stringify({ error: "Service temporarily unavailable. Please try again later." }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // All other DB errors
    console.error("[execute-trade] RPC error:", rpcError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!rpcResult || typeof (rpcResult as Record<string, unknown>).id !== "string") {
    console.error("[execute-trade] Unexpected RPC result shape:", rpcResult);
    return new Response(
      JSON.stringify({ error: "An error occurred." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[execute-trade] Trade opened successfully. Trade ID: ${(rpcResult as TradeRecord).id}`
  );

  return new Response(
    JSON.stringify({ success: true, data: rpcResult }),
    { status: 201, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});

// ---------------------------------------------------------------------------
// Fallback multi-step path (no atomic RPC)
// ---------------------------------------------------------------------------
// WARNING: This path does NOT use a DB-level transaction. It is provided only
// as a development convenience when the execute_trade_txn RPC has not been
// applied yet. In production, the RPC path must be used.
//
// Race-condition exposure: between the balance check and the INSERT/UPDATE,
// another concurrent request could drain the balance. The DB-level
// CHECK (balance >= 0) and the partial unique index are the last lines of
// defence in this fallback path.

async function fallbackMultiStep(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string,
  tradeInput: ExecuteTradeRequest,
  entryPrice: number,
  liquidationPrice: number,
  quantity: number
): Promise<Response> {
  // Read current balance
  const { data: userData, error: userError } = await supabase
    .from("users")
    .select("balance")
    .eq("id", userId)
    .single();

  if (userError || !userData) {
    console.error("[execute-trade] Could not fetch user balance:", userError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const currentBalance = parseFloat(String(userData.balance));
  if (currentBalance < tradeInput.margin) {
    return new Response(
      JSON.stringify({ error: "Insufficient balance to cover the required margin." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Insert trade
  const { data: insertedTrade, error: insertError } = await supabase
    .from("trades")
    .insert({
      user_id: userId,
      symbol: tradeInput.symbol,
      direction: tradeInput.direction,
      leverage: tradeInput.leverage,
      margin: tradeInput.margin,
      entry_price: entryPrice,
      liquidation_price: liquidationPrice,
      quantity: quantity,
      status: "open",
    })
    .select()
    .single();

  if (insertError) {
    const pgCode = (insertError as { code?: string }).code ?? "";
    if (pgCode === "23505") {
      return new Response(
        JSON.stringify({
          error: `You already have an open ${tradeInput.symbol} position. Close it before opening a new one.`,
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    console.error("[execute-trade] Trade insert failed:", insertError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Deduct margin from balance
  const { error: updateError } = await supabase
    .from("users")
    .update({ balance: currentBalance - tradeInput.margin })
    .eq("id", userId);

  if (updateError) {
    // Trade was inserted but balance update failed. Log loudly — requires
    // manual reconciliation. The DB CHECK (balance >= 0) may catch extreme cases.
    console.error(
      `[execute-trade] CRITICAL: Trade ${insertedTrade.id} inserted but balance update failed:`,
      updateError
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[execute-trade] Fallback path: trade opened. Trade ID: ${insertedTrade.id}`);

  return new Response(
    JSON.stringify({ success: true, data: insertedTrade }),
    { status: 201, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}
