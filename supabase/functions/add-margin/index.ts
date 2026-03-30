import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface AddMarginRequest {
  trade_id: string;
  amount: number;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const MIN_AMOUNT = 10;

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

  // --- 2. Rate limiting ---
  const rateLimitResult = checkRateLimit(user.id, "add-margin");
  if (!rateLimitResult.allowed) {
    console.log(
      `[add-margin] Rate limit hit for user ${user.id}. Retry after ${rateLimitResult.retryAfter}s`
    );
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
          "Retry-After": String(rateLimitResult.retryAfter ?? 5),
        },
      }
    );
  }

  // --- 3. Parse and validate body ---
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

  // Validate trade_id
  if (typeof body.trade_id !== "string" || !UUID_REGEX.test(body.trade_id)) {
    return new Response(
      JSON.stringify({ error: "trade_id must be a valid UUID" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Validate amount
  if (typeof body.amount !== "number" || body.amount < MIN_AMOUNT) {
    return new Response(
      JSON.stringify({ error: `amount must be a number >= ${MIN_AMOUNT}` }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const tradeId = body.trade_id as string;
  const amount = body.amount as number;

  console.log(
    `[add-margin] User ${user.id} adding ${amount} USDT margin to trade ${tradeId}`
  );

  // --- 4. Call RPC ---
  const supabase = getSupabaseAdmin();

  const { data: rpcResult, error: rpcError } = await supabase.rpc(
    "add_margin_txn",
    {
      p_trade_id: tradeId,
      p_user_id: user.id,
      p_additional_margin: amount,
    }
  );

  if (rpcError) {
    const pgMessage = rpcError.message ?? "";

    if (pgMessage.includes("insufficient_balance")) {
      return new Response(
        JSON.stringify({ error: "Insufficient balance to add margin." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (pgMessage.includes("trade_not_found")) {
      return new Response(
        JSON.stringify({ error: "Trade not found." }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (pgMessage.includes("trade_not_open")) {
      return new Response(
        JSON.stringify({ error: "Cannot add margin to a closed or liquidated position." }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.error("[add-margin] RPC error:", rpcError);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[add-margin] Margin added successfully. Trade ${tradeId}, new margin in response.`
  );

  return new Response(
    JSON.stringify({ success: true, data: rpcResult }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
