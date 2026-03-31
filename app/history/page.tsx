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

  // Safe number conversion — PostgreSQL NUMERIC comes as string sometimes
  const tc = Number(stats.total_closed) || 0;
  const wr = stats.win_rate != null ? Number(stats.win_rate) : null;
  const cp = stats.cumulative_pnl != null ? Number(stats.cumulative_pnl) : null;
  const bp = stats.best_trade_pnl != null ? Number(stats.best_trade_pnl) : null;
  const wp = stats.worst_trade_pnl != null ? Number(stats.worst_trade_pnl) : null;

  const statItems: Array<{ label: string; value: string; positive?: boolean | null }> = [
    {
      label: "Trades",
      value: String(tc),
      positive: null,
    },
    {
      label: "Win Rate",
      value: wr !== null && !isNaN(wr) ? `${(wr * 100).toFixed(1)}%` : "—",
      positive: wr !== null ? wr >= 0.5 : null,
    },
    {
      label: "Total PnL",
      value: cp !== null && !isNaN(cp) ? (cp >= 0 ? `+${cp.toFixed(2)}` : cp.toFixed(2)) : "—",
      positive: cp !== null ? cp >= 0 : null,
    },
    {
      label: "Best",
      value: bp !== null && !isNaN(bp) ? (bp >= 0 ? `+${bp.toFixed(2)}` : bp.toFixed(2)) : "—",
      positive: bp !== null ? bp >= 0 : null,
    },
    {
      label: "Worst",
      value: wp !== null && !isNaN(wp) ? (wp >= 0 ? `+${wp.toFixed(2)}` : wp.toFixed(2)) : "—",
      positive: wp !== null ? wp >= 0 : null,
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
  const [rawDebug, setRawDebug] = useState<string>("loading...");

  useEffect(() => {
    async function test() {
      try {
        const res = await supabase.functions.invoke("get-trade-history", {
          body: { limit: 3 },
        });
        setRawDebug(JSON.stringify({ error: res.error?.message, dataKeys: res.data ? Object.keys(res.data) : null, sample: JSON.stringify(res.data).slice(0, 500) }, null, 2));
      } catch (e) {
        setRawDebug("fetch error: " + String(e));
      }
    }
    test();
  }, []);

  return (
    <main className="p-4">
      <a href="/" className="text-neon-green text-xs">← Back</a>
      <h1 className="text-white text-lg font-bold mt-2 mb-4">Trade History Debug</h1>
      <pre className="text-zinc-400 text-xs font-mono whitespace-pre-wrap break-all bg-zinc-900 p-3 rounded-xl">{rawDebug}</pre>
    </main>
  );

}
