import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Auth ---
  const user = await getUserFromAuth(req.headers.get("Authorization"), req);
  if (!user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Rate limit ---
  const rl = checkRateLimit(user.id, "redeem-code");
  if (!rl.allowed) {
    return new Response(
      JSON.stringify({ error: "Too many attempts. Please wait.", retryAfter: rl.retryAfter }),
      { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json", "Retry-After": String(rl.retryAfter ?? 10) } }
    );
  }

  // --- Parse body ---
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const code = typeof body.code === "string" ? body.code.trim() : "";
  const tournamentId = typeof body.tournament_id === "string" ? body.tournament_id : null;

  if (!code || code.length < 4) {
    return new Response(
      JSON.stringify({ error: "Please enter a valid code." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[redeem-code] User ${user.id} redeeming code "${code}"`);

  // --- Call RPC ---
  const supabase = getSupabaseAdmin();
  const { data, error } = await supabase.rpc("redeem_tournament_code_txn", {
    p_user_id: user.id,
    p_code: code,
    p_tournament_id: tournamentId,
  });

  if (error) {
    console.error("[redeem-code] RPC error:", error);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const result = data as Record<string, unknown>;

  // RPC returns { error: "...", message: "..." } on failure
  if (result.error) {
    console.log(`[redeem-code] Rejected: ${result.error} — ${result.message}`);
    return new Response(
      JSON.stringify({ error: result.message }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[redeem-code] Success — user ${user.id} joined tournament ${result.tournament_id}`);

  return new Response(
    JSON.stringify({ success: true, data: result }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
