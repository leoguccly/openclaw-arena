import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface BinanceTickerResponse {
  symbol: string;
  price: string;
}

interface PriceResult {
  symbol: string;
  price: number;
  timestamp: string;
  source: "binance";
}

// ---------------------------------------------------------------------------
// Symbol whitelist
// ---------------------------------------------------------------------------

const ALLOWED_SYMBOLS = new Set(["BTCUSDT", "ETHUSDT"]);

// ---------------------------------------------------------------------------
// In-memory price cache — 2-second TTL
// Reduces Binance API calls under concurrent frontend polling.
// ---------------------------------------------------------------------------

interface CacheEntry {
  data: PriceResult;
  expiresAt: number;
}

const priceCache = new Map<string, CacheEntry>();

const CACHE_TTL_MS = 2_000;

function getCachedPrice(symbol: string): PriceResult | null {
  const entry = priceCache.get(symbol);
  if (entry && Date.now() < entry.expiresAt) {
    return entry.data;
  }
  priceCache.delete(symbol);
  return null;
}

function setCachedPrice(symbol: string, data: PriceResult): void {
  priceCache.set(symbol, {
    data,
    expiresAt: Date.now() + CACHE_TTL_MS,
  });
}

// ---------------------------------------------------------------------------
// Binance fetch
// ---------------------------------------------------------------------------

/**
 * Fetches the current spot price for `symbol` from the Binance public REST API.
 * Throws on network error or unexpected response shape.
 */
async function fetchBinancePrice(symbol: string): Promise<PriceResult> {
  const url = `https://api.binance.com/api/v3/ticker/price?symbol=${symbol}`;

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { "Accept": "application/json" },
      // 5-second hard timeout — Binance is fast; we don't want to hold up the
      // execute-trade path if the price feed is sluggish.
      signal: AbortSignal.timeout(5_000),
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[market-oracle] Binance fetch failed for ${symbol}:`, message);
    throw new Error("Price feed unavailable");
  }

  if (!response.ok) {
    console.error(
      `[market-oracle] Binance returned HTTP ${response.status} for ${symbol}`
    );
    throw new Error("Price feed unavailable");
  }

  let body: BinanceTickerResponse;
  try {
    body = await response.json() as BinanceTickerResponse;
  } catch {
    console.error(`[market-oracle] Could not parse Binance response for ${symbol}`);
    throw new Error("Price feed unavailable");
  }

  const price = parseFloat(body.price);
  if (isNaN(price) || price <= 0) {
    console.error(`[market-oracle] Invalid price value from Binance: ${body.price}`);
    throw new Error("Price feed unavailable");
  }

  return {
    symbol,
    price,
    timestamp: new Date().toISOString(),
    source: "binance",
  };
}

// ---------------------------------------------------------------------------
// Public helper — used by execute-trade and close-trade to get server-side price
// ---------------------------------------------------------------------------

/**
 * Returns a fresh (or recently cached) price for `symbol`.
 * Exported so sibling Edge Functions can share this logic without an HTTP hop.
 * Throws with message "Price feed unavailable" on failure.
 */
export async function getServerSidePrice(symbol: string): Promise<PriceResult> {
  const cached = getCachedPrice(symbol);
  if (cached) {
    console.log(
      `[market-oracle] Cache hit for ${symbol}: ${cached.price}`
    );
    return cached;
  }

  const result = await fetchBinancePrice(symbol);
  setCachedPrice(symbol, result);
  console.log(
    `[market-oracle] Fetched fresh price for ${symbol}: ${result.price}`
  );
  return result;
}

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
    // Use forwarded IP as the rate-limit key; fall back to a generic bucket.
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
