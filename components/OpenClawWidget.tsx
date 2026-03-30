"use client";

// ============================================================
// OpenClawWidget — Shows all active AI trading agents.
// Queries leaderboard_view WHERE is_human = false (up to 3).
// Falls back to single-lobster view when only one AI exists.
// ============================================================

import { useEffect, useState, useCallback } from "react";
import { supabase } from "@/lib/supabase";
import type { LeaderboardEntry } from "@/lib/types";

// ── Types ─────────────────────────────────────────────────────

type AIAgent = Pick<LeaderboardEntry, "display_name" | "roi" | "rank"> & {
  username: string;
};

// ── Emoji mapping ─────────────────────────────────────────────
// Heuristic: classify agent by username keywords.
// openclaw_lobster → 🦞 (aggressive)
// conservative/turtle → 🐢
// chaos/random → 🎲
// default → 🤖

function agentEmoji(username: string): string {
  const u = username.toLowerCase();
  if (u.includes("lobster") || u.includes("openclaw") || u.includes("aggress")) {
    return "🦞";
  }
  if (u.includes("conservative") || u.includes("turtle") || u.includes("safe")) {
    return "🐢";
  }
  if (u.includes("chaos") || u.includes("random") || u.includes("gamble")) {
    return "🎲";
  }
  return "🤖";
}

function shortName(displayName: string): string {
  // Trim to max 10 chars for compact row layout
  return displayName.length > 10 ? displayName.slice(0, 9) + "…" : displayName;
}

const fmtRoi = (r: number): string =>
  r >= 0 ? `+${(r * 100).toFixed(2)}%` : `${(r * 100).toFixed(2)}%`;

// ── Single-agent card (original behavior) ────────────────────

function SingleAgentCard({ agent }: { agent: AIAgent }) {
  const isPositive = agent.roi >= 0;
  return (
    <div
      className={`arena-card px-4 py-2.5 mb-4 flex items-center justify-between ${
        isPositive ? "border-neon-green/10" : "border-neon-orange/10"
      }`}
    >
      <div className="flex items-center gap-2 min-w-0">
        <div className="relative flex-shrink-0">
          {isPositive && (
            <span className="absolute inset-0 rounded-full animate-ping bg-neon-green/20" />
          )}
          <span className="relative text-base">{agentEmoji(agent.username)}</span>
        </div>
        <div className="flex items-center gap-1.5 min-w-0">
          <span className="text-xs font-semibold text-zinc-300 truncate">
            {shortName(agent.display_name)}
          </span>
          {agent.rank !== null && (
            <span className="text-zinc-600 text-xs flex-shrink-0">
              #{agent.rank}
            </span>
          )}
          <span className="text-zinc-700 text-xs flex-shrink-0">·</span>
          <span className="text-zinc-500 text-xs flex-shrink-0">Trading</span>
        </div>
      </div>
      <div className="flex items-center gap-2 flex-shrink-0 ml-3">
        <span className="text-zinc-600 text-xs uppercase tracking-wider">ROI</span>
        <span
          className={`text-sm font-bold tabular-nums ${
            isPositive
              ? "text-neon-green text-glow-green"
              : "text-neon-orange text-glow-orange"
          }`}
        >
          {fmtRoi(agent.roi)}
        </span>
      </div>
    </div>
  );
}

// ── Multi-agent compact row ───────────────────────────────────

function MultiAgentCard({ agents }: { agents: AIAgent[] }) {
  return (
    <div className="arena-card px-4 py-2.5 mb-4">
      {/* Label */}
      <p className="text-xs text-zinc-600 uppercase tracking-wider mb-2">
        AI Agents
      </p>
      <div className="flex gap-0 divide-x divide-arena-border">
        {agents.map((agent) => {
          const isPositive = agent.roi >= 0;
          return (
            <div
              key={agent.username}
              className="flex-1 flex flex-col items-center px-2 first:pl-0 last:pr-0"
            >
              {/* Emoji with optional pulse */}
              <div className="relative mb-1">
                {isPositive && (
                  <span className="absolute inset-0 rounded-full animate-ping bg-neon-green/20" />
                )}
                <span className="relative text-lg">{agentEmoji(agent.username)}</span>
              </div>

              {/* Name */}
              <span className="text-xs font-semibold text-zinc-300 truncate max-w-full text-center leading-tight mb-0.5">
                {shortName(agent.display_name)}
              </span>

              {/* Rank */}
              {agent.rank !== null && (
                <span className="text-zinc-600 text-xs leading-tight mb-1">
                  #{agent.rank}
                </span>
              )}

              {/* ROI */}
              <span
                className={`text-xs font-bold tabular-nums ${
                  isPositive
                    ? "text-neon-green text-glow-green"
                    : "text-neon-orange text-glow-orange"
                }`}
              >
                {fmtRoi(agent.roi)}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ── Loading skeleton ─────────────────────────────────────────

function LoadingSkeleton() {
  return (
    <div className="arena-card px-4 py-2.5 mb-4 flex items-center justify-between">
      <div className="flex items-center gap-2">
        <span className="text-base">🤖</span>
        <span className="text-zinc-600 text-xs animate-pulse">
          Alpha Agents loading...
        </span>
      </div>
    </div>
  );
}

// ── Main widget ───────────────────────────────────────────────

export default function OpenClawWidget() {
  const [agents, setAgents] = useState<AIAgent[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchAgents = useCallback(async () => {
    const { data: rows, error } = await supabase
      .from("leaderboard_view")
      .select("display_name, username, roi, rank")
      .eq("is_human", false)
      .order("rank", { ascending: true })
      .limit(3);

    if (!error && rows) {
      setAgents(rows as AIAgent[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchAgents();
  }, [fetchAgents]);

  // Refresh every 30 seconds
  useEffect(() => {
    const interval = setInterval(fetchAgents, 30_000);
    return () => clearInterval(interval);
  }, [fetchAgents]);

  if (loading) return <LoadingSkeleton />;
  if (agents.length === 0) return null;

  // Single agent: use original compact single-line layout
  if (agents.length === 1) {
    return <SingleAgentCard agent={agents[0]} />;
  }

  // Multiple agents: compact 2–3 column row
  return <MultiAgentCard agents={agents} />;
}
