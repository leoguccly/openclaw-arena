import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { runAgent } from "../_shared/agent-runner.ts";
import type { AgentConfig, Direction } from "../_shared/agent-runner.ts";

// ---------------------------------------------------------------------------
// Chaos-specific random helpers
// ---------------------------------------------------------------------------

function cryptoUint32(): number {
  const bytes = new Uint8Array(4);
  crypto.getRandomValues(bytes);
  return new DataView(bytes.buffer).getUint32(0);
}

/** Random integer in [min, max] inclusive using rejection sampling (no modulo bias). */
function randomIntInRange(min: number, max: number): number {
  const range = max - min + 1;
  const limit = Math.floor(0x1_0000_0000 / range) * range;
  let value: number;
  do { value = cryptoUint32(); } while (value >= limit);
  return min + (value % range);
}

const SYMBOLS = ["BTC/USDT", "ETH/USDT"] as const;
const BINANCE_SYMBOLS: Record<string, string> = {
  "BTC/USDT": "BTCUSDT",
  "ETH/USDT": "ETHUSDT",
};

const MIN_LEVERAGE = 5;
const MAX_LEVERAGE = 50;

// ---------------------------------------------------------------------------
// Agent configuration — random symbol, random leverage, random direction
// ---------------------------------------------------------------------------

/**
 * OpenClaw Chaos has no deterministic signal. Each cycle it:
 *   - Picks BTC/USDT or ETH/USDT at random
 *   - Generates a random direction (50/50 long/short)
 *   - Uses a random leverage (5x–50x) per trade via randomizeLeverage
 *   - Has a very wide stop-loss (10%) — high volatility by design
 *
 * The shared runAgent loop interprets a random direction as the "signal".
 * When a position is open, ~50% of cycles will produce a direction that
 * differs from the held direction, triggering a chaos flip (signal_flip action).
 */
function buildChaosConfig(): AgentConfig {
  // Pick symbol once per cycle — used for both price fetch and trade query.
  const symbol = SYMBOLS[randomIntInRange(0, SYMBOLS.length - 1)];
  const binanceSymbol = BINANCE_SYMBOLS[symbol];

  return {
    agentId: "00000000-0000-0000-0000-00000c1a0003",
    agentName: "[openclaw-chaos]",
    symbol,
    binanceSymbol,
    leverage: MIN_LEVERAGE,   // base; overridden per-open by randomizeLeverage
    maxLeverage: MAX_LEVERAGE,
    marginFraction: 0.01,     // 1% base; jitter gives [0.5%, 3%]
    maxMarginFraction: 0.05,
    marginJitterRange: 0.01,  // wider jitter range for chaos character
    stopLossFraction: 0.10,   // 10% — high risk tolerance by design
    minBalance: 100,
    maxJitterMs: 120_000,
    klineInterval: "5m",
    klineLimit: 1,            // chaos ignores kline data — signal is pure random
    computeSignal: (_closes: number[], _currentPrice: number): Direction | null => {
      // Pure random direction — no technical analysis.
      // Lowest bit of a crypto random uint32 is perfectly uniform.
      const lowestBit = cryptoUint32() & 0x1;
      return lowestBit === 0 ? "long" : "short";
    },
    randomizeLeverage: (_config: AgentConfig): number => {
      return randomIntInRange(MIN_LEVERAGE, MAX_LEVERAGE);
    },
  };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Cron-triggered via POST from the Supabase scheduler (every 20 minutes).
  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[openclaw-chaos] Agent cycle started at ${new Date().toISOString()}`);

  try {
    // Build a fresh config per cycle so the symbol and signal are independently
    // random on every invocation.
    const config = buildChaosConfig();
    console.log(`[openclaw-chaos] Target symbol for this cycle: ${config.symbol}`);

    const result = await runAgent(config);
    console.log(
      `[openclaw-chaos] Cycle complete | action=${result.action} | detail=${result.detail}`
    );
    return new Response(
      JSON.stringify({ success: true, data: result }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[openclaw-chaos] Agent cycle error:", message);
    return new Response(
      JSON.stringify({ error: "An error occurred." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
