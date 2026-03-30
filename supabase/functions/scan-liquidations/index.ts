import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin } from "../_shared/supabase-client.ts";
import { getServerSidePrice } from "../market-oracle/index.ts";
import { checkPriceAlerts } from "../manage-price-alerts/index.ts";
import { SYMBOL_TO_BINANCE } from "../_shared/symbols.ts";

// ---------------------------------------------------------------------------
// Execution-budget constants
// ---------------------------------------------------------------------------

/**
 * Number of open trades fetched per paginated loop iteration.
 * 50 is a comfortable page size: each batch touches only the breached subset
 * for RPC calls, so even a full page of 50 completes quickly.
 */
const BATCH_SIZE = 50;

/**
 * Hard ceiling on wall-clock execution time (ms).
 * Set 10 s below the Edge Function hard limit (60 s) so the response path
 * has enough headroom to flush and return before the runtime kills the isolate.
 */
const MAX_EXECUTION_MS = 50_000;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface OpenTrade {
  id: string;
  user_id: string;
  symbol: string;
  direction: "long" | "short";
  liquidation_price: number;
  margin: number;
  entry_price: number;
  quantity: number;
}

interface LiquidationOutcome {
  trade_id: string;
  user_id: string;
  symbol: string;
  direction: "long" | "short";
  liquidation_price: number;
  market_price: number;
  status: "liquidated" | "failed";
  error?: string;
}

interface SymbolScanResult {
  symbol: string;
  market_price: number;
  trades_scanned: number;
  trades_breached: number;
  trades_liquidated: number;
  trades_failed: number;
  skipped_reason?: string;
}

interface ScanSummary {
  started_at: string;
  finished_at: string;
  budget_exhausted: boolean;
  symbols_scanned: number;
  symbols_skipped: number;
  total_trades_scanned: number;
  total_trades_breached: number;
  total_trades_liquidated: number;
  total_trades_failed: number;
  high_liquidation_rate_warning: boolean;
  symbol_results: SymbolScanResult[];
  liquidations: LiquidationOutcome[];
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Price staleness guard: if the timestamp on the fetched price is older than
 * this many milliseconds, skip the symbol rather than liquidate with stale data.
 */
const MAX_PRICE_AGE_MS = 10_000; // 10 seconds

/**
 * If the ratio of breached trades to total scanned trades exceeds this threshold
 * in a single scan, emit a WARNING log. A sudden mass-liquidation event may
 * indicate a price feed anomaly rather than genuine market movement.
 * Processing still continues — the warning is purely observational.
 */
const HIGH_LIQUIDATION_RATE_THRESHOLD = 0.5; // 50%

// ---------------------------------------------------------------------------
// Liquidation condition helpers
// ---------------------------------------------------------------------------

/**
 * Returns true when a long position has hit its liquidation price.
 * Long trades are liquidated when the market falls to or below the liq price.
 */
function isLongBreached(marketPrice: number, liquidationPrice: number): boolean {
  return marketPrice <= liquidationPrice;
}

/**
 * Returns true when a short position has hit its liquidation price.
 * Short trades are liquidated when the market rises to or above the liq price.
 */
function isShortBreached(marketPrice: number, liquidationPrice: number): boolean {
  return marketPrice >= liquidationPrice;
}

function isBreached(trade: OpenTrade, marketPrice: number): boolean {
  if (trade.direction === "long") {
    return isLongBreached(marketPrice, trade.liquidation_price);
  }
  return isShortBreached(marketPrice, trade.liquidation_price);
}

// ---------------------------------------------------------------------------
// Price staleness guard
// ---------------------------------------------------------------------------

/**
 * Returns true when the ISO timestamp is within the acceptable freshness window.
 * `getServerSidePrice` stamps the timestamp at fetch time, so values older than
 * MAX_PRICE_AGE_MS indicate a cache hit from a stale Deno isolate or a slow
 * upstream response that arrived after a significant delay.
 */
function isPriceFresh(timestamp: string): boolean {
  const ageMs = Date.now() - new Date(timestamp).getTime();
  return ageMs <= MAX_PRICE_AGE_MS;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Cron invocations arrive as POST from the Supabase scheduler.
  // We also accept GET to allow manual triggering via the dashboard.
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Record wall-clock start time used by the execution-budget guard.
  const startTime = Date.now();
  const startedAt = new Date(startTime).toISOString();
  console.log(`[scan-liquidations] Scan started at ${startedAt}`);

  const supabase = getSupabaseAdmin();

  // Accumulate results across all batches.
  const symbolResultsMap = new Map<string, SymbolScanResult>();
  const allLiquidations: LiquidationOutcome[] = [];

  // Price cache: fetched once per symbol per invocation and reused across batches.
  // A symbol maps to null when its price fetch failed or the price was stale —
  // trades for that symbol are skipped for the remainder of this invocation.
  const priceCache = new Map<string, number | null>();

  let totalTradesScanned = 0;
  let totalBreached = 0;
  let budgetExhausted = false;

  // ---------------------------------------------------------------------------
  // Paginated scan loop
  //
  // Strategy (mirrors settle-tournament):
  //   • Always query from offset 0.
  //   • Successfully liquidated trades transition to status='liquidated' and
  //     drop out of the WHERE status='open' result set automatically.
  //   • Trades that fail the RPC stay 'open' and reappear on subsequent pages.
  //     To avoid an infinite loop on persistently failing trades within a single
  //     invocation we advance skipOffset by the count of failed trades seen so
  //     far, skipping past them until the next cron tick resets the cursor.
  // ---------------------------------------------------------------------------

  let skipOffset = 0; // tracks failed-trade positions to skip past this run

  while (true) {
    // --- Budget check before each batch ---
    const elapsed = Date.now() - startTime;
    if (elapsed >= MAX_EXECUTION_MS) {
      console.log(
        `[scan-liquidations] Budget exhausted after ${elapsed}ms at offset ${skipOffset}. ` +
        `Remaining open trades will be processed on the next cron tick.`
      );
      budgetExhausted = true;
      break;
    }

    // --- Fetch next page of open trades ---
    // The partial index idx_trades_liquidation_scan (symbol, liquidation_price)
    // WHERE status='open' makes this query efficient regardless of total table size.
    const { data: batchData, error: fetchError } = await supabase
      .from("trades")
      .select("id, user_id, symbol, direction, liquidation_price, margin, entry_price, quantity")
      .eq("status", "open")
      .range(skipOffset, skipOffset + BATCH_SIZE - 1);

    if (fetchError) {
      console.error("[scan-liquidations] Failed to fetch open trades:", fetchError.message);
      // Surface the error and stop this run. The next cron tick will retry.
      return new Response(
        JSON.stringify({ error: "Failed to fetch open trades. Scan aborted." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const batch = (batchData ?? []) as OpenTrade[];

    if (batch.length === 0) {
      // No more open trades — all pages exhausted.
      console.log(
        `[scan-liquidations] No more open trades to scan (total scanned this run: ${totalTradesScanned})`
      );
      break;
    }

    totalTradesScanned += batch.length;
    console.log(
      `[scan-liquidations] Batch of ${batch.length} trade(s) fetched (offset ${skipOffset}, ` +
      `total scanned so far: ${totalTradesScanned})`
    );

    // --- Group batch by symbol ---
    const batchBySymbol = new Map<string, OpenTrade[]>();
    for (const trade of batch) {
      const bucket = batchBySymbol.get(trade.symbol) ?? [];
      bucket.push(trade);
      batchBySymbol.set(trade.symbol, bucket);
    }

    let failedInBatch = 0;

    // --- Process each symbol group in this batch ---
    for (const [symbol, symbolTrades] of batchBySymbol) {
      const binanceSymbol = SYMBOL_TO_BINANCE[symbol];

      if (!binanceSymbol) {
        // Unknown symbol — should never happen if DB constraints are correct,
        // but guard defensively rather than crashing the entire scan.
        console.error(
          `[scan-liquidations] No Binance mapping for symbol "${symbol}". ` +
          `Skipping ${symbolTrades.length} trade(s).`
        );
        const existing = symbolResultsMap.get(symbol);
        symbolResultsMap.set(symbol, {
          symbol,
          market_price: 0,
          trades_scanned: (existing?.trades_scanned ?? 0) + symbolTrades.length,
          trades_breached: existing?.trades_breached ?? 0,
          trades_liquidated: existing?.trades_liquidated ?? 0,
          trades_failed: existing?.trades_failed ?? 0,
          skipped_reason: `No Binance symbol mapping for "${symbol}"`,
        });
        // These trades will never liquidate, so count them toward skip offset
        // to avoid re-visiting them on the next batch within this run.
        failedInBatch += symbolTrades.length;
        continue;
      }

      // --- Resolve market price (fetched once per symbol per invocation) ---
      if (!priceCache.has(symbol)) {
        try {
          const priceData = await getServerSidePrice(binanceSymbol);

          if (!isPriceFresh(priceData.timestamp)) {
            const ageMs = Date.now() - new Date(priceData.timestamp).getTime();
            console.warn(
              `[scan-liquidations] Price for ${symbol} is stale (${ageMs}ms old, ` +
              `limit ${MAX_PRICE_AGE_MS}ms). Skipping trades for this symbol this run.`
            );
            priceCache.set(symbol, null);
          } else {
            priceCache.set(symbol, priceData.price);
            console.log(
              `[scan-liquidations] ${symbol} market price: ${priceData.price} ` +
              `(timestamp: ${priceData.timestamp})`
            );
          }
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          console.error(
            `[scan-liquidations] Price fetch failed for ${symbol} (${binanceSymbol}): ${message}. ` +
            `Skipping trades for this symbol this run.`
          );
          priceCache.set(symbol, null);
        }
      }

      const marketPrice = priceCache.get(symbol)!;

      if (marketPrice === null) {
        // Price unavailable or stale — record skipped trades and advance offset.
        const existing = symbolResultsMap.get(symbol);
        symbolResultsMap.set(symbol, {
          symbol,
          market_price: 0,
          trades_scanned: (existing?.trades_scanned ?? 0) + symbolTrades.length,
          trades_breached: existing?.trades_breached ?? 0,
          trades_liquidated: existing?.trades_liquidated ?? 0,
          trades_failed: existing?.trades_failed ?? 0,
          skipped_reason: existing?.skipped_reason ??
            `Price feed unavailable or stale for ${symbol}`,
        });
        failedInBatch += symbolTrades.length;
        continue;
      }

      // --- Identify breached trades ---
      const breachedTrades = symbolTrades.filter((t) => isBreached(t, marketPrice));

      console.log(
        `[scan-liquidations] ${symbol}: ${symbolTrades.length} in batch, ` +
        `${breachedTrades.length} breached at price ${marketPrice}`
      );

      totalBreached += breachedTrades.length;

      // --- Liquidate each breached trade individually ---
      // A failure on one trade must NOT abort the rest of the batch.
      let liquidatedInSymbol = 0;
      let failedInSymbol = 0;

      for (const trade of breachedTrades) {
        const liquidationPrice = parseFloat(String(trade.liquidation_price));

        console.log(
          `[scan-liquidations] Liquidating trade ${trade.id} | ` +
          `user=${trade.user_id} | direction=${trade.direction} | ` +
          `liq_price=${liquidationPrice} | market_price=${marketPrice}`
        );

        const { error: rpcError } = await supabase.rpc("liquidate_trade_txn", {
          p_trade_id: trade.id,
          p_user_id: trade.user_id,
          p_market_price: marketPrice,
        });

        if (rpcError) {
          failedInSymbol++;
          failedInBatch++;
          const errMessage = rpcError.message ?? "Unknown RPC error";
          console.error(
            `[scan-liquidations] Failed to liquidate trade ${trade.id}: ${errMessage}`
          );
          allLiquidations.push({
            trade_id: trade.id,
            user_id: trade.user_id,
            symbol,
            direction: trade.direction,
            liquidation_price: liquidationPrice,
            market_price: marketPrice,
            status: "failed",
            error: errMessage,
          });
        } else {
          liquidatedInSymbol++;
          console.log(
            `[scan-liquidations] Trade ${trade.id} liquidated successfully | ` +
            `user=${trade.user_id} | market_price=${marketPrice}`
          );
          allLiquidations.push({
            trade_id: trade.id,
            user_id: trade.user_id,
            symbol,
            direction: trade.direction,
            liquidation_price: liquidationPrice,
            market_price: marketPrice,
            status: "liquidated",
          });
        }
      }

      // Merge into the running per-symbol result (a symbol can span multiple batches).
      const existing = symbolResultsMap.get(symbol);
      symbolResultsMap.set(symbol, {
        symbol,
        market_price: marketPrice,
        trades_scanned: (existing?.trades_scanned ?? 0) + symbolTrades.length,
        trades_breached: (existing?.trades_breached ?? 0) + breachedTrades.length,
        trades_liquidated: (existing?.trades_liquidated ?? 0) + liquidatedInSymbol,
        trades_failed: (existing?.trades_failed ?? 0) + failedInSymbol,
      });
    }

    // If this batch was shorter than BATCH_SIZE we have reached the last page.
    if (batch.length < BATCH_SIZE) {
      console.log(
        `[scan-liquidations] Final batch processed (${batch.length} rows < BATCH_SIZE ${BATCH_SIZE})`
      );
      break;
    }

    // Advance skipOffset past persistently-failing trades. Successfully
    // liquidated trades drop out of the open result set automatically.
    // Failed trades remain 'open', so we skip past them this run; the next
    // cron tick will start from offset 0 and retry them fresh.
    skipOffset += failedInBatch;
  }

  // ---------------------------------------------------------------------------
  // Price alerts — run ONCE per symbol after all liquidation batches complete.
  //
  // Piggybacks on the same prices already resolved during the scan.
  // Only fires for symbols that had a valid (non-stale) market price this run.
  // ---------------------------------------------------------------------------
  for (const [symbol, result] of symbolResultsMap) {
    if (result.skipped_reason || result.market_price === 0) continue;
    try {
      const alertResult = await checkPriceAlerts(supabase, symbol, result.market_price);
      if (alertResult.triggered > 0) {
        console.log(
          `[scan-liquidations] Price alerts: ${alertResult.triggered} triggered for ${symbol}`
        );
      }
      if (alertResult.errors.length > 0) {
        console.warn(
          `[scan-liquidations] Price alert errors for ${symbol}:`,
          alertResult.errors
        );
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(
        `[scan-liquidations] checkPriceAlerts failed for ${symbol}: ${message}`
      );
    }
  }

  // ---------------------------------------------------------------------------
  // High liquidation rate safety check
  //
  // If more than 50% of all scanned trades were breached in a single run this
  // could indicate a corrupted price feed rather than genuine market movement.
  // We log a WARNING but do not roll back — liquidations are already committed
  // atomically per trade inside the RPC.
  // ---------------------------------------------------------------------------
  const highLiquidationRateWarning =
    totalTradesScanned > 0 &&
    totalBreached / totalTradesScanned > HIGH_LIQUIDATION_RATE_THRESHOLD;

  if (highLiquidationRateWarning) {
    console.warn(
      `[scan-liquidations] WARNING: High liquidation rate detected. ` +
      `${totalBreached} of ${totalTradesScanned} scanned trades ` +
      `(${((totalBreached / totalTradesScanned) * 100).toFixed(1)}%) were breached ` +
      `in a single scan. Possible price feed anomaly. ` +
      `Liquidations have been committed — investigate price data integrity.`
    );
  }

  // ---------------------------------------------------------------------------
  // Build and return summary
  // ---------------------------------------------------------------------------
  const finishedAt = new Date().toISOString();

  const symbolResults = Array.from(symbolResultsMap.values());
  const totalLiquidated = allLiquidations.filter((l) => l.status === "liquidated").length;
  const totalFailed = allLiquidations.filter((l) => l.status === "failed").length;
  const skippedSymbols = symbolResults.filter((r) => r.skipped_reason !== undefined).length;

  const summary: ScanSummary = {
    started_at: startedAt,
    finished_at: finishedAt,
    budget_exhausted: budgetExhausted,
    symbols_scanned: symbolResults.length,
    symbols_skipped: skippedSymbols,
    total_trades_scanned: totalTradesScanned,
    total_trades_breached: totalBreached,
    total_trades_liquidated: totalLiquidated,
    total_trades_failed: totalFailed,
    high_liquidation_rate_warning: highLiquidationRateWarning,
    symbol_results: symbolResults,
    liquidations: allLiquidations,
  };

  console.log(
    `[scan-liquidations] Scan complete at ${finishedAt} | ` +
    `budget_exhausted=${budgetExhausted} | ` +
    `symbols=${symbolResults.length} (skipped=${skippedSymbols}) | ` +
    `trades_scanned=${totalTradesScanned} | breached=${totalBreached} | ` +
    `liquidated=${totalLiquidated} | failed=${totalFailed} | ` +
    `high_rate_warning=${highLiquidationRateWarning}`
  );

  return new Response(
    JSON.stringify({ success: true, data: summary }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
