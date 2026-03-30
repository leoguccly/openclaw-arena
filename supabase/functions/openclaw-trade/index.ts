import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { runAgent } from "../_shared/agent-runner.ts";
import type { AgentConfig, Direction } from "../_shared/agent-runner.ts";

// ---------------------------------------------------------------------------
// Agent configuration — BTC/USDT momentum (SMA crossover)
// ---------------------------------------------------------------------------

/**
 * OpenClaw (original) trades BTC/USDT using a simple momentum strategy:
 *   current_price > SMA(12×5m)  →  LONG
 *   current_price < SMA(12×5m)  →  SHORT
 *   current_price == SMA         →  no signal (hold)
 */
const config: AgentConfig = {
  agentId: "00000000-0000-0000-0000-00000c1a0001",
  agentName: "[openclaw-trade]",
  symbol: "BTC/USDT",
  binanceSymbol: "BTCUSDT",
  leverage: 10,
  maxLeverage: 20,
  marginFraction: 0.02,
  maxMarginFraction: 0.05,
  marginJitterRange: 0.005,
  stopLossFraction: 0.05,
  minBalance: 100,
  maxJitterMs: 120_000,
  klineInterval: "5m",
  klineLimit: 12,
  computeSignal: (closes: number[], currentPrice: number): Direction | null => {
    const sma = closes.reduce((acc, v) => acc + v, 0) / closes.length;
    console.log(
      `[openclaw-trade] SMA(${closes.length})=${sma.toFixed(2)} | current=${currentPrice.toFixed(2)}`
    );
    if (currentPrice > sma) return "long";
    if (currentPrice < sma) return "short";
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

  // Cron-triggered via POST from the Supabase scheduler (every 10 minutes).
  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[openclaw-trade] Agent cycle started at ${new Date().toISOString()}`);

  try {
    const result = await runAgent(config);
    console.log(
      `[openclaw-trade] Cycle complete | action=${result.action} | detail=${result.detail}`
    );
    return new Response(
      JSON.stringify({ success: true, data: result }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[openclaw-trade] Agent cycle error:", message);
    return new Response(
      JSON.stringify({ error: "An error occurred." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
