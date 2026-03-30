// ---------------------------------------------------------------------------
// Shared price feed — extracted from market-oracle to avoid serve() conflicts
// ---------------------------------------------------------------------------
// When another Edge Function imports market-oracle/index.ts directly,
// market-oracle's serve() call executes and hijacks the request handler.
// This module contains ONLY the price fetching logic with no serve() call,
// making it safe to import from any Edge Function.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PriceResult {
  symbol: string;
  price: number;
  timestamp: string;
  source: "binance";
}

interface BinanceTickerResponse {
  symbol: string;
  price: string;
}

// ---------------------------------------------------------------------------
// In-memory price cache — 2-second TTL
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

async function fetchBinancePrice(symbol: string): Promise<PriceResult> {
  const url = `https://api.binance.com/api/v3/ticker/price?symbol=${symbol}`;

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(5_000),
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[price-feed] Binance fetch failed for ${symbol}:`, message);
    throw new Error("Price feed unavailable");
  }

  if (!response.ok) {
    console.error(`[price-feed] Binance returned HTTP ${response.status} for ${symbol}`);
    throw new Error("Price feed unavailable");
  }

  let body: BinanceTickerResponse;
  try {
    body = (await response.json()) as BinanceTickerResponse;
  } catch {
    console.error(`[price-feed] Could not parse Binance response for ${symbol}`);
    throw new Error("Price feed unavailable");
  }

  const price = parseFloat(body.price);
  if (isNaN(price) || price <= 0) {
    console.error(`[price-feed] Invalid price value from Binance: ${body.price}`);
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
// Public API
// ---------------------------------------------------------------------------

/**
 * Returns a fresh (or recently cached) price for `symbol`.
 * Safe to import from any Edge Function — no serve() side effect.
 */
export async function getServerSidePrice(symbol: string): Promise<PriceResult> {
  const cached = getCachedPrice(symbol);
  if (cached) {
    console.log(`[price-feed] Cache hit for ${symbol}: ${cached.price}`);
    return cached;
  }

  const result = await fetchBinancePrice(symbol);
  setCachedPrice(symbol, result);
  console.log(`[price-feed] Fetched fresh price for ${symbol}: ${result.price}`);
  return result;
}
