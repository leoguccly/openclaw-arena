"use client";

// ============================================================
// Referral Page — Share your referral link, track referees,
// and earn free tournament entries when they join Alpha Arena.
// ============================================================

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import type { ReferralInfo, ReferralReferee } from "@/lib/types";

// ── Helpers ──────────────────────────────────────────────────

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

// ── Sub-components ────────────────────────────────────────────

function ReferralLinkCard({
  referralLink,
  onCopy,
  copied,
  onTgShare,
}: {
  referralLink: string;
  onCopy: () => void;
  copied: boolean;
  onTgShare: () => void;
}) {
  return (
    <div className="arena-card p-4 mb-4">
      <p className="text-xs text-zinc-500 uppercase tracking-wider mb-2">
        Your Referral Link
      </p>
      <div className="bg-arena-bg border border-arena-border rounded-xl px-3 py-2.5 mb-3 break-all font-mono text-xs text-neon-green">
        {referralLink}
      </div>
      <div className="grid grid-cols-2 gap-3">
        <button
          onClick={onCopy}
          className="py-3 rounded-xl font-bold text-sm border border-arena-border text-zinc-300 hover:border-neon-green hover:text-neon-green transition-all active:scale-95"
        >
          {copied ? "✓ Copied!" : "Copy Link"}
        </button>
        <button
          onClick={onTgShare}
          className="py-3 rounded-xl font-bold text-sm bg-neon-green text-arena-bg glow-green-intense hover:brightness-110 transition-all active:scale-95"
        >
          Share on TG
        </button>
      </div>
    </div>
  );
}

function StatsRow({
  totalReferrals,
}: {
  totalBonusEarned: number;
  totalReferrals: number;
}) {
  // Reward tiers: 5 → 1 entry, 10 → 2 entries, 15 → 3 entries (cap)
  const freeEntries = Math.min(3, Math.floor(totalReferrals / 5));
  const nextTier = freeEntries < 3 ? (freeEntries + 1) * 5 : null;
  const progressToNext = nextTier ? totalReferrals % 5 : 5;

  return (
    <div className="mb-4">
      {/* Stats row */}
      <div className="grid grid-cols-2 gap-3 mb-3">
        <div className="arena-card p-4 text-center">
          <p className="text-xs text-zinc-500 uppercase tracking-wider mb-1">
            Referrals
          </p>
          <p className="text-2xl font-bold text-white">{totalReferrals}</p>
          <p className="text-xs text-zinc-600 mt-0.5">qualified</p>
        </div>
        <div className="arena-card p-4 text-center">
          <p className="text-xs text-zinc-500 uppercase tracking-wider mb-1">
            Free Entries
          </p>
          <p className="text-2xl font-bold text-neon-green text-glow-green">
            🎫 {freeEntries}
          </p>
          <p className="text-xs text-zinc-600 mt-0.5">of 3 max</p>
        </div>
      </div>

      {/* Progress to next tier */}
      {nextTier && (
        <div className="arena-card p-3">
          <div className="flex justify-between text-xs text-zinc-500 mb-1.5">
            <span>Next free entry at {nextTier} referrals</span>
            <span>{progressToNext}/5</span>
          </div>
          <div className="w-full bg-arena-border rounded-full h-2">
            <div
              className="bg-neon-green rounded-full h-2 transition-all"
              style={{ width: `${(progressToNext / 5) * 100}%` }}
            />
          </div>
        </div>
      )}
      {freeEntries >= 3 && (
        <div className="arena-card p-3 text-center text-xs text-neon-green font-bold">
          🏆 Maximum rewards reached!
        </div>
      )}
    </div>
  );
}

function RefereeRow({ referee }: { referee: ReferralReferee }) {
  const confirmed = referee.bonus_paid_at !== null;
  return (
    <div className="flex items-center justify-between py-3 border-b border-arena-border last:border-0">
      <div className="min-w-0">
        <p className="text-sm font-semibold text-zinc-200 truncate">
          {referee.display_name}
        </p>
        {referee.username && (
          <p className="text-xs text-zinc-500 truncate">@{referee.username}</p>
        )}
        <p className="text-xs text-zinc-600 mt-0.5">
          Joined {fmtDate(referee.joined_at)}
        </p>
      </div>
      <span
        className={`ml-3 flex-shrink-0 text-xs font-bold px-2.5 py-1 rounded-full ${
          confirmed
            ? "bg-neon-green/10 text-neon-green border border-neon-green/30"
            : "bg-zinc-800 text-zinc-500 border border-arena-border"
        }`}
      >
        {confirmed ? "Confirmed" : "Pending"}
      </span>
    </div>
  );
}

// ── Page ──────────────────────────────────────────────────────

export default function ReferralPage() {
  const [info, setInfo] = useState<ReferralInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>("");
  const [copied, setCopied] = useState(false);

  const fetchReferralInfo = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const res = await supabase.functions.invoke("get-referral");
      if (res.error) {
        setError(res.error.message || "Failed to load referral info.");
      } else {
        const data = res.data?.data ?? res.data;
        setInfo(data as ReferralInfo);
      }
    } catch {
      setError("Network error. Please try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchReferralInfo();
  }, [fetchReferralInfo]);

  function handleCopy() {
    if (!info) return;
    navigator.clipboard.writeText(info.referral_link).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  }

  function handleTgShare() {
    if (!info) return;
    const text = encodeURIComponent(
      `Join me on Alpha Arena — trade crypto vs AI agents! Use my link to start:\n${info.referral_link}`
    );
    const tgShareUrl = `https://t.me/share/url?url=${encodeURIComponent(
      info.referral_link
    )}&text=${text}`;

    const tg = window.Telegram?.WebApp;
    if (tg?.openTelegramLink) {
      tg.openTelegramLink(tgShareUrl);
    } else {
      window.open(tgShareUrl, "_blank");
    }
  }

  return (
    <main className="flex flex-col min-h-screen px-4 pt-4 safe-bottom">
      {/* ── Header ── */}
      <header className="flex items-center gap-3 mb-6">
        <Link
          href="/"
          className="text-zinc-400 hover:text-neon-green transition-colors text-sm border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green"
        >
          ← Back
        </Link>
        <div>
          <h1 className="text-lg font-bold tracking-tight">
            <span className="text-neon-green text-glow-green">Referral</span>
            <span className="text-zinc-500 text-sm ml-1.5">Program</span>
          </h1>
          <p className="text-zinc-500 text-xs mt-0.5">
            Invite traders. Earn bonus USDT.
          </p>
        </div>
      </header>

      {/* ── Loading ── */}
      {loading && (
        <div className="arena-card p-8 flex items-center justify-center mb-4">
          <span className="text-zinc-500 text-sm animate-pulse">
            Loading referral info...
          </span>
        </div>
      )}

      {/* ── Error ── */}
      {!loading && error && (
        <div className="arena-card border-neon-orange/30 p-4 mb-4 text-center">
          <p className="text-neon-orange text-sm mb-3">{error}</p>
          <button
            onClick={fetchReferralInfo}
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            Retry
          </button>
        </div>
      )}

      {/* ── Content ── */}
      {!loading && info && (
        <>
          {/* How it works */}
          <div className="arena-card px-4 py-3 mb-4 flex items-start gap-3 border-neon-green/10">
            <span className="text-xl mt-0.5">💡</span>
            <p className="text-xs text-zinc-400 leading-relaxed">
              Share your link. When a friend joins and makes their first trade,
              you both receive a{" "}
              <span className="text-neon-green font-semibold">bonus USDT</span>{" "}
              credited to your balance.
            </p>
          </div>

          {/* Referral link + share buttons */}
          <ReferralLinkCard
            referralLink={info.referral_link}
            onCopy={handleCopy}
            copied={copied}
            onTgShare={handleTgShare}
          />

          {/* Stats */}
          <StatsRow
            totalBonusEarned={info.total_bonus_earned}
            totalReferrals={info.referees.length}
          />

          {/* Referee list */}
          <div className="arena-card p-4 mb-4">
            <p className="text-xs text-zinc-500 uppercase tracking-wider mb-1">
              Your Referrals
            </p>
            {info.referees.length === 0 ? (
              <div className="py-8 text-center">
                <p className="text-3xl mb-3">👥</p>
                <p className="text-zinc-400 text-sm">No referrals yet.</p>
                <p className="text-zinc-600 text-xs mt-1">
                  Share your link to get started.
                </p>
              </div>
            ) : (
              <div>
                {info.referees.map((referee, idx) => (
                  <RefereeRow key={idx} referee={referee} />
                ))}
              </div>
            )}
          </div>
        </>
      )}

      {/* ── Bottom Share CTA ── */}
      {!loading && info && (
        <div className="mt-auto pb-4">
          <div className="arena-card p-4 border-neon-green/20">
            <p className="text-center text-zinc-400 text-sm mb-3">
              Ready to grow your crew?
            </p>
            <button
              onClick={handleTgShare}
              className="w-full py-4 rounded-xl font-bold text-base bg-neon-green text-arena-bg glow-green-intense hover:brightness-110 transition-all active:scale-95"
            >
              🚀 Share Now on Telegram
            </button>
          </div>
        </div>
      )}
    </main>
  );
}
