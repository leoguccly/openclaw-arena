import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { runAgent } from "../_shared/agent-runner.ts";
import type { AgentConfig, Direction } from "../_shared/agent-runner.ts";

// ---------------------------------------------------------------------------
// Agent configuration — ETH/USDT mean reversion
// ---------------------------------------------------------------------------

/**
 * OpenClaw Conservative trades ETH/USDT using mean reversion against SMA(24×5m).
 * This is deliberately the inverse of the openclaw-trade momentum strategy:
 *
 *   price > SMA * 1.02  (≥2% above mean, overbought)  →  SHORT
 *   price < SMA * 0.98  (≥2% below mean, oversold)    →  LONG
 *   within ±2% band                                   →  no signal (hold)
 *
 * Parameters are more conservative than openclaw-trade:
 *   - ETH instead of BTC
 *   - 5x leverage (vs 10x)
 *   - 1% base margin (vs 2%)
 *   - 3% stop-loss (vs 5%)
 *   - 24 klines (vs 12)
 */

const MEAN_REVERSION_UPPER = 1.02; // price > SMA * 1.02 → SHORT
const MEAN_REVERSION_LOWER = 0.98; // price < SMA * 0.98 → LONG

const config: AgentConfig = {
  agentId: "00000000-0000-0000-0000-00000c1a0002",
  agentName: "[openclaw-conservative]",
  symbol: "ETH/USDT",
  binanceSymbol: "ETHUSDT",
  leverage: 5,
  maxLeverage: 5,
  marginFraction: 0.01,
  maxMarginFraction: 0.05,
  marginJitterRange: 0.005,
  stopLossFraction: 0.03,
  minBalance: 100,
  maxJitterMs: 120_000,
  klineInterval: "5m",
  klineLimit: 24,
  computeSignal: (closes: number[], currentPrice: number): Direction | null => {
    const sma = closes.reduce((acc, v) => acc + v, 0) / closes.length;
    const upperBand = sma * MEAN_REVERSION_UPPER;
    const lowerBand = sma * MEAN_REVERSION_LOWER;
    const deviationPct = ((currentPrice - sma) / sma) * 100;

    console.log(
      `[openclaw-conservative] SMA(${closes.length})=${sma.toFixed(4)} | ` +
      `current=${currentPrice.toFixed(4)} | deviation=${deviationPct.toFixed(2)}% | ` +
      `upper_band=${upperBand.toFixed(4)} | lower_band=${lowerBand.toFixed(4)}`
    );

    if (currentPrice > upperBand) return "short";
    if (currentPrice < lowerBand) return "long";
    return null;
  },
};

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Cron-triggered via POST from the Supabase scheduler (every 15 minutes).
  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[openclaw-conservative] Agent cycle started at ${new Date().toISOString()}`
  );

  try {
    const result = await runAgent(config);
    console.log(
      `[openclaw-conservative] Cycle complete | action=${result.action} | detail=${result.detail}`
    );
    return new Response(
      JSON.stringify({ success: true, data: result }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[openclaw-conservative] Agent cycle error:", message);
    return new Response(
      JSON.stringify({ error: "An error occurred." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
