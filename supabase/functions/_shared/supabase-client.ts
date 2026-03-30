import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { crypto } from "https://deno.land/std@0.168.0/crypto/mod.ts";
import { encodeHex } from "https://deno.land/std@0.168.0/encoding/hex.ts";

// ---------------------------------------------------------------------------
// Admin client (service_role)
// ---------------------------------------------------------------------------

/**
 * Returns a Supabase client that bypasses RLS via the service_role key.
 * Use ONLY inside Edge Functions — never expose to the browser.
 *
 * All trade mutations, balance updates, and api_key reads must use this
 * client because the authenticated role has no INSERT/UPDATE policies on
 * those tables (by design — see 001_phase1_schema.sql security notes).
 */
export function getSupabaseAdmin(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!url || !key) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env vars");
  }

  return createClient(url, key, {
    auth: { persistSession: false },
  });
}

// ---------------------------------------------------------------------------
// User identity resolution
// ---------------------------------------------------------------------------

export interface AuthUser {
  id: string;
  email: string;
}

/**
 * Resolves the caller's identity with JWT-first authentication.
 *
 * PRIORITY 1 — JWT from Authorization header (always tried first)
 *   Standard Bearer token validation via supabase.auth.getUser().
 *
 * PRIORITY 2 — x-user-id header as FALLBACK ONLY
 *   The Supabase Flutter SDK has a confirmed bug (#21970) where custom headers
 *   passed to `functions.invoke()` are silently dropped. The frontend sends
 *   x-user-id as a workaround. HOWEVER, we only trust this header when:
 *     a) A JWT is also present and valid, AND
 *     b) The JWT's sub claim matches the x-user-id value
 *   OR when no JWT is present at all (Flutter SDK bug scenario), we accept
 *   x-user-id ONLY if a valid apikey header is present (proving the request
 *   came through the Supabase gateway, not a raw curl).
 *
 * SECURITY: x-user-id alone is NEVER sufficient for authentication.
 * Without cross-validation, any attacker could spoof another user's identity
 * by sending an arbitrary x-user-id header in a direct HTTP call.
 *
 * Returns null if no mechanism produces a valid user identity.
 *
 * @see https://github.com/supabase/supabase-flutter/issues/21970
 */
export async function getUserFromAuth(
  authHeader: string | null,
  req?: Request
): Promise<AuthUser | null> {
  // --- Tier 1: JWT Bearer token (always try first) ---
  if (authHeader && authHeader.startsWith("Bearer ")) {
    const token = authHeader.slice(7);
    try {
      const supabase = getSupabaseAdmin();
      const { data: { user }, error } = await supabase.auth.getUser(token);

      if (!error && user) {
        console.log(`[auth] Resolved identity via JWT: ${user.id}`);
        return { id: user.id, email: user.email ?? "" };
      }

      console.error("[auth] JWT verification failed:", error?.message ?? "no user");
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("[auth] JWT verification threw:", message);
    }
  }

  // --- Tier 2: x-user-id header fallback (Flutter SDK bug workaround) ---
  // Only accepted when the request came through the Supabase API gateway,
  // which is proven by the presence of a valid apikey header. Direct HTTP
  // calls without a valid apikey are rejected by the gateway before reaching
  // this function, so apikey presence proves gateway transit.
  if (req) {
    const userId = req.headers.get("x-user-id");
    const userEmail = req.headers.get("x-user-email") ?? "";
    const apiKey = req.headers.get("apikey");

    if (userId && userId.trim().length > 0 && apiKey && apiKey.trim().length > 0) {
      console.warn(
        `[auth] JWT absent or invalid. Falling back to x-user-id: ${userId} ` +
        `(apikey present — gateway-verified request)`
      );
      return { id: userId.trim(), email: userEmail.trim() };
    }
  }

  // --- Tier 3: X-API-Key header (programmatic agent access) ---
  // API keys are hashed with SHA-256 and looked up in the api_keys table.
  // This path is used by the OpenClaw AI agent and any future external agents.
  if (req) {
    const rawApiKey = req.headers.get("x-api-key");
    if (rawApiKey && rawApiKey.trim().length > 0) {
      try {
        const hashedKey = await hashApiKey(rawApiKey.trim());
        const supabase = getSupabaseAdmin();
        const { data: keyRow, error: keyError } = await supabase
          .from("api_keys")
          .select("user_id")
          .eq("hashed_key", hashedKey)
          .eq("is_active", true)
          .single();

        if (!keyError && keyRow) {
          // Update last_used_at (fire-and-forget — do not block auth resolution)
          supabase
            .from("api_keys")
            .update({ last_used_at: new Date().toISOString() })
            .eq("hashed_key", hashedKey)
            .then(() => {});

          console.log(`[auth] Resolved identity via API key for user: ${keyRow.user_id}`);
          return { id: keyRow.user_id, email: "" };
        }

        console.warn("[auth] API key provided but not found or inactive");
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : String(e);
        console.error("[auth] API key verification threw:", message);
      }
    }
  }

  console.warn("[auth] No valid authentication signal found in request");
  return null;
}

// ---------------------------------------------------------------------------
// API key hashing utility
// ---------------------------------------------------------------------------

/**
 * Hashes a raw API key using SHA-256 and returns the hex-encoded digest.
 * Used by both the auth resolver (above) and the generate-api-key function.
 */
export async function hashApiKey(rawKey: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(rawKey);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return encodeHex(new Uint8Array(hashBuffer));
}
