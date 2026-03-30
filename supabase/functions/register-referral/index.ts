import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Maximum length of a referral code we will accept in the request body.
 * Codes are 8 characters; anything longer is certainly invalid.
 */
const MAX_CODE_LENGTH = 32;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RegisterReferralRequest {
  referral_code: string;
}

interface ReferrerRow {
  id: string;
  referral_code: string;
}

interface UserRow {
  referred_by: string | null;
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

  console.log(`[register-referral] Request from user ${user.id}`);

  // --- 2. Rate limiting ---
  const rateLimitResult = checkRateLimit(user.id, "register-referral");
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
          "Retry-After": String(rateLimitResult.retryAfter ?? 60),
        },
      }
    );
  }

  // --- 3. Parse request body ---
  let body: RegisterReferralRequest;
  try {
    body = await req.json() as RegisterReferralRequest;
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 4. Validate input ---
  if (!body.referral_code || typeof body.referral_code !== "string") {
    return new Response(
      JSON.stringify({ error: "referral_code is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const code = body.referral_code.trim().toUpperCase();

  if (code.length === 0 || code.length > MAX_CODE_LENGTH) {
    return new Response(
      JSON.stringify({ error: "referral_code is invalid" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const supabase = getSupabaseAdmin();

  // --- 5. Look up the referral code owner ---
  // SECURITY: We look up the code but never reveal whether it exists in the
  // response. All outcomes (code not found, self-referral, already registered)
  // return the same 200 OK response so callers cannot enumerate valid codes.
  const { data: referrerData, error: referrerError } = await supabase
    .from("users")
    .select("id, referral_code")
    .eq("referral_code", code)
    .maybeSingle<ReferrerRow>();

  if (referrerError) {
    console.error(
      `[register-referral] Failed to look up referral code "${code}":`,
      referrerError.message
    );
    // Fail silently — do not leak DB errors to the caller
    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!referrerData) {
    // Code does not exist — silent skip per spec
    console.log(
      `[register-referral] Code "${code}" not found — silent skip for user ${user.id}`
    );
    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 6. Self-referral guard ---
  if (referrerData.id === user.id) {
    console.log(
      `[register-referral] Self-referral attempt by user ${user.id} — silent skip`
    );
    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 7. Check if user already has a referrer ---
  const { data: currentUserData, error: currentUserError } = await supabase
    .from("users")
    .select("referred_by")
    .eq("id", user.id)
    .single<UserRow>();

  if (currentUserError || !currentUserData) {
    console.error(
      `[register-referral] Failed to fetch current user row for ${user.id}:`,
      currentUserError?.message ?? "no row returned"
    );
    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (currentUserData.referred_by !== null) {
    // Already referred — silent skip
    console.log(
      `[register-referral] User ${user.id} already has a referrer — silent skip`
    );
    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- 8. Register the referral ---
  // SET referred_by and record the exact code used. Both fields are written in
  // a single UPDATE. The unique constraint on referred_by prevents a race
  // condition from registering two referrers (23505 → silent skip).
  const { error: updateError } = await supabase
    .from("users")
    .update({
      referred_by: referrerData.id,
      referral_code_used: code,
    })
    .eq("id", user.id)
    .is("referred_by", null); // Only write if still null — idempotency guard

  if (updateError) {
    const pgCode = (updateError as { code?: string }).code ?? "";
    if (pgCode === "23505") {
      // Concurrent request already set referred_by — silent skip
      console.log(
        `[register-referral] Concurrent referral write for user ${user.id} — silent skip`
      );
      return new Response(
        JSON.stringify({ success: true }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.error(
      `[register-referral] Failed to update referred_by for user ${user.id}:`,
      updateError.message
    );
    // Still return 200 — never leak internal errors per spec
    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[register-referral] User ${user.id} registered under referrer ${referrerData.id} ` +
    `via code "${code}"`
  );

  return new Response(
    JSON.stringify({ success: true }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
