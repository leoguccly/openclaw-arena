"use client";

// ============================================================
// Trade History / Journal Page
// Cursor-based pagination, filter by status and symbol.
// Calls the `get-trade-history` Edge Function.
// ============================================================

import { useEffect, useState, useCallback, useRef } from "react";
import { supabase } from "@/lib/supabase";
import type { TradeHistoryItem, AggregateStats } from "@/lib/types";

// ── Helpers ───────────────────────────────────────────────────

function fmtPrice(p: number | string | null | undefined): string {
  const n = Number(p);
  if (isNaN(n)) return "—";
  return n >= 1000
    ? n.toLocaleString("en-US", { maximumFractionDigits: 2 })
    : n.toFixed(4);
}

function fmtPnl(p: number | string | null | undefined): string {
  const n = Number(p);
  if (isNaN(n)) return "—";
  return n >= 0 ? `+${n.toFixed(2)}` : n.toFixed(2);
}

function fmtDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "—";
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function fmtWinRate(wr: number | null): string {
  if (wr === null) return "—";
  return `${(wr * 100).toFixed(1)}%`;
}

function fmtPnlStat(p: number | null): string {
  if (p === null) return "—";
  return p >= 0 ? `+${p.toFixed(2)}` : p.toFixed(2);
}

// ── Types for local filters ────────────────────────────────────

type StatusFilter = "all" | "closed" | "liquidated";
type SymbolFilter = "all" | "BTC" | "ETH";

const PAGE_SIZE = 20;

// ── Stats Bar ─────────────────────────────────────────────────

function StatsBar({ stats, loading }: { stats: AggregateStats | null; loading: boolean }) {
  if (loading) {
    return (
      <div className="arena-card p-4 mb-4 animate-pulse">
        <div className="grid grid-cols-3 gap-3">
          {[...Array(5)].map((_, i) => (
            <div key={i} className="h-10 bg-zinc-800 rounded-lg" />
          ))}
        </div>
      </div>
    );
  }

  if (!stats) return null;

  const statItems: Array<{ label: string; value: string; positive?: boolean | null }> = [
    {
      label: "Trades",
      value: String(stats.total_closed),
      positive: null,
    },
    {
      label: "Win Rate",
      value: fmtWinRate(stats.win_rate),
      positive: stats.win_rate !== null ? stats.win_rate >= 0.5 : null,
    },
    {
      label: "Total PnL",
      value: fmtPnlStat(stats.cumulative_pnl),
      positive: stats.cumulative_pnl !== null ? stats.cumulative_pnl >= 0 : null,
    },
    {
      label: "Best",
      value: fmtPnlStat(stats.best_trade_pnl),
      positive: stats.best_trade_pnl !== null ? stats.best_trade_pnl >= 0 : null,
    },
    {
      label: "Worst",
      value: fmtPnlStat(stats.worst_trade_pnl),
      positive: stats.worst_trade_pnl !== null ? stats.worst_trade_pnl >= 0 : null,
    },
  ];

  return (
    <div className="arena-card p-4 mb-4">
      <div className="grid grid-cols-3 gap-3">
        {statItems.map((item) => (
          <div key={item.label} className="text-center">
            <p className="text-zinc-500 text-[10px] uppercase tracking-wider mb-1">
              {item.label}
            </p>
            <p
              className={`text-sm font-bold tabular-nums ${
                item.positive === null
                  ? "text-white"
                  : item.positive
                  ? "text-neon-green text-glow-green"
                  : "text-neon-orange text-glow-orange"
              }`}
            >
              {item.value}
            </p>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Trade Row ─────────────────────────────────────────────────

function TradeRow({ trade }: { trade: TradeHistoryItem }) {
  if (!trade || !trade.symbol || !trade.direction) return null;
  const isLong      = trade.direction === "long";
  const isLiq       = trade.status === "liquidated";
  const hasPnl      = trade.realised_pnl !== null;
  const pnlPositive = (trade.realised_pnl ?? 0) >= 0;

  return (
    <div
      className={`arena-card p-3 border-l-4 ${
        isLiq
          ? "border-l-neon-orange"
          : hasPnl && pnlPositive
          ? "border-l-neon-green"
          : hasPnl
          ? "border-l-neon-orange"
          : "border-l-zinc-700"
      }`}
    >
      {/* Row 1: Direction badge, symbol, leverage, status */}
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center gap-2 min-w-0">
          {/* Direction badge */}
          <span
            className={`text-[10px] font-bold px-2 py-0.5 rounded flex-shrink-0 ${
              isLong
                ? "bg-neon-green/20 text-neon-green"
                : "bg-neon-orange/20 text-neon-orange"
            }`}
          >
            {isLong ? "LONG" : "SHORT"}
          </span>

          {/* Symbol + leverage */}
          <span className="text-xs text-zinc-300 font-medium truncate">
            {trade.symbol.split("/")[0]}
          </span>
          <span className="text-xs text-zinc-600 flex-shrink-0">
            {trade.leverage}x
          </span>

          {/* Tournament badge */}
          {trade.tournament_name && (
            <span className="text-[10px] px-1.5 py-0.5 rounded bg-zinc-800 text-zinc-400 border border-zinc-700 truncate max-w-[80px]">
              {trade.tournament_name}
            </span>
          )}
        </div>

        {/* Status badge */}
        <span
          className={`text-[10px] font-bold px-2 py-0.5 rounded border flex-shrink-0 ml-2 ${
            isLiq
              ? "bg-neon-orange/15 text-neon-orange border-neon-orange/30"
              : trade.status === "closed"
              ? "bg-zinc-800 text-zinc-400 border-zinc-700"
              : "bg-neon-green/10 text-neon-green border-neon-green/20"
          }`}
        >
          {isLiq ? "LIQ" : trade.status.toUpperCase()}
        </span>
      </div>

      {/* Row 2: Entry → Exit prices + PnL */}
      <div className="flex items-end justify-between">
        <div>
          <p className="text-xs text-zinc-500 mb-0.5">
            ${fmtPrice(trade.entry_price)}
            {trade.exit_price !== null && (
              <>
                <span className="mx-1 text-zinc-700">→</span>
                ${fmtPrice(trade.exit_price)}
              </>
            )}
          </p>
          <p className="text-[10px] text-zinc-600">
            {fmtDate(trade.created_at)}
            {trade.closed_at && (
              <span className="ml-1">
                · {fmtDate(trade.closed_at)}
              </span>
            )}
          </p>
        </div>

        {/* PnL */}
        {hasPnl ? (
          <p
            className={`text-sm font-bold tabular-nums ${
              pnlPositive
                ? "text-neon-green text-glow-green"
                : "text-neon-orange text-glow-orange"
            }`}
          >
            {fmtPnl(trade.realised_pnl!)}
          </p>
        ) : (
          <p className="text-xs text-zinc-600">—</p>
        )}
      </div>
    </div>
  );
}

// ── Main Page ─────────────────────────────────────────────────

export default function HistoryPage() {
  const [trades, setTrades]               = useState<TradeHistoryItem[]>([]);
  const [stats, setStats]                 = useState<AggregateStats | null>(null);
  const [statsLoading, setStatsLoading]   = useState<boolean>(true);
  const [loading, setLoading]             = useState<boolean>(true);
  const [loadingMore, setLoadingMore]     = useState<boolean>(false);
  const [hasMore, setHasMore]             = useState<boolean>(true);
  const [cursor, setCursor]               = useState<string | null>(null);
  const [statusFilter, setStatusFilter]   = useState<StatusFilter>("all");
  const [symbolFilter, setSymbolFilter]   = useState<SymbolFilter>("all");
  const [error, setError]                 = useState<string>("");

  const loaderRef = useRef<HTMLDivElement | null>(null);

  // ── Load stats ────────────────────────────────────────────────
  useEffect(() => {
    async function loadStats() {
      setStatsLoading(true);
      try {
        const res = await supabase.functions.invoke("get-trade-history", {
          body: { stats_only: true },
        });
        const statsPayload = res.data?.data ?? res.data;
        if (!res.error && statsPayload?.stats) {
          setStats(statsPayload.stats as AggregateStats);
        }
      } catch {
        // Non-critical — skip
      } finally {
        setStatsLoading(false);
      }
    }
    loadStats();
  }, []);

  // ── Load trades (resets on filter change) ─────────────────────
  const loadTrades = useCallback(
    async (nextCursor: string | null, append: boolean) => {
      if (!append) {
        setLoading(true);
        setError("");
      } else {
        setLoadingMore(true);
      }

      try {
        const body: Record<string, unknown> = {
          limit: PAGE_SIZE,
        };
        if (nextCursor)                 body.cursor        = nextCursor;
        if (statusFilter !== "all")     body.status        = statusFilter;
        if (symbolFilter !== "all")     body.symbol        = `${symbolFilter}/USDT`;

        const res = await supabase.functions.invoke("get-trade-history", { body });

        if (res.error) {
          setError("Failed to load trade history.");
          return;
        }

        const payload = res.data?.data ?? res.data;
        const items   = (payload?.trades ?? []) as TradeHistoryItem[];
        const nextCur = (payload?.next_cursor ?? null) as string | null;

        setTrades((prev) => (append ? [...prev, ...items] : items));
        setCursor(nextCur);
        setHasMore(nextCur !== null);
      } catch {
        setError("Network error. Pull to refresh.");
      } finally {
        setLoading(false);
        setLoadingMore(false);
      }
    },
    [statusFilter, symbolFilter]
  );

  // Reset + reload when filters change
  useEffect(() => {
    setCursor(null);
    setHasMore(true);
    loadTrades(null, false);
  }, [loadTrades]);

  // ── Infinite scroll via IntersectionObserver ──────────────────
  useEffect(() => {
    const el = loaderRef.current;
    if (!el) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && hasMore && !loadingMore && !loading) {
          loadTrades(cursor, true);
        }
      },
      { threshold: 0.1 }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [cursor, hasMore, loadingMore, loading, loadTrades]);

  // ── Filter pills ──────────────────────────────────────────────

  const statusFilters: Array<{ key: StatusFilter; label: string }> = [
    { key: "all",         label: "All"       },
    { key: "closed",      label: "Closed"    },
    { key: "liquidated",  label: "Liquidated"},
  ];

  const symbolFilters: Array<{ key: SymbolFilter; label: string }> = [
    { key: "all",  label: "All" },
    { key: "BTC",  label: "BTC" },
    { key: "ETH",  label: "ETH" },
  ];

  return (
    <main className="flex flex-col min-h-screen px-4 pt-4 safe-bottom">
      {/* ── Header ── */}
      <header className="flex items-center justify-between mb-4">
        <div>
          <h1 className="text-lg font-bold">
            <span className="text-neon-green text-glow-green">Trade</span>
            <span className="text-white ml-1">History</span>
          </h1>
          <p className="text-zinc-500 text-xs mt-0.5">Your trading journal</p>
        </div>
        <a
          href="/"
          className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
        >
          ← Back
        </a>
      </header>

      {/* ── Aggregate Stats ── */}
      <StatsBar stats={stats} loading={statsLoading} />

      {/* ── Filters ── */}
      <div className="flex gap-2 mb-3 overflow-x-auto pb-1 no-scrollbar">
        {statusFilters.map((f) => (
          <button
            key={f.key}
            onClick={() => setStatusFilter(f.key)}
            className={`flex-shrink-0 px-3 py-1.5 rounded-lg text-xs font-bold transition-all ${
              statusFilter === f.key
                ? "bg-neon-green/10 text-neon-green border border-neon-green/30"
                : "text-zinc-500 border border-arena-border hover:border-zinc-600"
            }`}
          >
            {f.label}
          </button>
        ))}
        <span className="text-zinc-700 self-center mx-1">|</span>
        {symbolFilters.map((f) => (
          <button
            key={f.key}
            onClick={() => setSymbolFilter(f.key)}
            className={`flex-shrink-0 px-3 py-1.5 rounded-lg text-xs font-bold transition-all ${
              symbolFilter === f.key
                ? "bg-neon-green/10 text-neon-green border border-neon-green/30"
                : "text-zinc-500 border border-arena-border hover:border-zinc-600"
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      {/* ── Error ── */}
      {error && (
        <div className="arena-card border-neon-orange/30 p-3 mb-4 text-neon-orange text-sm text-center">
          {error}
        </div>
      )}

      {/* ── Trade List ── */}
      {loading ? (
        <div className="space-y-3">
          {[...Array(5)].map((_, i) => (
            <div
              key={i}
              className="arena-card p-4 h-20 animate-pulse bg-zinc-900/50"
            />
          ))}
        </div>
      ) : trades.length === 0 ? (
        <div className="flex-1 flex flex-col items-center justify-center py-20 text-center">
          <p className="text-4xl mb-4">📜</p>
          <p className="text-zinc-400 text-sm font-medium">No trades yet</p>
          <p className="text-zinc-600 text-xs mt-1">
            Your closed and liquidated positions will appear here.
          </p>
          <a
            href="/"
            className="mt-6 px-6 py-2.5 rounded-xl text-sm font-bold bg-neon-green text-arena-bg glow-green-intense transition-all active:scale-95"
          >
            Start Trading
          </a>
        </div>
      ) : (
        <div className="space-y-3 pb-4">
          {/* DEBUG: show raw first trade data */}
          <div className="arena-card p-2 text-xs text-zinc-500 font-mono break-all mb-2">
            DEBUG: {JSON.stringify(trades[0]).slice(0, 300)}
          </div>
          {trades.map((trade) => {
            try {
              return <TradeRow key={trade.id ?? Math.random()} trade={trade} />;
            } catch (e) {
              return (
                <div key={Math.random()} className="arena-card p-2 text-xs text-red-500">
                  Render error: {String(e)} | Data: {JSON.stringify(trade).slice(0, 200)}
                </div>
              );
            }
          })}

          {/* Infinite scroll sentinel */}
          <div ref={loaderRef} className="h-4" />

          {loadingMore && (
            <div className="text-center py-4">
              <p className="text-zinc-600 text-xs animate-pulse">Loading more...</p>
            </div>
          )}

          {!hasMore && trades.length > 0 && (
            <p className="text-center text-zinc-700 text-xs py-4">
              All {trades.length} trades loaded
            </p>
          )}
        </div>
      )}
    </main>
  );
}
