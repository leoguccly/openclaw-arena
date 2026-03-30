import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface DailyRewardRpcResult {
  already_claimed: boolean;
  streak: number;
  bonus_amount: number;
  new_balance: number;
}

interface UserRow {
  is_human: boolean;
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

  console.log(`[claim-daily-reward] Request from user ${user.id}`);

  // --- 2. Rate limiting (once per invocation to block burst abuse) ---
  const rateLimitResult = checkRateLimit(user.id, "claim-daily-reward");
  if (!rateLimitResult.allowed) {
    console.log(
      `[claim-daily-reward] Rate limit hit for user ${user.id}. Retry after ${rateLimitResult.retryAfter}s`
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
          "Retry-After": String(rateLimitResult.retryAfter ?? 60),
        },
      }
    );
  }

  const supabase = getSupabaseAdmin();

  // --- 3. Verify the caller is a human user ---
  // AI agents are not eligible for daily rewards. The is_human flag is
  // maintained by the platform and cannot be modified by the user directly.
  const { data: userData, error: userError } = await supabase
    .from("users")
    .select("is_human")
    .eq("id", user.id)
    .single();

  if (userError || !userData) {
    console.error(
      `[claim-daily-reward] Could not fetch user row for ${user.id}:`,
      userError?.message ?? "no row returned"
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const userRow = userData as UserRow;

  if (!userRow.is_human) {
    console.log(
      `[claim-daily-reward] Rejected AI account ${user.id} — daily rewards are for human users only`
    );
    return new Response(
      JSON.stringify({ error: "Daily rewards are available to human users only." }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 4. Call award_daily_reward_txn RPC ---
  // The database function handles idempotency (already_claimed flag),
  // streak tracking, and the atomic balance increment in one transaction.
  const { data: rpcData, error: rpcError } = await supabase.rpc(
    "award_daily_reward_txn",
    { p_user_id: user.id }
  );

  if (rpcError) {
    console.error(
      `[claim-daily-reward] award_daily_reward_txn failed for user ${user.id}:`,
      rpcError.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const result = rpcData as DailyRewardRpcResult;

  if (result.already_claimed) {
    console.log(`[claim-daily-reward] User ${user.id} already claimed today's reward`);
  } else {
    console.log(
      `[claim-daily-reward] User ${user.id} claimed reward — ` +
      `streak: ${result.streak}, bonus: ${result.bonus_amount}, new_balance: ${result.new_balance}`
    );

    // --- 5. Achievement check is handled by the Transactional Outbox ---
    // The award_daily_reward_txn RPC now inserts a 'check_achievements'
    // event into public.event_outbox IN THE SAME DATABASE TRANSACTION as
    // the balance credit. The process-outbox Edge Function (cron, every
    // 30 seconds) reads pending rows and dispatches them with retry
    // semantics. ACH-005 (Streak Keeper) can no longer be silently lost
    // due to a network failure or function timeout at this call site.
    console.log(
      `[claim-daily-reward] check_achievements outbox event enqueued by RPC for user ${user.id} ` +
      `(streak=${result.streak}) — will be dispatched by process-outbox`
    );
  }

  return new Response(
    JSON.stringify({
      success: true,
      data: {
        already_claimed: result.already_claimed,
        streak: result.streak,
        bonus_amount: result.bonus_amount,
        new_balance: result.new_balance,
      },
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
