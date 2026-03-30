/**
 * Shared agent runner engine for all OpenClaw AI personality agents.
 *
 * Each agent provides an AgentConfig with its identity, risk parameters, and
 * strategy function. This module owns all the shared logic: timing jitter,
 * balance/position reads, price fetch, kline fetch, stop-loss, signal flip,
 * and RPC calls. The personality-specific signal computation is injected via
 * the config.
 *
 * Chaos agents that need per-trade random leverage provide a
 * `randomizeLeverage` callback; the runner calls it instead of using the
 * static `config.leverage`.
 */

import { getSupabaseAdmin } from "./supabase-client.ts";
import { getServerSidePrice } from "./price-feed.ts";
import {
  computeLiquidationPrice,
  computeQuantity,
  computePnl,
  computeSettlement,
  computeUnrealisedPnl,
} from "./trade-math.ts";
import type { Direction } from "./trade-math.ts";

// ---------------------------------------------------------------------------
// Re-export Direction so callers can import from one place
// ---------------------------------------------------------------------------

export type { Direction };

// ---------------------------------------------------------------------------
// Binance kline response shape
// ---------------------------------------------------------------------------

/**
 * A single kline entry from the Binance REST API.
 * The Binance kline array schema:
 *   [0]  openTime   (number)
 *   [1]  open       (string)
 *   [2]  high       (string)
 *   [3]  low        (string)
 *   [4]  close      (string)  ← we use this
 *   [5]  volume     (string)
 *   ...  (remaining fields ignored)
 *
 * Index 0 is a number; indices 1-11 are strings. We express the full tuple
 * so TypeScript validates our array-index accesses without falling back to
 * `any`.
 */
type BinanceKlineEntry = [
  number,  // 0: openTime
  string,  // 1: open
  string,  // 2: high
  string,  // 3: low
  string,  // 4: close  ← we read this
  string,  // 5: volume
  number,  // 6: closeTime
  string,  // 7: quoteAssetVolume
  number,  // 8: numberOfTrades
  string,  // 9: takerBuyBaseAssetVolume
  string,  // 10: takerBuyQuoteAssetVolume
  string,  // 11: ignore
];

// ---------------------------------------------------------------------------
// AgentConfig — each personality supplies this
// ---------------------------------------------------------------------------

export interface AgentConfig {
  /** UUID that matches the AI user seed row (is_human = false). */
  agentId: string;
  /** Prefix used in all log lines, e.g. "[openclaw-trade]". */
  agentName: string;
  /** Display symbol traded, e.g. "BTC/USDT". */
  symbol: string;
  /** Binance ticker symbol, e.g. "BTCUSDT". */
  binanceSymbol: string;
  /** Base leverage for position sizing. */
  leverage: number;
  /** Hard cap on leverage regardless of base value. */
  maxLeverage: number;
  /** Base fraction of balance to allocate as margin (e.g. 0.02 = 2%). */
  marginFraction: number;
  /** Hard cap on margin fraction regardless of jitter (e.g. 0.05 = 5%). */
  maxMarginFraction: number;
  /** ± random offset applied to marginFraction (e.g. 0.005 = ±0.5%). */
  marginJitterRange: number;
  /** Fraction of margin loss that triggers a stop-loss close (e.g. 0.05 = 5%). */
  stopLossFraction: number;
  /** Minimum balance (USDT) below which the agent will not trade. */
  minBalance: number;
  /**
   * Maximum random delay (ms) applied at cycle start to prevent front-running.
   * Keep below the Edge Function timeout (~150 s → use 120_000 max).
   */
  maxJitterMs: number;

  /**
   * Strategy function: given the array of close prices from recent klines and
   * the current live price, return the desired direction or null (no signal).
   */
  computeSignal: (closes: number[], currentPrice: number) => Direction | null;

  /** Binance kline interval string, e.g. "5m". */
  klineInterval: string;
  /** Number of klines to fetch. */
  klineLimit: number;

  /**
   * Optional: if provided, called once per new-open to determine the leverage
   * for that specific trade. Used by openclaw-chaos for per-trade random leverage.
   * When absent, `Math.min(config.leverage, config.maxLeverage)` is used.
   */
  randomizeLeverage?: (config: AgentConfig) => number;
}

export interface AgentResult {
  action: string;
  detail: string;
}

// ---------------------------------------------------------------------------
// Internal types (not exported — callers use AgentConfig/AgentResult only)
// ---------------------------------------------------------------------------

interface OpenTradeRow {
  id: string;
  symbol: string;
  direction: Direction;
  leverage: number;
  margin: number;
  entry_price: number;
  liquidation_price: number;
  quantity: number;
  status: "open";
}

interface UserRow {
  balance: number;
}

// ---------------------------------------------------------------------------
// Cryptographic random helpers
// ---------------------------------------------------------------------------

/**
 * Returns a cryptographically random unsigned 32-bit integer.
 * Avoids Math.random() so the jitter cannot be predicted by an attacker
 * who knows the cron schedule.
 */
function cryptoUint32(): number {
  const bytes = new Uint8Array(4);
  crypto.getRandomValues(bytes);
  return new DataView(bytes.buffer).getUint32(0);
}

/**
 * Returns a cryptographically random integer in [0, maxMs).
 */
function randomJitter(maxMs: number): number {
  return cryptoUint32() % maxMs;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Margin computation with jitter
// ---------------------------------------------------------------------------

/**
 * Computes the margin to allocate for a new trade.
 *
 * The base fraction is config.marginFraction, but a cryptographically random
 * offset in [-marginJitterRange, +marginJitterRange] is added to make the
 * exact amount unpredictable to market observers. The result is capped at
 * maxMarginFraction regardless.
 */
function computeMarginWithJitter(
  balance: number,
  fraction: number,
  maxFraction: number,
  jitterRange: number
): number {
  const uniform = cryptoUint32() / 0x1_0000_0000; // [0, 1)
  const jitter = (uniform * 2 - 1) * jitterRange;  // [-jitterRange, +jitterRange]
  const effective = fraction + jitter;
  const preferred = balance * effective;
  const cap = balance * maxFraction;
  return Math.min(preferred, cap);
}

// ---------------------------------------------------------------------------
// Binance klines fetcher
// ---------------------------------------------------------------------------

/**
 * Fetches the last `limit` klines for `binanceSymbol` at the given interval
 * from the Binance public REST API and returns close prices as a number array.
 *
 * Throws "Kline feed unavailable" on any network or parse error so the caller
 * can surface a clean error without leaking Binance internals.
 */
async function fetchKlineCloses(
  binanceSymbol: string,
  interval: string,
  limit: number,
  agentName: string
): Promise<number[]> {
  const url =
    `https://api.binance.com/api/v3/klines?symbol=${binanceSymbol}&interval=${interval}&limit=${limit}`;

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(8_000),
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`${agentName} Binance klines fetch failed: ${message}`);
    throw new Error("Kline feed unavailable");
  }

  if (!response.ok) {
    console.error(`${agentName} Binance klines returned HTTP ${response.status}`);
    throw new Error("Kline feed unavailable");
  }

  let raw: unknown;
  try {
    raw = await response.json();
  } catch {
    console.error(`${agentName} Failed to parse Binance klines JSON`);
    throw new Error("Kline feed unavailable");
  }

  if (!Array.isArray(raw) || raw.length === 0) {
    console.error(`${agentName} Binance returned empty klines array`);
    throw new Error("Kline feed unavailable");
  }

  return (raw as BinanceKlineEntry[]).map((kline, i) => {
    const closePrice = parseFloat(String(kline[4]));
    if (isNaN(closePrice) || closePrice <= 0) {
      throw new Error(`Invalid close price in kline[${i}]`);
    }
    return closePrice;
  });
}

// ---------------------------------------------------------------------------
// Supabase RPC wrappers
// ---------------------------------------------------------------------------

async function closeTradeViaRpc(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  trade: OpenTradeRow,
  currentPrice: number,
  reason: string,
  agentId: string,
  agentName: string
): Promise<void> {
  const entryPrice = parseFloat(String(trade.entry_price));
  const quantity = parseFloat(String(trade.quantity));
  const margin = parseFloat(String(trade.margin));

  const realisedPnl = computePnl(trade.direction, quantity, entryPrice, currentPrice);
  const settlement = computeSettlement(margin, realisedPnl);

  console.log(
    `${agentName} Closing trade ${trade.id} | reason=${reason} | ` +
    `symbol=${trade.symbol} | direction=${trade.direction} | ` +
    `entry=${entryPrice} | exit=${currentPrice.toFixed(4)} | ` +
    `qty=${quantity.toFixed(8)} | margin=${margin} | ` +
    `pnl=${realisedPnl.toFixed(4)} | settlement=${settlement.toFixed(4)}`
  );

  const { error } = await supabase.rpc("close_trade_txn", {
    p_trade_id: trade.id,
    p_user_id: agentId,
    p_exit_price: currentPrice,
    p_realised_pnl: realisedPnl,
    p_settlement: settlement,
  });

  if (error) {
    console.error(`${agentName} close_trade_txn failed for trade ${trade.id}:`, error);
    throw new Error(`close_trade_txn RPC error: ${error.message}`);
  }

  console.log(`${agentName} Trade ${trade.id} closed successfully via RPC`);
}

async function openTradeViaRpc(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  direction: Direction,
  entryPrice: number,
  margin: number,
  config: AgentConfig
): Promise<void> {
  const leverage = config.randomizeLeverage
    ? config.randomizeLeverage(config)
    : Math.min(config.leverage, config.maxLeverage);

  const liquidationPrice = computeLiquidationPrice(entryPrice, direction, leverage);
  const quantity = computeQuantity(margin, leverage, entryPrice);

  console.log(
    `${config.agentName} Opening ${direction} ${config.symbol} x${leverage} | ` +
    `margin=${margin.toFixed(4)} | entry=${entryPrice.toFixed(4)} | ` +
    `liq=${liquidationPrice.toFixed(4)} | qty=${quantity.toFixed(8)}`
  );

  const { error } = await supabase.rpc("execute_trade_txn", {
    p_user_id: config.agentId,
    p_symbol: config.symbol,
    p_direction: direction,
    p_leverage: leverage,
    p_margin: margin,
    p_entry_price: entryPrice,
    p_liquidation_price: liquidationPrice,
    p_quantity: quantity,
  });

  if (error) {
    console.error(`${config.agentName} execute_trade_txn failed:`, error);
    throw new Error(`execute_trade_txn RPC error: ${error.message}`);
  }

  console.log(
    `${config.agentName} New ${direction} position opened at ${entryPrice.toFixed(4)}`
  );
}

// ---------------------------------------------------------------------------
// Core agent loop — shared engine
// ---------------------------------------------------------------------------

/**
 * Executes one full agent cycle:
 *   1. Anti-front-running timing jitter
 *   2. Read balance and any open position for this agent's symbol
 *   3. Balance guard
 *   4. Fetch live price
 *   5. Fetch klines, compute signal via config.computeSignal()
 *   6. If open position: check stop-loss, then check signal flip
 *   7. If no open position: open if there is a signal
 *
 * Returns an AgentResult describing what happened.
 */
export async function runAgent(config: AgentConfig): Promise<AgentResult> {
  // Step 1: timing jitter to prevent cron-schedule front-running
  const jitterMs = randomJitter(config.maxJitterMs);
  console.log(
    `${config.agentName} Applying ${(jitterMs / 1000).toFixed(1)}s timing jitter`
  );
  await sleep(jitterMs);

  const supabase = getSupabaseAdmin();

  // Step 2: fetch balance and open position in parallel
  const [userResult, tradesResult] = await Promise.all([
    supabase
      .from("users")
      .select("balance")
      .eq("id", config.agentId)
      .single<UserRow>(),
    supabase
      .from("trades")
      .select(
        "id, symbol, direction, leverage, margin, entry_price, liquidation_price, quantity, status"
      )
      .eq("user_id", config.agentId)
      .eq("symbol", config.symbol)
      .eq("status", "open")
      .limit(1),
  ]);

  if (userResult.error || !userResult.data) {
    const message = userResult.error?.message ?? "no data";
    console.error(`${config.agentName} Failed to fetch agent user row: ${message}`);
    throw new Error(`Could not read ${config.agentName} balance`);
  }

  const balance = parseFloat(String(userResult.data.balance));
  const openTrade: OpenTradeRow | null =
    tradesResult.data && tradesResult.data.length > 0
      ? (tradesResult.data[0] as OpenTradeRow)
      : null;

  console.log(
    `${config.agentName} Balance=${balance.toFixed(4)} USDT | ` +
    `openPosition=${openTrade ? `${openTrade.direction} (id=${openTrade.id})` : "none"}`
  );

  // Step 3: balance guard
  if (balance < config.minBalance) {
    const msg =
      `Balance ${balance.toFixed(4)} USDT is below minimum ${config.minBalance} USDT. Skipping.`;
    console.warn(`${config.agentName} ${msg}`);
    return { action: "skip", detail: msg };
  }

  // Step 4: fetch live price
  let currentPrice: number;
  try {
    const priceData = await getServerSidePrice(config.binanceSymbol);
    currentPrice = priceData.price;
    console.log(`${config.agentName} Live ${config.symbol} price: ${currentPrice.toFixed(4)}`);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`${config.agentName} Price feed error: ${message}`);
    throw new Error("Price feed unavailable — aborting agent cycle");
  }

  // Step 5: fetch klines and compute signal
  let closes: number[];
  try {
    closes = await fetchKlineCloses(
      config.binanceSymbol,
      config.klineInterval,
      config.klineLimit,
      config.agentName
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`${config.agentName} Kline feed error: ${message}`);
    throw new Error("Kline feed unavailable — aborting agent cycle");
  }

  const signal = config.computeSignal(closes, currentPrice);

  if (!signal) {
    const msg = `No signal from strategy (${config.klineLimit} klines, price=${currentPrice.toFixed(4)}). Holding.`;
    console.log(`${config.agentName} ${msg}`);
    return { action: "hold", detail: msg };
  }

  console.log(`${config.agentName} Signal: ${signal.toUpperCase()}`);

  // Step 6: evaluate open position
  if (openTrade) {
    const entryPrice = parseFloat(String(openTrade.entry_price));
    const quantity = parseFloat(String(openTrade.quantity));
    const margin = parseFloat(String(openTrade.margin));

    const unrealisedPnl = computeUnrealisedPnl(
      openTrade.direction,
      quantity,
      entryPrice,
      currentPrice
    );
    const unrealisedLossFraction =
      unrealisedPnl < 0 ? Math.abs(unrealisedPnl) / margin : 0;

    console.log(
      `${config.agentName} Open trade ${openTrade.id} | ` +
      `unrealisedPnl=${unrealisedPnl.toFixed(4)} | ` +
      `lossFraction=${(unrealisedLossFraction * 100).toFixed(2)}%`
    );

    // 6a. Stop-loss check
    if (unrealisedLossFraction >= config.stopLossFraction) {
      console.log(
        `${config.agentName} Stop-loss triggered ` +
        `(loss=${(unrealisedLossFraction * 100).toFixed(2)}% >= ${config.stopLossFraction * 100}%)`
      );
      await closeTradeViaRpc(
        supabase, openTrade, currentPrice, "stop_loss", config.agentId, config.agentName
      );
      return {
        action: "stop_loss",
        detail:
          `Closed ${openTrade.direction} trade ${openTrade.id} due to stop-loss. ` +
          `Loss=${(unrealisedLossFraction * 100).toFixed(2)}%`,
      };
    }

    // 6b. Signal flip check
    if (openTrade.direction !== signal) {
      console.log(
        `${config.agentName} Signal flipped from ${openTrade.direction} to ${signal}. ` +
        `Closing then reopening.`
      );
      await closeTradeViaRpc(
        supabase, openTrade, currentPrice, "signal_flip", config.agentId, config.agentName
      );

      // Re-read balance after settlement changes it
      const { data: refreshedUser, error: refreshError } = await supabase
        .from("users")
        .select("balance")
        .eq("id", config.agentId)
        .single<UserRow>();

      if (refreshError || !refreshedUser) {
        console.error(
          `${config.agentName} Could not refresh balance after close. Skipping open.`,
          refreshError
        );
        return {
          action: "signal_flip_close_only",
          detail: `Closed ${openTrade.id} on signal flip but could not refresh balance for new open.`,
        };
      }

      const refreshedBalance = parseFloat(String(refreshedUser.balance));

      if (refreshedBalance < config.minBalance) {
        const msg =
          `After close, balance ${refreshedBalance.toFixed(4)} USDT < ${config.minBalance}. Skipping open.`;
        console.warn(`${config.agentName} ${msg}`);
        return { action: "signal_flip_close_only", detail: msg };
      }

      const newMargin = computeMarginWithJitter(
        refreshedBalance,
        config.marginFraction,
        config.maxMarginFraction,
        config.marginJitterRange
      );
      await openTradeViaRpc(supabase, signal, currentPrice, newMargin, config);

      return {
        action: "signal_flip",
        detail:
          `Closed ${openTrade.direction} trade ${openTrade.id}. ` +
          `Opened ${signal} at ${currentPrice.toFixed(4)} with margin=${newMargin.toFixed(4)}.`,
      };
    }

    // 6c. Signal agrees with open position — hold
    const msg =
      `Signal ${signal.toUpperCase()} agrees with open ${openTrade.direction} position. Holding.`;
    console.log(`${config.agentName} ${msg}`);
    return { action: "hold", detail: msg };
  }

  // Step 7: no open position — open one
  const margin = computeMarginWithJitter(
    balance,
    config.marginFraction,
    config.maxMarginFraction,
    config.marginJitterRange
  );
  await openTradeViaRpc(supabase, signal, currentPrice, margin, config);

  return {
    action: "open",
    detail: `Opened ${signal} at ${currentPrice.toFixed(4)} with margin=${margin.toFixed(4)} USDT.`,
  };
}
