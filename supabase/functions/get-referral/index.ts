import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Base URL for referral links. The referral code is appended as a query param.
 * Callers can override this via the REFERRAL_BASE_URL env var for staging/prod.
 */
const REFERRAL_BASE_URL =
  Deno.env.get("REFERRAL_BASE_URL") ?? "https://openclaw.arena/join";

/** Length of the generated referral code (alphanumeric, crypto-random). */
const REFERRAL_CODE_LENGTH = 8;

/** Alphabet used for referral code generation — uppercase + digits, unambiguous. */
const REFERRAL_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface UserRow {
  referral_code: string | null;
}

interface ReferralEventRow {
  id: string;
  referee_id: string;
  referrer_bonus: number;
  bonus_paid_at: string;
  referee: {
    display_name: string | null;
  } | null;
}

interface RefereeRecord {
  user_id: string;
  display_name: string | null;
  bonus_amount: number;
  bonus_paid_at: string;
}

// ---------------------------------------------------------------------------
// Referral code generator
// ---------------------------------------------------------------------------

/**
 * Generates an 8-character alphanumeric referral code using
 * crypto.getRandomValues() so each character is drawn from a 32-symbol
 * alphabet via rejection sampling — no modulo bias.
 */
function generateReferralCode(): string {
  const alphabetLength = REFERRAL_ALPHABET.length; // 32
  const result: string[] = [];

  while (result.length < REFERRAL_CODE_LENGTH) {
    const bytes = new Uint8Array(REFERRAL_CODE_LENGTH * 2); // oversample
    crypto.getRandomValues(bytes);

    for (const byte of bytes) {
      if (result.length >= REFERRAL_CODE_LENGTH) break;
      // Rejection threshold: reject bytes that would introduce modulo bias.
      // 256 / 32 = 8 → reject bytes >= 32 * 8 = 256. Since 256 % 256 == 0,
      // all values 0–255 map evenly to 0–31 with no bias at all.
      // (256 is an exact multiple of 32, so every byte is valid.)
      const index = byte % alphabetLength;
      result.push(REFERRAL_ALPHABET[index]);
    }
  }

  return result.join("");
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "GET" && req.method !== "POST") {
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

  console.log(`[get-referral] Request from user ${user.id}`);

  // --- 2. Rate limiting ---
  const rateLimitResult = checkRateLimit(user.id, "get-referral");
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

  // --- 3. Fetch or generate referral code ---
  const { data: userData, error: userError } = await supabase
    .from("users")
    .select("referral_code")
    .eq("id", user.id)
    .single<UserRow>();

  if (userError || !userData) {
    console.error(
      `[get-referral] Failed to fetch user row for ${user.id}:`,
      userError?.message ?? "no row returned"
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  let referralCode = userData.referral_code;

  if (!referralCode) {
    // Generate a new code. Retry up to 5 times on the unlikely event of a
    // collision with an existing code (unique constraint violation: 23505).
    let generated = false;
    let attempts = 0;

    while (!generated && attempts < 5) {
      attempts++;
      const candidate = generateReferralCode();

      const { error: updateError } = await supabase
        .from("users")
        .update({ referral_code: candidate })
        .eq("id", user.id)
        .is("referral_code", null); // Only write if still null (idempotency guard)

      if (!updateError) {
        referralCode = candidate;
        generated = true;
        console.log(
          `[get-referral] Generated referral code "${candidate}" for user ${user.id} ` +
          `(attempt ${attempts})`
        );
      } else {
        const pgCode = (updateError as { code?: string }).code ?? "";
        if (pgCode === "23505") {
          // Unique constraint collision — try again with a different code
          console.warn(
            `[get-referral] Referral code collision on attempt ${attempts} for user ${user.id}. Retrying.`
          );
          continue;
        }
        // Some other DB error
        console.error(
          `[get-referral] Failed to update referral_code for user ${user.id}:`,
          updateError.message
        );
        return new Response(
          JSON.stringify({ error: "An error occurred. Please try again." }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    if (!generated || !referralCode) {
      // If the row was updated by a concurrent request between our SELECT and
      // UPDATE, re-read the now-set code rather than failing.
      const { data: refetchedUser, error: refetchError } = await supabase
        .from("users")
        .select("referral_code")
        .eq("id", user.id)
        .single<UserRow>();

      if (refetchError || !refetchedUser?.referral_code) {
        console.error(
          `[get-referral] Could not resolve referral code for user ${user.id} after ${attempts} attempts`
        );
        return new Response(
          JSON.stringify({ error: "An error occurred. Please try again." }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      referralCode = refetchedUser.referral_code;
      console.log(
        `[get-referral] Re-fetched referral code "${referralCode}" for user ${user.id} ` +
        `after concurrent write`
      );
    }
  }

  // --- 4. Fetch confirmed referrals from referral_events ---
  // JOIN to users for referee display_name. We select confirmed referrals only
  // to display to the referrer; pending entries are internal.
  const { data: eventsData, error: eventsError } = await supabase
    .from("referral_events")
    .select(
      "id, referee_id, referrer_bonus, bonus_paid_at, referee:users!referral_events_referee_id_fkey(display_name)"
    )
    .eq("referrer_id", user.id)
    .order("bonus_paid_at", { ascending: false });

  if (eventsError) {
    console.error(
      `[get-referral] Failed to fetch referral_events for user ${user.id}:`,
      eventsError.message
    );
    // Non-fatal: return the code and link with an empty list rather than 500.
  }

  const events = (eventsData ?? []) as ReferralEventRow[];

  // Build the referee display list — every row in referral_events is a confirmed payout
  const referees: RefereeRecord[] = events.map((ev) => ({
    user_id: ev.referee_id,
    display_name: ev.referee?.display_name ?? null,
    bonus_amount: parseFloat(String(ev.referrer_bonus ?? 0)),
    bonus_paid_at: ev.bonus_paid_at,
  }));

  // Total bonus earned = sum of all referrer_bonus payouts
  const totalBonusEarned = events
    .reduce((sum, ev) => sum + parseFloat(String(ev.referrer_bonus ?? 0)), 0);

  const referralLink = `${REFERRAL_BASE_URL}?ref=${referralCode}`;

  console.log(
    `[get-referral] User ${user.id} — code=${referralCode}, ` +
    `referees=${referees.length}, total_bonus=${totalBonusEarned.toFixed(4)}`
  );

  return new Response(
    JSON.stringify({
      success: true,
      data: {
        referral_code: referralCode,
        referral_link: referralLink,
        referees,
        total_bonus_earned: totalBonusEarned,
      },
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
