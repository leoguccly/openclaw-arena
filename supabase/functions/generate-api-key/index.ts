import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, hashApiKey } from "../_shared/supabase-client.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface GenerateApiKeyBody {
  user_id: string;
  label?: string;
}

interface ApiKeyRecord {
  id: string;
  user_id: string;
  key_prefix: string;
  hashed_key: string;
  label: string | null;
  created_at: string;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The raw key is "oca_" + 32 lowercase hex chars = 36 chars total. */
const KEY_PREFIX_CHARS = "oca_";
const KEY_HEX_LENGTH = 32;

/** First 12 characters of the raw key are stored as the display prefix. */
const KEY_PREFIX_DISPLAY_LENGTH = 12;

// ---------------------------------------------------------------------------
// Service-role guard
// ---------------------------------------------------------------------------

/**
 * This endpoint creates API keys on behalf of users and must only be reachable
 * by trusted internal callers (admin dashboard, backend scripts).
 *
 * We enforce this with a shared secret passed in the X-Internal-Secret header.
 * The secret is stored as the INTERNAL_SECRET Supabase secret and never
 * exposed to end-users or the frontend.
 *
 * An alternative approach (checking for the service_role JWT) is fragile
 * because it requires callers to hold the service_role key, which has its own
 * security implications. A separate static secret is simpler and easier to rotate.
 */
function isAuthorizedCaller(req: Request): boolean {
  const internalSecret = Deno.env.get("INTERNAL_SECRET");

  // If no secret is configured, fail closed — never allow unauthenticated access.
  if (!internalSecret || internalSecret.trim().length === 0) {
    console.error(
      "[generate-api-key] INTERNAL_SECRET env var is not set — denying all requests"
    );
    return false;
  }

  const provided = req.headers.get("x-internal-secret");
  if (!provided) {
    return false;
  }

  // Constant-time comparison is not available natively in Deno, but this
  // secret is long enough (and the endpoint internal enough) that a timing
  // attack via the public internet is not a realistic threat vector.
  return provided === internalSecret;
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

/**
 * Generates a cryptographically random hex string of the given byte length.
 * Result length = byteLength * 2 (each byte → 2 hex chars).
 */
function randomHex(byteLength: number): string {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Builds a raw API key: "oca_" prefix + 32 random hex chars.
 *
 * Example: oca_3f7a1c9e2b084d6f8a5e0c1234567890
 */
function generateRawKey(): string {
  return KEY_PREFIX_CHARS + randomHex(KEY_HEX_LENGTH / 2);
}

// SHA-256 hashing is provided by the shared hashApiKey() from supabase-client.ts.
// Using a single implementation prevents divergence between key generation and
// key verification paths.

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

  // --- Authorization: service-role callers only ---
  if (!isAuthorizedCaller(req)) {
    console.warn("[generate-api-key] Unauthorized caller — missing or invalid x-internal-secret");
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Parse body ---
  let body: GenerateApiKeyBody;
  try {
    body = await req.json() as GenerateApiKeyBody;
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Validate user_id ---
  const { user_id, label } = body;

  if (!user_id || typeof user_id !== "string") {
    return new Response(
      JSON.stringify({ error: "user_id is required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!UUID_REGEX.test(user_id)) {
    return new Response(
      JSON.stringify({ error: "user_id must be a valid UUID" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // --- Validate label (optional) ---
  const normalizedLabel: string | null =
    typeof label === "string" && label.trim().length > 0
      ? label.trim()
      : null;

  if (label !== undefined && normalizedLabel === null) {
    return new Response(
      JSON.stringify({ error: "label must be a non-empty string if provided" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[generate-api-key] Generating key for user ${user_id}` +
    (normalizedLabel ? ` with label "${normalizedLabel}"` : "")
  );

  const supabase = getSupabaseAdmin();

  // --- Check for duplicate label ---
  // A user may not have two keys with the same label; this keeps key management
  // readable in the dashboard. Labelless keys (null) are not subject to this
  // constraint — multiple null-label keys are allowed.
  if (normalizedLabel !== null) {
    const { data: existing, error: lookupError } = await supabase
      .from("api_keys")
      .select("id")
      .eq("user_id", user_id)
      .eq("label", normalizedLabel)
      .maybeSingle();

    if (lookupError) {
      console.error("[generate-api-key] Label uniqueness check failed:", lookupError.message);
      return new Response(
        JSON.stringify({ error: "An error occurred. Please try again." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (existing) {
      console.warn(
        `[generate-api-key] Duplicate label "${normalizedLabel}" for user ${user_id}`
      );
      return new Response(
        JSON.stringify({
          error: `An API key with the label "${normalizedLabel}" already exists for this user.`,
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
  }

  // --- Generate key material ---
  const rawKey = generateRawKey();
  const hashedKey = await hashApiKey(rawKey);

  // key_prefix is the first KEY_PREFIX_DISPLAY_LENGTH chars of the raw key.
  // "oca_3f7a1c9e" gives users enough context to identify keys in the dashboard
  // without exposing the full secret.
  const keyPrefix = rawKey.slice(0, KEY_PREFIX_DISPLAY_LENGTH);

  console.log(`[generate-api-key] Key prefix for user ${user_id}: ${keyPrefix}`);

  // --- Persist hashed key ---
  const { data: record, error: insertError } = await supabase
    .from("api_keys")
    .insert({
      user_id,
      hashed_key: hashedKey,
      key_prefix: keyPrefix,
      label: normalizedLabel,
    })
    .select()
    .single();

  if (insertError) {
    // Guard against a race where another insert with the same label sneaked in
    // between our uniqueness check and the insert.
    if (insertError.code === "23505") {
      return new Response(
        JSON.stringify({
          error: `An API key with the label "${normalizedLabel}" already exists for this user.`,
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.error("[generate-api-key] Insert failed:", insertError.message);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const inserted = record as ApiKeyRecord;

  console.log(
    `[generate-api-key] API key created — id: ${inserted.id}, ` +
    `user: ${user_id}, prefix: ${keyPrefix}`
  );

  // raw_key is returned only once and is never stored. The caller must save it.
  return new Response(
    JSON.stringify({
      success: true,
      data: {
        key_prefix: keyPrefix,
        raw_key: rawKey,
        label: normalizedLabel,
      },
    }),
    { status: 201, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
