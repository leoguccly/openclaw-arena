"use client";

// ============================================================
// Achievements Page
// Three sections: Earned (full color), In Progress (progress bar),
// Locked (grayed out). Calls the `get-achievements` Edge Function.
// ============================================================

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { Achievement } from "@/lib/types";

// ── Icon mapping ──────────────────────────────────────────────

const ICON_MAP: Record<string, string> = {
  trophy:    "🏆",
  lightning: "⚡",
  medal:     "🥇",
  star:      "⭐",
  fire:      "🔥",
  shield:    "🛡️",
};

function getIcon(key: string): string {
  return ICON_MAP[key] ?? "🎯";
}

// ── Helpers ───────────────────────────────────────────────────

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function progressPercent(current: number, required: number): number {
  return Math.min(100, Math.round((current / required) * 100));
}

// ── Achievement sections ──────────────────────────────────────

type Section = "earned" | "inProgress" | "locked";

function categorise(achievements: Achievement[]): Record<Section, Achievement[]> {
  const earned:     Achievement[] = [];
  const inProgress: Achievement[] = [];
  const locked:     Achievement[] = [];

  for (const a of achievements) {
    if (a.earned_at) {
      earned.push(a);
    } else if (a.is_progress_tracked && (a.current_count ?? 0) > 0) {
      inProgress.push(a);
    } else {
      locked.push(a);
    }
  }

  return { earned, inProgress, locked };
}

// ── EarnedCard ────────────────────────────────────────────────

function EarnedCard({ achievement }: { achievement: Achievement }) {
  return (
    <div className="arena-card p-4 border-neon-green/15 flex items-start gap-3">
      <div className="flex-shrink-0 w-11 h-11 rounded-xl bg-neon-green/10 border border-neon-green/25 flex items-center justify-center text-2xl">
        {getIcon(achievement.icon_key)}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 mb-0.5">
          <p className="text-sm font-bold text-white truncate">{achievement.name}</p>
          <span className="text-neon-green text-xs flex-shrink-0">✓</span>
        </div>
        <p className="text-xs text-zinc-500 leading-snug mb-1.5">
          {achievement.description}
        </p>
        {achievement.earned_at && (
          <p className="text-[10px] text-zinc-600">
            Earned {fmtDate(achievement.earned_at)}
          </p>
        )}
      </div>
    </div>
  );
}

// ── InProgressCard ────────────────────────────────────────────

function InProgressCard({ achievement }: { achievement: Achievement }) {
  const current  = achievement.current_count ?? 0;
  const required = achievement.required_count;
  const pct      = progressPercent(current, required);

  return (
    <div className="arena-card p-4 flex items-start gap-3">
      <div className="flex-shrink-0 w-11 h-11 rounded-xl bg-zinc-800 border border-zinc-700 flex items-center justify-center text-2xl">
        {getIcon(achievement.icon_key)}
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-bold text-white mb-0.5 truncate">
          {achievement.name}
        </p>
        <p className="text-xs text-zinc-500 leading-snug mb-2">
          {achievement.description}
        </p>
        {/* Progress bar */}
        <div className="flex items-center gap-2">
          <div className="flex-1 h-1.5 bg-zinc-800 rounded-full overflow-hidden">
            <div
              className="h-full rounded-full bg-neon-green transition-all duration-700"
              style={{ width: `${pct}%` }}
            />
          </div>
          <span className="text-[10px] text-zinc-500 flex-shrink-0 tabular-nums">
            {current}/{required}
          </span>
        </div>
      </div>
    </div>
  );
}

// ── LockedCard ────────────────────────────────────────────────

function LockedCard({ achievement }: { achievement: Achievement }) {
  return (
    <div className="arena-card p-4 flex items-start gap-3 opacity-45">
      <div className="flex-shrink-0 w-11 h-11 rounded-xl bg-zinc-900 border border-zinc-800 flex items-center justify-center text-2xl grayscale">
        {getIcon(achievement.icon_key)}
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-bold text-zinc-400 mb-0.5 truncate">
          {achievement.name}
        </p>
        <p className="text-xs text-zinc-600 leading-snug">
          {achievement.description}
        </p>
      </div>
      <span className="text-zinc-700 text-base flex-shrink-0 mt-0.5">🔒</span>
    </div>
  );
}

// ── Section Header ─────────────────────────────────────────────

function SectionHeader({ title, count }: { title: string; count: number }) {
  return (
    <div className="flex items-center gap-2 mb-3">
      <h2 className="text-xs font-bold text-zinc-400 uppercase tracking-widest">
        {title}
      </h2>
      <span className="text-xs text-zinc-600 font-bold">{count}</span>
      <div className="flex-1 h-px bg-arena-border" />
    </div>
  );
}

// ── Main Page ─────────────────────────────────────────────────

export default function AchievementsPage() {
  const [achievements, setAchievements] = useState<Achievement[]>([]);
  const [loading, setLoading]           = useState<boolean>(true);
  const [error, setError]               = useState<string>("");

  useEffect(() => {
    async function load() {
      setLoading(true);
      setError("");
      try {
        const res = await supabase.functions.invoke("get-achievements", {
          body: {},
        });

        if (res.error) {
          setError("Failed to load achievements.");
          return;
        }

        // Edge Function returns { data: { earned, in_progress, locked } }
        const payload = res.data?.data ?? res.data ?? {};
        const earned = (payload.earned ?? []) as Achievement[];
        const inProgress = (payload.in_progress ?? []) as Achievement[];
        const locked = (payload.locked ?? []) as Achievement[];
        // Merge into a single flat array for the categorise() function
        setAchievements([...earned, ...inProgress, ...locked]);
      } catch {
        setError("Network error. Try again.");
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  const sections = categorise(achievements);
  const earnedCount = sections.earned.length;
  const total       = achievements.length;

  return (
    <main className="flex flex-col min-h-screen px-4 pt-4 safe-bottom">
      {/* ── Header ── */}
      <header className="flex items-center justify-between mb-4">
        <div>
          <h1 className="text-lg font-bold">
            <span className="text-neon-green text-glow-green">Achieve</span>
            <span className="text-white">ments</span>
          </h1>
          {!loading && total > 0 && (
            <p className="text-zinc-500 text-xs mt-0.5">
              {earnedCount}/{total} unlocked
            </p>
          )}
        </div>
        <a
          href="/"
          className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
        >
          ← Back
        </a>
      </header>

      {/* ── Overall progress bar ── */}
      {!loading && total > 0 && (
        <div className="arena-card p-4 mb-5">
          <div className="flex items-center justify-between mb-2">
            <span className="text-xs text-zinc-500 uppercase tracking-wider">
              Progress
            </span>
            <span className="text-xs font-bold text-neon-green tabular-nums">
              {Math.round((earnedCount / total) * 100)}%
            </span>
          </div>
          <div className="h-2 bg-zinc-800 rounded-full overflow-hidden">
            <div
              className="h-full rounded-full bg-neon-green transition-all duration-1000"
              style={{ width: `${(earnedCount / total) * 100}%` }}
            />
          </div>
        </div>
      )}

      {/* ── Loading skeletons ── */}
      {loading && (
        <div className="space-y-3">
          {[...Array(6)].map((_, i) => (
            <div
              key={i}
              className="arena-card p-4 h-20 animate-pulse bg-zinc-900/50"
            />
          ))}
        </div>
      )}

      {/* ── Error ── */}
      {error && !loading && (
        <div className="arena-card border-neon-orange/30 p-4 text-neon-orange text-sm text-center">
          {error}
        </div>
      )}

      {/* ── Empty state ── */}
      {!loading && !error && achievements.length === 0 && (
        <div className="flex-1 flex flex-col items-center justify-center py-20 text-center">
          <p className="text-4xl mb-4">🏆</p>
          <p className="text-zinc-400 text-sm font-medium">No achievements yet</p>
          <p className="text-zinc-600 text-xs mt-1">
            Start trading to unlock your first achievement.
          </p>
        </div>
      )}

      {/* ── Sections ── */}
      {!loading && achievements.length > 0 && (
        <div className="space-y-6 pb-6">
          {/* Earned */}
          {sections.earned.length > 0 && (
            <section>
              <SectionHeader title="Earned" count={sections.earned.length} />
              <div className="space-y-3">
                {sections.earned.map((a) => (
                  <EarnedCard key={a.id} achievement={a} />
                ))}
              </div>
            </section>
          )}

          {/* In Progress */}
          {sections.inProgress.length > 0 && (
            <section>
              <SectionHeader title="In Progress" count={sections.inProgress.length} />
              <div className="space-y-3">
                {sections.inProgress.map((a) => (
                  <InProgressCard key={a.id} achievement={a} />
                ))}
              </div>
            </section>
          )}

          {/* Locked */}
          {sections.locked.length > 0 && (
            <section>
              <SectionHeader title="Locked" count={sections.locked.length} />
              <div className="space-y-3">
                {sections.locked.map((a) => (
                  <LockedCard key={a.id} achievement={a} />
                ))}
              </div>
            </section>
          )}
        </div>
      )}
    </main>
  );
}
