import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";
import { getServerSidePrice } from "../_shared/price-feed.ts";

// ---------------------------------------------------------------------------
// Symbol whitelist
// ---------------------------------------------------------------------------

const ALLOWED_SYMBOLS = new Set(["BTCUSDT", "ETHUSDT"]);

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "GET") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  try {
    // --- Symbol extraction ---
    const url = new URL(req.url);
    const symbol = url.searchParams.get("symbol")?.toUpperCase() ?? "";

    if (!symbol) {
      return new Response(
        JSON.stringify({ error: "Query param 'symbol' is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!ALLOWED_SYMBOLS.has(symbol)) {
      return new Response(
        JSON.stringify({
          error: `Symbol not supported. Allowed: ${[...ALLOWED_SYMBOLS].join(", ")}`,
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // --- Rate limiting (keyed by IP for unauthenticated endpoint) ---
    const clientIp =
      req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
      req.headers.get("x-real-ip") ??
      "anonymous";

    const rateLimitResult = checkRateLimit(clientIp, "market-oracle");
    if (!rateLimitResult.allowed) {
      return new Response(
        JSON.stringify({
          error: "Rate limit exceeded",
          retryAfter: rateLimitResult.retryAfter,
        }),
        {
          status: 429,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
            "Retry-After": String(rateLimitResult.retryAfter ?? 1),
          },
        }
      );
    }

    // --- Fetch price (with cache) ---
    const priceData = await getServerSidePrice(symbol);

    return new Response(
      JSON.stringify({ success: true, data: priceData }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);

    if (message === "Price feed unavailable") {
      return new Response(
        JSON.stringify({ error: "Price feed unavailable. Please try again." }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.error("[market-oracle] Unexpected error:", err);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
