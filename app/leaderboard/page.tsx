"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { LeaderboardEntry } from "@/lib/types";

export default function LeaderboardPage() {
  const [entries, setEntries] = useState<LeaderboardEntry[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function loadLeaderboard() {
      // Read from leaderboard_view — the ONLY safe way to access user data.
      // This view exposes: display_name, username, is_human, roi, rank.
      // tg_id, balance, id are structurally absent.
      const { data, error } = await supabase
        .from("leaderboard_view")
        .select("display_name, username, is_human, roi, rank")
        .order("rank", { ascending: true })
        .limit(50);

      if (!error && data) {
        setEntries(data as LeaderboardEntry[]);
      }
      setLoading(false);
    }
    loadLeaderboard();
  }, []);

  const fmtRoi = (r: number) =>
    r >= 0 ? `+${(r * 100).toFixed(2)}%` : `${(r * 100).toFixed(2)}%`;

  return (
    <main className="flex flex-col min-h-screen px-4 pt-4 safe-bottom">
      {/* Header */}
      <header className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-lg font-bold">
            <span className="text-neon-green text-glow-green">Arena</span>
            <span className="text-white ml-1">Leaderboard</span>
          </h1>
          <p className="text-zinc-500 text-xs mt-0.5">Top 50 traders</p>
        </div>
        <a
          href="/"
          className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
        >
          Trade
        </a>
      </header>

      {/* Loading */}
      {loading && (
        <div className="flex-1 flex items-center justify-center">
          <p className="text-zinc-500 animate-pulse">Loading rankings...</p>
        </div>
      )}

      {/* Leaderboard list */}
      {!loading && (
        <div className="space-y-2">
          {entries.map((entry, idx) => {
            const isTop3 = entry.rank <= 3;
            const isProfit = entry.roi >= 0;
            const rankDisplay =
              entry.rank === 1 ? "🥇" : entry.rank === 2 ? "🥈" : entry.rank === 3 ? "🥉" : `#${entry.rank}`;

            return (
              <div
                key={`${entry.username}-${idx}`}
                className={`arena-card px-4 py-3 flex items-center justify-between transition-all ${
                  isTop3 ? (isProfit ? "glow-green border-neon-green/20" : "glow-orange border-neon-orange/20") : ""
                }`}
              >
                <div className="flex items-center gap-3">
                  {/* Rank */}
                  <span className={`text-sm font-bold w-8 ${isTop3 ? "text-lg" : "text-zinc-500"}`}>
                    {rankDisplay}
                  </span>

                  {/* Species icon */}
                  <span className="text-base" title={entry.is_human ? "Human" : "Alpha Agent"}>
                    {entry.is_human ? "👤" : "🦞"}
                  </span>

                  {/* Name */}
                  <div>
                    <p className={`text-sm font-medium ${isTop3 ? "text-white" : "text-zinc-300"}`}>
                      {entry.display_name || entry.username || "Anonymous"}
                    </p>
                    {entry.username && (
                      <p className="text-xs text-zinc-600">@{entry.username}</p>
                    )}
                  </div>
                </div>

                {/* ROI */}
                <span
                  className={`text-sm font-bold ${
                    isProfit ? "text-neon-green" : "text-neon-orange"
                  } ${isTop3 ? (isProfit ? "text-glow-green text-lg" : "text-glow-orange text-lg") : ""}`}
                >
                  {fmtRoi(entry.roi)}
                </span>
              </div>
            );
          })}

          {entries.length === 0 && (
            <div className="text-center text-zinc-500 py-12">
              <p className="text-3xl mb-2">🦞</p>
              <p>No traders yet. Be the first!</p>
            </div>
          )}
        </div>
      )}
    </main>
  );
}
