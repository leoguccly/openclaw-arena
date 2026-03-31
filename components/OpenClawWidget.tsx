"use client";

// ============================================================
// TopTradersWidget — Shows top 3 traders from the leaderboard.
// Queries leaderboard_view WHERE is_human = true, ordered by rank.
// ============================================================

import { useEffect, useState, useCallback } from "react";
import { supabase } from "@/lib/supabase";
import type { LeaderboardEntry } from "@/lib/types";

type TopTrader = Pick<LeaderboardEntry, "display_name" | "roi" | "rank">;

const RANK_EMOJI = ["🥇", "🥈", "🥉"];

const fmtRoi = (r: number): string =>
  r >= 0 ? `+${(r * 100).toFixed(2)}%` : `${(r * 100).toFixed(2)}%`;

function shortName(name: string): string {
  return name.length > 10 ? name.slice(0, 9) + "…" : name;
}

export default function OpenClawWidget() {
  const [traders, setTraders] = useState<TopTrader[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchTopTraders = useCallback(async () => {
    const { data, error } = await supabase
      .from("leaderboard_view")
      .select("display_name, roi, rank")
      .eq("is_human", true)
      .order("rank", { ascending: true })
      .limit(3);

    if (!error && data) {
      setTraders(data as TopTrader[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchTopTraders();
  }, [fetchTopTraders]);

  useEffect(() => {
    const interval = setInterval(fetchTopTraders, 30_000);
    return () => clearInterval(interval);
  }, [fetchTopTraders]);

  if (loading) {
    return (
      <div className="arena-card px-4 py-2.5 mb-4 flex items-center gap-2">
        <span className="text-base">🏆</span>
        <span className="text-zinc-600 text-xs animate-pulse">Loading leaderboard...</span>
      </div>
    );
  }

  if (traders.length === 0) return null;

  return (
    <div className="arena-card px-4 py-2.5 mb-4">
      <p className="text-xs text-zinc-600 uppercase tracking-wider mb-2">
        Top Traders
      </p>
      <div className="flex gap-0 divide-x divide-arena-border">
        {traders.map((trader, i) => {
          const isPositive = trader.roi >= 0;
          return (
            <div
              key={`${trader.display_name}-${i}`}
              className="flex-1 flex flex-col items-center px-2 first:pl-0 last:pr-0"
            >
              <span className="text-lg mb-1">{RANK_EMOJI[i] ?? `#${trader.rank}`}</span>
              <span className="text-xs font-semibold text-zinc-300 truncate max-w-full text-center leading-tight mb-0.5">
                {shortName(trader.display_name)}
              </span>
              <span
                className={`text-xs font-bold tabular-nums ${
                  isPositive
                    ? "text-neon-green text-glow-green"
                    : "text-neon-orange text-glow-orange"
                }`}
              >
                {fmtRoi(trader.roi)}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
