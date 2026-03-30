/**
 * In-memory sliding-window rate limiter for Supabase Edge Functions.
 *
 * IMPORTANT: Deno isolates are typically kept warm but are NOT shared across
 * concurrent invocations. This means the in-memory Map is effective against
 * sequential abuse and moderate concurrency, but cannot enforce hard global
 * limits under extreme parallelism. For a fully distributed rate limit, move
 * to a Redis/Upstash backend. For the MVP this is sufficient.
 *
 * Strategy: per-user, per-action sliding window.
 * Each entry tracks the timestamps of recent requests within the window.
 * On each check, expired timestamps are evicted before counting.
 */

interface WindowEntry {
  /** Timestamps (ms since epoch) of requests within the current window. */
  timestamps: number[];
}

// Global store: key = `${userId}:${action}`
const store = new Map<string, WindowEntry>();

// ---------------------------------------------------------------------------
// Action configurations
// ---------------------------------------------------------------------------

interface RateLimitConfig {
  /** Maximum number of requests allowed within the window. */
  maxRequests: number;
  /** Duration of the sliding window in milliseconds. */
  windowMs: number;
}

const CONFIGS: Record<string, RateLimitConfig> = {
  "execute-trade": {
    maxRequests: 1,
    windowMs: 5_000, // 1 trade per 5 seconds per user
  },
  "market-oracle": {
    maxRequests: 10,
    windowMs: 10_000, // 10 price queries per 10 seconds per user
  },
  "join-tournament": {
    maxRequests: 3,
    windowMs: 60_000, // 3 join attempts per minute per user
  },
};

/** Fallback config for actions not explicitly listed. */
const DEFAULT_CONFIG: RateLimitConfig = {
  maxRequests: 20,
  windowMs: 60_000,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export interface RateLimitResult {
  allowed: boolean;
  /** Seconds until the oldest window entry expires. Present only when denied. */
  retryAfter?: number;
}

/**
 * Checks whether `userId` is allowed to perform `action` right now.
 *
 * Side-effects: updates the in-memory store (evicts expired entries, records
 * the current timestamp if allowed).
 */
export function checkRateLimit(userId: string, action: string): RateLimitResult {
  const config = CONFIGS[action] ?? DEFAULT_CONFIG;
  const key = `${userId}:${action}`;
  const now = Date.now();
  const windowStart = now - config.windowMs;

  // Retrieve or initialise the entry for this key.
  const entry = store.get(key) ?? { timestamps: [] };

  // Evict timestamps that have fallen outside the current window.
  entry.timestamps = entry.timestamps.filter((ts) => ts > windowStart);

  if (entry.timestamps.length >= config.maxRequests) {
    // The oldest timestamp in the window determines when the caller may retry.
    const oldestTs = entry.timestamps[0];
    const retryAfterMs = oldestTs + config.windowMs - now;
    const retryAfterSec = Math.ceil(retryAfterMs / 1_000);

    store.set(key, entry);
    return { allowed: false, retryAfter: retryAfterSec };
  }

  // Record this request.
  entry.timestamps.push(now);
  store.set(key, entry);

  return { allowed: true };
}
