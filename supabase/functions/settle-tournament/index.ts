import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin } from "../_shared/supabase-client.ts";
import { getServerSidePrice } from "../_shared/price-feed.ts";
import { toBinanceSymbol } from "../_shared/symbols.ts";
import { computePnl, computeSettlement } from "../_shared/trade-math.ts";

// ---------------------------------------------------------------------------
// Execution-budget constants
// ---------------------------------------------------------------------------

/**
 * Number of trades processed per loop iteration.
 * Kept small enough that each batch completes well within one HTTP round-trip.
 */
const BATCH_SIZE = 20;

/**
 * Hard ceiling on wall-clock execution time (ms).
 * Set 10 s below the Edge Function hard limit (60 s) to give the response
 * path enough headroom to flush and return before the runtime kills the isolate.
 */
const MAX_EXECUTION_MS = 50_000;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface Tournament {
  id: string;
  status: "upcoming" | "active" | "settling" | "completed";
  start_at: string;
  end_at: string;
}

interface OpenTrade {
  id: string;
  tournament_id: string;
  user_id: string;
  symbol: string;
  direction: "long" | "short";
  quantity: number;
  entry_price: number;
  margin: number;
}

interface SettleSummary {
  activatedTournaments: string[];
  settledTournaments: string[];
  /** Tournaments for which force-close completed but there were still open
   *  trades remaining when the execution budget was exhausted.  The next
   *  cron tick will resume them (tournament status stays `settling`). */
  partialTournaments: string[];
  forceClosedTrades: number;
  errors: string[];
}

// ---------------------------------------------------------------------------
// Force-close open trades for a tournament — batched, budget-aware
// ---------------------------------------------------------------------------

/**
 * Iterates over open trades in pages of BATCH_SIZE.
 *
 * Returns `true` when ALL open trades have been processed (or there were none),
 * and `false` when the execution budget was exhausted before finishing — the
 * caller should treat the tournament as partially settled and skip the final
 * settlement RPC so the next cron tick can resume.
 */
async function forceCloseTrades(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  tournament: Tournament,
  summary: SettleSummary,
  startTime: number
): Promise<boolean> {
  // Resolve current market prices once per symbol within this invocation.
  const priceCache = new Map<string, number>();

  let offset = 0;
  let totalFetched = 0;

  while (true) {
    // --- Budget check before each batch ---
    const elapsed = Date.now() - startTime;
    if (elapsed >= MAX_EXECUTION_MS) {
      console.log(
        `[settle-tournament] Budget exhausted after ${elapsed}ms — ` +
        `stopping force-close for tournament ${tournament.id} at offset ${offset}. ` +
        `Remaining open trades will be processed on the next cron tick.`
      );
      return false;
    }

    // --- Fetch next batch ---
    const { data: trades, error: fetchError } = await supabase
      .from("trades")
      .select("id, tournament_id, user_id, symbol, direction, quantity, entry_price, margin")
      .eq("tournament_id", tournament.id)
      .eq("status", "open")
      .range(offset, offset + BATCH_SIZE - 1);

    if (fetchError) {
      const msg =
        `[settle-tournament] Failed to fetch trades for tournament ${tournament.id} ` +
        `(offset ${offset}): ${fetchError.message}`;
      console.error(msg);
      summary.errors.push(msg);
      // A fetch failure is not a budget issue — surface the error but stop
      // this round; the next tick will retry from the beginning (offset 0
      // because successfully closed trades will no longer be `open`).
      return false;
    }

    if (!trades || trades.length === 0) {
      // No more open trades — we are done.
      if (totalFetched === 0) {
        console.log(
          `[settle-tournament] No open trades found for tournament ${tournament.id}`
        );
      } else {
        console.log(
          `[settle-tournament] All open trades processed for tournament ${tournament.id} ` +
          `(${totalFetched} total fetched this run)`
        );
      }
      return true;
    }

    totalFetched += trades.length;
    console.log(
      `[settle-tournament] Processing batch of ${trades.length} trade(s) for ` +
      `tournament ${tournament.id} (offset ${offset})`
    );

    // --- Process each trade in the batch ---
    for (const trade of trades as OpenTrade[]) {
      const binanceSymbol = toBinanceSymbol(trade.symbol);

      if (!binanceSymbol) {
        const msg =
          `[settle-tournament] No Binance symbol mapping for "${trade.symbol}" ` +
          `(trade ${trade.id}). Skipping.`;
        console.error(msg);
        summary.errors.push(msg);
        continue;
      }

      let exitPrice: number;
      if (priceCache.has(binanceSymbol)) {
        exitPrice = priceCache.get(binanceSymbol)!;
      } else {
        try {
          const priceResult = await getServerSidePrice(binanceSymbol);
          exitPrice = priceResult.price;
          priceCache.set(binanceSymbol, exitPrice);
          console.log(
            `[settle-tournament] Market price for ${binanceSymbol}: ${exitPrice}`
          );
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          const msg =
            `[settle-tournament] Could not fetch price for ${binanceSymbol} ` +
            `(trade ${trade.id}): ${message}`;
          console.error(msg);
          summary.errors.push(msg);
          continue;
        }
      }

      const realisedPnl = computePnl(
        trade.direction,
        trade.quantity,
        trade.entry_price,
        exitPrice
      );
      const settlement = computeSettlement(trade.margin, realisedPnl);

      console.log(
        `[settle-tournament] Trade ${trade.id} — direction: ${trade.direction}, ` +
        `qty: ${trade.quantity}, entry: ${trade.entry_price}, exit: ${exitPrice}, ` +
        `pnl: ${realisedPnl.toFixed(4)}, settlement: ${settlement.toFixed(4)}`
      );

      const { error: closeError } = await supabase.rpc("close_trade_txn", {
        p_trade_id: trade.id,
        p_user_id: trade.user_id,
        p_exit_price: exitPrice,
        p_realised_pnl: realisedPnl,
        p_settlement: settlement,
      });

      if (closeError) {
        const msg =
          `[settle-tournament] Failed to close trade ${trade.id}: ${closeError.message}`;
        console.error(msg);
        summary.errors.push(msg);
        // Continue — a single RPC failure must not abort the whole batch.
        // The trade remains `open` and will be retried on the next cron tick.
        continue;
      }

      summary.forceClosedTrades += 1;
      console.log(
        `[settle-tournament] Trade ${trade.id} force-closed successfully`
      );
    }

    // Advance cursor only when this batch was a full page.  If it was shorter,
    // the next SELECT would return zero rows and exit the loop cleanly.
    if (trades.length < BATCH_SIZE) {
      // Fewer rows than requested → this was the last page.
      console.log(
        `[settle-tournament] Final batch for tournament ${tournament.id} processed`
      );
      return true;
    }

    // Always re-query from offset 0. Successfully closed trades drop out of the
    // `open` result set automatically, so the window shrinks each iteration.
    // Persistently failing trades remain at the head of the result set and the
    // loop terminates naturally when the page becomes shorter than BATCH_SIZE.
    offset = 0;
  }
}

// ---------------------------------------------------------------------------
// Settle an expired tournament (idempotent across cron ticks)
// ---------------------------------------------------------------------------

/**
 * Settlement is a two-phase operation spread across potentially many cron ticks:
 *
 * Phase 1 (any tick where status = `active` and end_at <= now):
 *   • Transition status `active` → `settling` (distributed mutex).
 *   • Force-close open trades in batches; stop if budget exhausted.
 *
 * Phase 2 (any tick where status = `settling`):
 *   • Resume force-closing remaining open trades.
 *   • Once zero open trades remain, call `settle_tournament_txn`.
 *   • Status transitions `settling` → `completed` inside the RPC.
 */
async function settleTournament(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  tournament: Tournament,
  summary: SettleSummary,
  startTime: number
): Promise<void> {
  console.log(
    `[settle-tournament] Processing tournament ${tournament.id} ` +
    `(status: ${tournament.status}, ended: ${tournament.end_at})`
  );

  // --- Phase 1 mutex: transition active → settling ---
  // Only performed when the tournament is still `active`.  If we are resuming
  // a previously timed-out run the status is already `settling`; skip the UPDATE
  // to avoid a no-op round-trip.
  if (tournament.status === "active") {
    const { error: transitionError } = await supabase
      .from("tournaments")
      .update({ status: "settling" })
      .eq("id", tournament.id)
      .eq("status", "active"); // guard against concurrent cron overlaps

    if (transitionError) {
      const msg =
        `[settle-tournament] Failed to transition tournament ${tournament.id} ` +
        `to settling: ${transitionError.message}`;
      console.error(msg);
      summary.errors.push(msg);
      return;
    }

    console.log(
      `[settle-tournament] Tournament ${tournament.id} transitioned active → settling`
    );
  } else {
    console.log(
      `[settle-tournament] Tournament ${tournament.id} already settling — resuming force-close`
    );
  }

  // --- Force-close open trades (batched, budget-aware) ---
  const errorsBefore = summary.errors.length;
  const allClosed = await forceCloseTrades(supabase, tournament, summary, startTime);

  if (!allClosed) {
    // Budget exhausted or fetch error — leave status as `settling` so the next
    // cron tick picks it up and resumes.
    summary.partialTournaments.push(tournament.id);
    console.log(
      `[settle-tournament] Tournament ${tournament.id} partially settled — ` +
      `will resume on next cron tick`
    );
    return;
  }

  // --- Guard: abort final settlement if any trade close failed ---
  // Running settle_tournament_txn with un-closed trades would produce incorrect
  // ROI values because locked margin has not been returned to user balance.
  if (summary.errors.length > errorsBefore) {
    const failCount = summary.errors.length - errorsBefore;
    const msg =
      `[settle-tournament] Aborting settlement RPC for ${tournament.id} — ` +
      `${failCount} trade close failure(s). Status stays \`settling\`; ` +
      `fix the failures and retry on the next cron tick.`;
    console.error(msg);
    summary.errors.push(msg);
    return;
  }

  // --- Phase 2: finalize — compute ROI, rank participants, mark completed ---
  const { error: settleError } = await supabase.rpc("settle_tournament_txn", {
    p_tournament_id: tournament.id,
  });

  if (settleError) {
    const msg =
      `[settle-tournament] settle_tournament_txn failed for ${tournament.id}: ${settleError.message}`;
    console.error(msg);
    summary.errors.push(msg);
    return;
  }

  summary.settledTournaments.push(tournament.id);
  console.log(
    `[settle-tournament] Tournament ${tournament.id} settled successfully`
  );
}

// ---------------------------------------------------------------------------
// Activate upcoming tournaments whose start_at has passed
// ---------------------------------------------------------------------------

async function activateUpcomingTournaments(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  summary: SettleSummary
): Promise<void> {
  const now = new Date().toISOString();

  const { data: upcoming, error: fetchError } = await supabase
    .from("tournaments")
    .select("id, status, start_at, end_at")
    .eq("status", "upcoming")
    .lte("start_at", now);

  if (fetchError) {
    const msg = `[settle-tournament] Failed to fetch upcoming tournaments: ${fetchError.message}`;
    console.error(msg);
    summary.errors.push(msg);
    return;
  }

  if (!upcoming || upcoming.length === 0) {
    console.log("[settle-tournament] No upcoming tournaments to activate");
    return;
  }

  console.log(
    `[settle-tournament] Activating ${upcoming.length} upcoming tournament(s)`
  );

  for (const tournament of upcoming as Tournament[]) {
    const { error: updateError } = await supabase
      .from("tournaments")
      .update({ status: "active" })
      .eq("id", tournament.id)
      .eq("status", "upcoming"); // guard against concurrent updates

    if (updateError) {
      const msg =
        `[settle-tournament] Failed to activate tournament ${tournament.id}: ${updateError.message}`;
      console.error(msg);
      summary.errors.push(msg);
      continue;
    }

    summary.activatedTournaments.push(tournament.id);
    console.log(
      `[settle-tournament] Tournament ${tournament.id} transitioned to active`
    );
  }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // This function is cron-triggered; accept both GET and POST so it works with
  // both Supabase cron (POST) and manual curl health checks (GET).
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Record wall-clock start time used by the execution budget guard.
  const startTime = Date.now();

  console.log(`[settle-tournament] Cron job started at ${new Date(startTime).toISOString()}`);

  const supabase = getSupabaseAdmin();
  const now = new Date().toISOString();

  const summary: SettleSummary = {
    activatedTournaments: [],
    settledTournaments: [],
    partialTournaments: [],
    forceClosedTrades: 0,
    errors: [],
  };

  try {
    // --- Step 1: Process expired tournaments ---
    //
    // Query for BOTH `active` (newly expired) AND `settling` (resumed from a
    // previous timed-out run) tournaments.  This makes every cron tick
    // idempotent: an interrupted settlement is automatically continued without
    // any external intervention.
    const { data: tournamentsToSettle, error: fetchError } = await supabase
      .from("tournaments")
      .select("id, status, start_at, end_at")
      .in("status", ["active", "settling"])
      .lte("end_at", now);

    if (fetchError) {
      console.error(
        "[settle-tournament] Failed to fetch tournaments to settle:",
        fetchError.message
      );
      return new Response(
        JSON.stringify({ error: "Failed to fetch tournaments. Please try again." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (tournamentsToSettle && tournamentsToSettle.length > 0) {
      console.log(
        `[settle-tournament] Found ${tournamentsToSettle.length} tournament(s) to process ` +
        `(active + settling)`
      );

      for (const tournament of tournamentsToSettle as Tournament[]) {
        await settleTournament(supabase, tournament, summary, startTime);
      }
    } else {
      console.log(
        "[settle-tournament] No expired or in-progress tournaments to process"
      );
    }

    // --- Step 2: Activate upcoming tournaments ---
    await activateUpcomingTournaments(supabase, summary);

  } catch (err: unknown) {
    console.error("[settle-tournament] Unexpected error:", err);
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const elapsed = Date.now() - startTime;
  const hasErrors = summary.errors.length > 0;

  console.log(
    `[settle-tournament] Job complete in ${elapsed}ms — ` +
    `activated: ${summary.activatedTournaments.length}, ` +
    `settled: ${summary.settledTournaments.length}, ` +
    `partial (resumed next tick): ${summary.partialTournaments.length}, ` +
    `trades closed: ${summary.forceClosedTrades}, ` +
    `errors: ${summary.errors.length}`
  );

  return new Response(
    JSON.stringify({
      success: !hasErrors,
      data: {
        activatedTournaments: summary.activatedTournaments,
        settledTournaments: summary.settledTournaments,
        partialTournaments: summary.partialTournaments,
        forceClosedTrades: summary.forceClosedTrades,
        errors: summary.errors,
      },
    }),
    {
      // Return 207 Multi-Status when partial errors occurred so the cron
      // scheduler can distinguish full success from partial failure.
      status: hasErrors ? 207 : 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
});
