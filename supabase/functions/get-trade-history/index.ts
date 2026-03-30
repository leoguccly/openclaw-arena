import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 100;

const ALLOWED_SYMBOLS = new Set(["BTC/USDT", "ETH/USDT"]);
const ALLOWED_STATUSES = new Set(["open", "closed", "liquidated"]);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface TradeRow {
  id: string;
  user_id: string;
  symbol: string;
  direction: "long" | "short";
  leverage: number;
  margin: number;
  entry_price: number;
  exit_price: number | null;
  liquidation_price: number;
  quantity: number;
  realised_pnl: number | null;
  status: "open" | "closed" | "liquidated";
  created_at: string;
  updated_at: string;
  [key: string]: unknown;
}

interface AggregateStatsRow {
  total_closed: string | null;
  wins: string | null;
  cumulative_pnl: string | null;
  best_trade: string | null;
  worst_trade: string | null;
}

interface TradeStats {
  total_closed: number;
  wins: number;
  losses: number;
  win_rate: number | null;
  cumulative_pnl: number;
  best_trade: number | null;
  worst_trade: number | null;
}

// ---------------------------------------------------------------------------
// Query param parsing
// ---------------------------------------------------------------------------

interface ParsedParams {
  symbol: string | null;
  status: string | null;
  limit: number;
  cursor: string | null;
}

function parseParams(url: URL): { params: ParsedParams | null; error: string | null } {
  const symbolRaw = url.searchParams.get("symbol");
  const statusRaw = url.searchParams.get("status");
  const limitRaw = url.searchParams.get("limit");
  const cursorRaw = url.searchParams.get("cursor");

  // symbol — optional, must be in allowlist if present
  if (symbolRaw !== null && !ALLOWED_SYMBOLS.has(symbolRaw)) {
    return {
      params: null,
      error: `symbol must be one of: ${[...ALLOWED_SYMBOLS].join(", ")}`,
    };
  }

  // status — optional, must be in allowlist if present
  if (statusRaw !== null && !ALLOWED_STATUSES.has(statusRaw)) {
    return {
      params: null,
      error: `status must be one of: ${[...ALLOWED_STATUSES].join(", ")}`,
    };
  }

  // limit — optional, integer in [1, MAX_LIMIT]
  let limit = DEFAULT_LIMIT;
  if (limitRaw !== null) {
    const parsed = parseInt(limitRaw, 10);
    if (isNaN(parsed) || parsed < 1 || parsed > MAX_LIMIT) {
      return {
        params: null,
        error: `limit must be an integer between 1 and ${MAX_LIMIT}`,
      };
    }
    limit = parsed;
  }

  // cursor — optional, must be a parseable ISO date string if present
  if (cursorRaw !== null) {
    const ts = Date.parse(cursorRaw);
    if (isNaN(ts)) {
      return {
        params: null,
        error: "cursor must be a valid ISO 8601 date string",
      };
    }
  }

  return {
    params: {
      symbol: symbolRaw,
      status: statusRaw,
      limit,
      cursor: cursorRaw,
    },
    error: null,
  };
}

// ---------------------------------------------------------------------------
// Aggregate stats
// ---------------------------------------------------------------------------

/**
 * Fetches closed/liquidated trade aggregate stats for the user in a single
 * parameterised SQL query executed via an RPC wrapper.
 *
 * Falls back to zero-value stats on error so the trade list is still returned.
 */
async function fetchAggregateStats(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string
): Promise<TradeStats> {
  const zeroStats: TradeStats = {
    total_closed: 0,
    wins: 0,
    losses: 0,
    win_rate: null,
    cumulative_pnl: 0,
    best_trade: null,
    worst_trade: null,
  };

  // We call a raw SQL query through Supabase's rpc mechanism. If the
  // get_trade_stats RPC is not available, we fall back to a client-side
  // aggregate using the trades table directly.
  const { data, error } = await supabase.rpc("get_trade_stats", {
    p_user_id: userId,
  });

  if (error) {
    // RPC not found (42883) — attempt a direct table query as fallback.
    const pgCode = (error as { code?: string }).code ?? "";
    if (pgCode === "42883" || error.message.includes("does not exist")) {
      console.warn(
        "[get-trade-history] get_trade_stats RPC not found, falling back to direct query"
      );
      return await fetchAggregateStatsDirect(supabase, userId);
    }

    console.error(
      `[get-trade-history] get_trade_stats RPC error for user ${userId}:`,
      error.message
    );
    return zeroStats;
  }

  const row = (Array.isArray(data) ? data[0] : data) as AggregateStatsRow | null;
  if (!row) {
    return zeroStats;
  }

  return parseStatsRow(row);
}

/**
 * Direct Supabase client fallback for aggregate stats when the RPC is absent.
 * Fetches all closed/liquidated trades and computes aggregates in TypeScript.
 *
 * NOTE: This path loads every closed trade into memory and is not suitable for
 * users with thousands of trades. Apply the get_trade_stats migration before
 * production launch.
 */
async function fetchAggregateStatsDirect(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  userId: string
): Promise<TradeStats> {
  const zeroStats: TradeStats = {
    total_closed: 0,
    wins: 0,
    losses: 0,
    win_rate: null,
    cumulative_pnl: 0,
    best_trade: null,
    worst_trade: null,
  };

  const { data: rows, error } = await supabase
    .from("trades")
    .select("realised_pnl")
    .eq("user_id", userId)
    .in("status", ["closed", "liquidated"]);

  if (error || !rows) {
    console.error(
      `[get-trade-history] Direct stats query failed for user ${userId}:`,
      error?.message ?? "no data"
    );
    return zeroStats;
  }

  const pnls = (rows as { realised_pnl: number | null }[])
    .map((r) => r.realised_pnl ?? 0);

  const total_closed = pnls.length;
  const wins = pnls.filter((p) => p > 0).length;
  const losses = total_closed - wins;
  const cumulative_pnl = pnls.reduce((acc, p) => acc + p, 0);
  const best_trade = total_closed > 0 ? Math.max(...pnls) : null;
  const worst_trade = total_closed > 0 ? Math.min(...pnls) : null;
  const win_rate = total_closed > 0 ? wins / total_closed : null;

  return { total_closed, wins, losses, win_rate, cumulative_pnl, best_trade, worst_trade };
}

function parseStatsRow(row: AggregateStatsRow): TradeStats {
  const total_closed = parseInt(row.total_closed ?? "0", 10);
  const wins = parseInt(row.wins ?? "0", 10);
  const losses = total_closed - wins;
  const cumulative_pnl = parseFloat(row.cumulative_pnl ?? "0");
  const best_trade = row.best_trade !== null ? parseFloat(row.best_trade) : null;
  const worst_trade = row.worst_trade !== null ? parseFloat(row.worst_trade) : null;
  const win_rate = total_closed > 0 ? wins / total_closed : null;

  return { total_closed, wins, losses, win_rate, cumulative_pnl, best_trade, worst_trade };
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

  // --- 1. Authentication ---
  const user = await getUserFromAuth(req.headers.get("Authorization"), req);
  if (!user) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[get-trade-history] Request from user ${user.id}`);

  // --- 2. Rate limiting ---
  const rateLimitResult = checkRateLimit(user.id, "get-trade-history");
  if (!rateLimitResult.allowed) {
    return new Response(
      JSON.stringify({
        error: "Too many requests. Please wait before trying again.",
        retryAfter: rateLimitResult.retryAfter,
      }),
      {
        status: 429,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Retry-After": String(rateLimitResult.retryAfter ?? 10),
        },
      }
    );
  }

  // --- 3. Parse and validate query params ---
  const url = new URL(req.url);
  const { params, error: paramError } = parseParams(url);

  if (paramError || !params) {
    return new Response(
      JSON.stringify({ error: paramError ?? "Invalid query parameters" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(
    `[get-trade-history] User ${user.id} — symbol=${params.symbol ?? "all"}, ` +
    `status=${params.status ?? "all"}, limit=${params.limit}, cursor=${params.cursor ?? "none"}`
  );

  const supabase = getSupabaseAdmin();

  // --- 4. Fetch trade page from trade_history_view ---
  // Cursor-based pagination: created_at < cursor allows stable forward paging
  // without the offset skew problem that occurs when new rows are inserted.
  let query = supabase
    .from("trade_history_view")
    .select("*")
    .eq("user_id", user.id)
    .order("created_at", { ascending: false })
    .limit(params.limit);

  if (params.symbol !== null) {
    query = query.eq("symbol", params.symbol);
  }

  if (params.status !== null) {
    query = query.eq("status", params.status);
  }

  if (params.cursor !== null) {
    // Exclusive: fetch rows strictly older than the cursor timestamp.
    query = query.lt("created_at", params.cursor);
  }

  const { data: trades, error: tradesError } = await query;

  if (tradesError) {
    console.error(
      `[get-trade-history] Trade query failed for user ${user.id}:`,
      tradesError.message
    );
    return new Response(
      JSON.stringify({ error: "An error occurred. Please try again." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const tradeList = (trades ?? []) as TradeRow[];

  // Derive the cursor for the next page: the created_at of the last row.
  const next_cursor =
    tradeList.length === params.limit
      ? tradeList[tradeList.length - 1].created_at
      : null;

  // --- 5. Fetch aggregate stats (parallel, non-blocking on failure) ---
  const stats = await fetchAggregateStats(supabase, user.id);

  console.log(
    `[get-trade-history] Returning ${tradeList.length} trades for user ${user.id}. ` +
    `next_cursor=${next_cursor ?? "none"}`
  );

  return new Response(
    JSON.stringify({
      success: true,
      data: {
        trades: tradeList,
        next_cursor,
        stats,
      },
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
