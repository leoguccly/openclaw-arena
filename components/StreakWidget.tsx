"use client";

// ============================================================
// StreakWidget — Daily reward streak status + claim button.
// On mount, silently fires the claim-daily-reward Edge Function.
// If already claimed: shows green checkmark + tomorrow's bonus.
// If newly claimed: animates a bonus popup (scale + fade).
// ============================================================

import { useEffect, useState, useRef } from "react";
import { supabase } from "@/lib/supabase";
import type { DailyClaimResult } from "@/lib/types";

// Streak milestone bonuses — MUST mirror award_daily_reward_txn RPC schedule
function getStreakBonus(streak: number): number {
  if (streak >= 7) return 750;
  if (streak === 6) return 500;
  if (streak === 5) return 350;
  if (streak === 4) return 250;
  if (streak === 3) return 200;
  if (streak === 2) return 150;
  return 100; // Day 1
}

export default function StreakWidget() {
  const [result, setResult]         = useState<DailyClaimResult | null>(null);
  const [loading, setLoading]       = useState<boolean>(true);
  const [showBonus, setShowBonus]   = useState<boolean>(false);
  const [error, setError]           = useState<string>("");
  const bonusTimerRef               = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Auto-claim on mount
  useEffect(() => {
    async function claim() {
      setLoading(true);
      setError("");
      try {
        const res = await supabase.functions.invoke("claim-daily-reward", {
          body: {},
        });

        if (res.error) {
          // Silent failure — streak widget is non-critical
          setError("Could not connect to reward server.");
          return;
        }

        const data = res.data as DailyClaimResult;
        setResult(data);

        // If reward was freshly claimed (not already_claimed), show popup
        if (!data.already_claimed && data.bonus_amount > 0) {
          setShowBonus(true);
          bonusTimerRef.current = setTimeout(() => setShowBonus(false), 2800);
        }
      } catch {
        setError("Network error.");
      } finally {
        setLoading(false);
      }
    }

    claim();

    return () => {
      if (bonusTimerRef.current) clearTimeout(bonusTimerRef.current);
    };
  }, []);

  // ── Skeleton while loading ────────────────────────────────────
  if (loading) {
    return (
      <div className="arena-card px-4 py-3 mb-4 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="text-base">🔥</span>
          <span className="text-zinc-600 text-xs animate-pulse">
            Checking daily reward...
          </span>
        </div>
      </div>
    );
  }

  // ── Error state (soft — don't block page) ────────────────────
  if (error || !result) {
    return null;
  }

  const { streak, already_claimed, bonus_amount, new_balance } = result;
  const nextBonus = getStreakBonus(streak + 1);
  const isClaimed = already_claimed;

  return (
    <div className="relative arena-card px-4 py-3 mb-4 overflow-hidden">
      {/* ── Bonus popup animation ── */}
      {showBonus && (
        <div
          className="absolute inset-0 flex items-center justify-center pointer-events-none z-10"
          style={{ animation: "streak-bonus-pop 2.8s ease-out forwards" }}
        >
          <div className="flex flex-col items-center">
            <span
              className="text-3xl font-bold text-neon-green text-glow-green"
              style={{ animation: "streak-bonus-pop 2.8s ease-out forwards" }}
            >
              +{bonus_amount} USDT
            </span>
            <span className="text-xs text-zinc-400 mt-1">Daily reward claimed!</span>
          </div>
        </div>
      )}

      <div className={`flex items-center justify-between transition-opacity duration-500 ${showBonus ? "opacity-10" : "opacity-100"}`}>
        {/* Left: flame + streak info */}
        <div className="flex items-center gap-2.5 min-w-0">
          <div className="relative flex-shrink-0">
            {!isClaimed && (
              <span className="absolute inset-0 rounded-full animate-ping bg-neon-orange/25" />
            )}
            <span className="relative text-xl">🔥</span>
          </div>

          <div className="min-w-0">
            <div className="flex items-baseline gap-1.5">
              <span className="text-sm font-bold text-white">
                Day {streak}
              </span>
              <span className="text-zinc-500 text-xs">streak</span>
              {isClaimed && (
                <span className="text-neon-green text-xs font-bold">✓</span>
              )}
            </div>
            <p className="text-xs text-zinc-500 truncate">
              {isClaimed
                ? `Tomorrow: +${nextBonus} USDT`
                : `Claim +${bonus_amount} USDT today`}
            </p>
          </div>
        </div>

        {/* Right: balance chip OR claim indicator */}
        {isClaimed ? (
          <div className="flex-shrink-0 ml-3 flex flex-col items-end">
            <span className="text-xs text-zinc-500 uppercase tracking-wider">
              Balance
            </span>
            <span className="text-xs font-bold text-neon-green tabular-nums">
              ${new_balance.toLocaleString("en-US", { maximumFractionDigits: 0 })}
            </span>
          </div>
        ) : (
          <div className="flex-shrink-0 ml-3">
            <span
              className="
                inline-block px-3 py-1.5 rounded-xl text-xs font-bold
                bg-neon-orange/15 text-neon-orange border border-neon-orange/40
                animate-pulse
              "
            >
              Claim +{bonus_amount}
            </span>
          </div>
        )}
      </div>

      <style>{`
        @keyframes streak-bonus-pop {
          0%   { opacity: 0; transform: scale(0.7) translateY(8px); }
          15%  { opacity: 1; transform: scale(1.1) translateY(0); }
          70%  { opacity: 1; transform: scale(1) translateY(0); }
          100% { opacity: 0; transform: scale(0.95) translateY(-6px); }
        }
      `}</style>
    </div>
  );
}
