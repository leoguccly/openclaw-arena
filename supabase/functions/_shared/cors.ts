/**
 * Standard CORS headers for Alpha Arena Edge Functions.
 *
 * Access-Control-Allow-Origin is driven by the CORS_ALLOWED_ORIGIN secret so
 * production can be locked to a specific origin (e.g. the Telegram Web App
 * domain) while local development continues to work with the '*' fallback.
 *
 * Set the origin in production:
 *   supabase secrets set CORS_ALLOWED_ORIGIN=https://openclaw-arena.vercel.app
 *
 * x-user-id / x-user-email are listed explicitly because the Supabase Flutter
 * SDK has a known bug (#21970) where custom headers are stripped; the frontend
 * sends these as fallback auth signals that the Edge Functions must accept.
 */
const ALLOWED_ORIGIN = Deno.env.get("CORS_ALLOWED_ORIGIN") ?? "*";

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-user-id, x-user-email, x-api-key",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
