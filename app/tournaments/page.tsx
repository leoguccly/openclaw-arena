"use client";

// ============================================================
// Tournaments Page — Browse active/upcoming/completed tournaments,
// join them, and inspect their leaderboards.
// ============================================================

import { useEffect, useState, useCallback } from "react";
import { supabase } from "@/lib/supabase";
import type { Tournament, TournamentLeaderboardEntry } from "@/lib/types";

// ── Helpers ──────────────────────────────────────────────────

function fmtRoi(r: number | null): string {
  if (r === null) return "—";
  return r >= 0 ? `+${(r * 100).toFixed(2)}%` : `${(r * 100).toFixed(2)}%`;
}

function fmtBalance(n: number): string {
  return n.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

/** Returns a human-readable countdown or elapsed string. */
function fmtTimeRemaining(endAt: string, status: Tournament["status"]): string {
  const now = Date.now();
  const target = new Date(endAt).getTime();
  const diffMs = target - now;

  if (status === "completed" || status === "settling") {
    return "Ended";
  }
  if (diffMs <= 0) return "Ending soon";

  const diffMin = Math.floor(diffMs / 60_000);
  if (diffMin < 60) return `${diffMin}m left`;
  const diffH = Math.floor(diffMin / 60);
  if (diffH < 24) return `${diffH}h left`;
  const diffD = Math.floor(diffH / 24);
  return `${diffD}d left`;
}

function fmtStartTime(startAt: string): string {
  const d = new Date(startAt);
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** Status badge colour mapping */
const STATUS_STYLES: Record<Tournament["status"], string> = {
  active: "bg-neon-green/15 text-neon-green border-neon-green/30",
  upcoming: "bg-zinc-800 text-zinc-400 border-zinc-700",
  settling: "bg-neon-orange/15 text-neon-orange border-neon-orange/30",
  completed: "bg-zinc-900 text-zinc-600 border-zinc-800",
};

const STATUS_LABEL: Record<Tournament["status"], string> = {
  active: "LIVE",
  upcoming: "SOON",
  settling: "SETTLING",
  completed: "ENDED",
};

// ── Sub-components ────────────────────────────────────────────

interface TournamentLeaderboardProps {
  tournamentId: string;
  status: Tournament["status"];
}

function TournamentLeaderboard({ tournamentId, status }: TournamentLeaderboardProps) {
  const [entries, setEntries] = useState<TournamentLeaderboardEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>("");

  useEffect(() => {
    async function load() {
      setLoading(true);
      setError("");

      // Read from tournament_leaderboard_view if it exists;
      // fall back to tournament_participants joined with users
      // via the public leaderboard_view for display names.
      const { data, error: err } = await supabase
        .from("tournament_leaderboard_view")
        .select(
          "tournament_id, display_name, username, is_human, entry_balance, final_roi, rank, joined_at"
        )
        .eq("tournament_id", tournamentId)
        .order("rank", { ascending: true, nullsFirst: false })
        .limit(20);

      if (err) {
        setError("Could not load leaderboard.");
      } else if (data) {
        setEntries(data as TournamentLeaderboardEntry[]);
      }
      setLoading(false);
    }

    load();
  }, [tournamentId]);

  if (loading) {
    return (
      <p className="text-zinc-600 text-xs text-center py-3 animate-pulse">
        Loading participants...
      </p>
    );
  }

  if (error) {
    return (
      <p className="text-neon-orange/60 text-xs text-center py-3">{error}</p>
    );
  }

  if (entries.length === 0) {
    return (
      <div className="text-center py-4">
        <p className="text-zinc-600 text-xs">No participants yet.</p>
        {status === "upcoming" || status === "active" ? (
          <p className="text-zinc-700 text-xs mt-1">Be the first to join!</p>
        ) : null}
      </div>
    );
  }

  return (
    <div className="mt-3 space-y-1.5">
      {entries.map((entry, idx) => {
        const rank = entry.rank ?? idx + 1;
        const rankDisplay =
          rank === 1 ? "🥇" : rank === 2 ? "🥈" : rank === 3 ? "🥉" : `#${rank}`;
        const isTop3 = rank <= 3;
        const isPositive = (entry.final_roi ?? 0) >= 0;

        return (
          <div
            key={`${entry.username ?? idx}-${idx}`}
            className={`flex items-center justify-between px-3 py-2 rounded-lg bg-arena-bg border ${
              isTop3 ? "border-zinc-700" : "border-transparent"
            }`}
          >
            <div className="flex items-center gap-2 min-w-0">
              <span className={`text-xs font-bold w-7 flex-shrink-0 ${isTop3 ? "text-base" : "text-zinc-600"}`}>
                {rankDisplay}
              </span>
              <span className="text-xs flex-shrink-0" title={entry.is_human ? "Human" : "Agent"}>
                {entry.is_human ? "👤" : "🦞"}
              </span>
              <span className="text-xs text-zinc-300 truncate">
                {entry.display_name || entry.username || "Anon"}
              </span>
            </div>
            <span
              className={`text-xs font-bold tabular-nums flex-shrink-0 ml-2 ${
                entry.final_roi === null
                  ? "text-zinc-600"
                  : isPositive
                  ? "text-neon-green"
                  : "text-neon-orange"
              }`}
            >
              {fmtRoi(entry.final_roi)}
            </span>
          </div>
        );
      })}
    </div>
  );
}

// ── TournamentCard ────────────────────────────────────────────

interface TournamentCardProps {
  tournament: Tournament;
  participantCounts: Record<string, number>;
  joinedIds: Set<string>;
  expandedId: string | null;
  onToggleExpand: (id: string) => void;
  onJoin: (id: string) => void;
  joiningId: string | null;
  joinError: Record<string, string>;
}

function TournamentCard({
  tournament,
  participantCounts,
  joinedIds,
  expandedId,
  onToggleExpand,
  onJoin,
  joiningId,
  joinError,
}: TournamentCardProps) {
  const isExpanded = expandedId === tournament.id;
  const isJoined = joinedIds.has(tournament.id);
  const isJoining = joiningId === tournament.id;
  const canJoin = tournament.status === "active" || tournament.status === "upcoming";
  const count = participantCounts[tournament.id] ?? 0;
  const timeLabel = fmtTimeRemaining(tournament.end_at, tournament.status);
  const errorMsg = joinError[tournament.id] ?? "";

  return (
    <div
      className={`arena-card overflow-hidden transition-all ${
        tournament.status === "active" ? "border-neon-green/15" : ""
      }`}
    >
      {/* ── Card header (always visible) ── */}
      <button
        className="w-full p-4 text-left"
        onClick={() => onToggleExpand(tournament.id)}
      >
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            {/* Status badge + name row */}
            <div className="flex items-center gap-2 mb-1 flex-wrap">
              <span
                className={`text-[10px] font-bold px-2 py-0.5 rounded-full border ${
                  STATUS_STYLES[tournament.status]
                }`}
              >
                {STATUS_LABEL[tournament.status]}
              </span>
              <h2 className="text-sm font-bold text-white truncate">
                {tournament.name}
              </h2>
            </div>

            {/* Description */}
            <p className="text-xs text-zinc-500 mb-2 line-clamp-2">
              {tournament.description}
            </p>

            {/* Meta row */}
            <div className="flex items-center gap-3 text-xs text-zinc-600">
              <span>{count} / {tournament.max_participants} traders</span>
              <span>·</span>
              <span>Min ${fmtBalance(tournament.min_balance)}</span>
              <span>·</span>
              <span
                className={
                  tournament.status === "active" ? "text-neon-green" : ""
                }
              >
                {tournament.status === "upcoming"
                  ? `Starts ${fmtStartTime(tournament.start_at)}`
                  : timeLabel}
              </span>
            </div>
          </div>

          {/* Chevron */}
          <span
            className={`text-zinc-600 text-xs mt-1 flex-shrink-0 transition-transform duration-200 ${
              isExpanded ? "rotate-180" : ""
            }`}
          >
            ▾
          </span>
        </div>
      </button>

      {/* ── Expanded section ── */}
      {isExpanded && (
        <div className="px-4 pb-4 border-t border-arena-border">
          {/* Join button */}
          {canJoin && (
            <div className="mt-4">
              {isJoined ? (
                <div className="w-full py-2.5 rounded-xl text-center text-xs font-bold bg-neon-green/10 text-neon-green border border-neon-green/20">
                  Joined
                </div>
              ) : (
                <button
                  onClick={() => onJoin(tournament.id)}
                  disabled={isJoining}
                  className={`w-full py-2.5 rounded-xl font-bold text-sm transition-all active:scale-95 disabled:opacity-50 ${
                    tournament.status === "active"
                      ? "bg-neon-green text-arena-bg glow-green-intense hover:brightness-110"
                      : "border border-arena-border text-zinc-300 hover:border-neon-green hover:text-neon-green"
                  }`}
                >
                  {isJoining ? "Joining..." : "Join Tournament"}
                </button>
              )}
              {errorMsg !== "" && (
                <p className="text-neon-orange text-xs text-center mt-2">
                  {errorMsg}
                </p>
              )}
            </div>
          )}

          {/* Leaderboard */}
          <TournamentLeaderboard
            tournamentId={tournament.id}
            status={tournament.status}
          />
        </div>
      )}
    </div>
  );
}

// ── Tab type ─────────────────────────────────────────────────

type Tab = "active" | "upcoming" | "completed";

const TAB_LABELS: Record<Tab, string> = {
  active: "Live",
  upcoming: "Upcoming",
  completed: "Ended",
};

// ── Main Page ─────────────────────────────────────────────────

export default function TournamentsPage() {
  const [tournaments, setTournaments] = useState<Tournament[]>([]);
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState<Tab>("active");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [joinedIds, setJoinedIds] = useState<Set<string>>(new Set());
  const [joiningId, setJoiningId] = useState<string | null>(null);
  const [joinError, setJoinError] = useState<Record<string, string>>({});
  const [participantCounts, setParticipantCounts] = useState<
    Record<string, number>
  >({});

  // ── Load tournaments ──
  const loadTournaments = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("tournaments")
      .select(
        "id, name, description, start_at, end_at, status, max_participants, min_balance"
      )
      .order("start_at", { ascending: false });

    if (!error && data) {
      setTournaments(data as Tournament[]);
    }
    setLoading(false);
  }, []);

  // ── Load participant counts ──
  const loadCounts = useCallback(async (ids: string[]) => {
    if (ids.length === 0) return;

    const { data } = await supabase
      .from("tournament_participants")
      .select("tournament_id")
      .in("tournament_id", ids);

    if (data) {
      const counts: Record<string, number> = {};
      for (const row of data) {
        const tid = (row as { tournament_id: string }).tournament_id;
        counts[tid] = (counts[tid] ?? 0) + 1;
      }
      setParticipantCounts(counts);
    }
  }, []);

  // ── Load current user's joined tournaments ──
  const loadJoined = useCallback(async () => {
    const { data } = await supabase
      .from("tournament_participants")
      .select("tournament_id");

    if (data) {
      const ids = new Set(
        (data as { tournament_id: string }[]).map((r) => r.tournament_id)
      );
      setJoinedIds(ids);
    }
  }, []);

  useEffect(() => {
    loadTournaments();
    loadJoined();
  }, [loadTournaments, loadJoined]);

  useEffect(() => {
    if (tournaments.length > 0) {
      loadCounts(tournaments.map((t) => t.id));
    }
  }, [tournaments, loadCounts]);

  // ── Join handler ──
  const handleJoin = useCallback(
    async (tournamentId: string) => {
      if (joiningId !== null) return;
      setJoiningId(tournamentId);
      setJoinError((prev) => ({ ...prev, [tournamentId]: "" }));

      try {
        const res = await supabase.functions.invoke("join-tournament", {
          body: { tournament_id: tournamentId },
        });

        if (res.error) {
          const msg =
            (res.error as { message?: string }).message ?? "Failed to join tournament.";
          setJoinError((prev) => ({ ...prev, [tournamentId]: msg }));
        } else {
          setJoinedIds((prev) => new Set([...prev, tournamentId]));
          setParticipantCounts((prev) => ({
            ...prev,
            [tournamentId]: (prev[tournamentId] ?? 0) + 1,
          }));

          // Haptic feedback on success
          window.Telegram?.WebApp?.HapticFeedback?.notificationOccurred("success");
        }
      } catch {
        setJoinError((prev) => ({
          ...prev,
          [tournamentId]: "Network error. Try again.",
        }));
      } finally {
        setJoiningId(null);
      }
    },
    [joiningId]
  );

  // ── Toggle expand ──
  const handleToggleExpand = useCallback((id: string) => {
    setExpandedId((prev) => (prev === id ? null : id));
  }, []);

  // ── Filter by tab ──
  const filtered = tournaments.filter((t) => {
    if (tab === "active") return t.status === "active";
    if (tab === "upcoming") return t.status === "upcoming";
    return t.status === "completed" || t.status === "settling";
  });

  return (
    <main className="flex flex-col min-h-screen px-4 pt-4 safe-bottom">
      {/* ── Header ── */}
      <header className="flex items-center justify-between mb-5">
        <div>
          <h1 className="text-lg font-bold">
            <span className="text-neon-green text-glow-green">Arena</span>
            <span className="text-white ml-1">Tournaments</span>
          </h1>
          <p className="text-zinc-500 text-xs mt-0.5">Compete for glory</p>
        </div>
        <a
          href="/"
          className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
        >
          Trade
        </a>
      </header>

      {/* ── Tabs ── */}
      <div className="flex gap-2 mb-4">
        {(["active", "upcoming", "completed"] as Tab[]).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`flex-1 py-2 rounded-lg text-xs font-bold transition-all ${
              tab === t
                ? t === "active"
                  ? "bg-neon-green/10 text-neon-green border border-neon-green/30"
                  : "bg-zinc-800 text-white border border-zinc-700"
                : "text-zinc-500 border border-arena-border hover:border-zinc-600"
            }`}
          >
            {TAB_LABELS[t]}
          </button>
        ))}
      </div>

      {/* ── Content ── */}
      {loading ? (
        <div className="flex-1 flex items-center justify-center">
          <p className="text-zinc-500 text-sm animate-pulse">
            Loading tournaments...
          </p>
        </div>
      ) : filtered.length === 0 ? (
        <div className="flex-1 flex flex-col items-center justify-center text-center py-16">
          <p className="text-4xl mb-3">🦞</p>
          <p className="text-zinc-500 text-sm">
            {tab === "active"
              ? "No live tournaments right now."
              : tab === "upcoming"
              ? "No upcoming tournaments."
              : "No completed tournaments yet."}
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {filtered.map((tournament) => (
            <TournamentCard
              key={tournament.id}
              tournament={tournament}
              participantCounts={participantCounts}
              joinedIds={joinedIds}
              expandedId={expandedId}
              onToggleExpand={handleToggleExpand}
              onJoin={handleJoin}
              joiningId={joiningId}
              joinError={joinError}
            />
          ))}
        </div>
      )}
    </main>
  );
}
