"use client";

import { useRef, useState, useCallback, useEffect } from "react";
import type { Trade } from "@/lib/types";

// ============================================================
// CyberPoster — Nuclear-grade Viral Battle Report Generator
// ============================================================
//
// ARCHITECTURE (PO + code-architect requirement):
// The poster DOM lives OFF-SCREEN at `left: -9999px` during normal
// browsing. It never pollutes the trading panel layout or affects
// page performance. When the user taps "Generate", html2canvas
// captures this off-screen DOM into a canvas, then we display the
// resulting PNG image in a modal overlay.
//
// html2canvas CAN capture elements positioned off-screen — it reads
// the computed DOM styles regardless of viewport visibility. The
// off-screen element must NOT be `display: none` or `visibility: hidden`
// (those would collapse layout), hence we use `position: absolute;
// left: -9999px`.
//
// RETINA FIX:
// `scale: window.devicePixelRatio` ensures crisp rendering on
// iPhone Retina (3x), Android high-DPI (2.75x), etc.
// Poster uses explicit pixel dimensions (390x640) to prevent
// html2canvas layout miscalculation.
// ============================================================

interface CyberPosterProps {
  trade: Trade;
  pnl: number;
  currentPrice: number;
  username: string;
  roi: number;
  openclawRoi?: number | null;
  tournamentRank?: number | null;
  onClose: () => void;
}

// ── Taunt text pool — randomly selected for variety ──
const TAUNT_PROFIT = [
  "我正在 Alpha Arena 屠杀市场。你是人类，还是 AI？",
  "你还在观望？我已经在印钞了。",
  "龙虾看了沉默，人类看了流泪。",
  "这不是运气，这是降维打击。",
];

const TAUNT_LOSS = [
  "我正在 Alpha Arena 被市场教做人。你敢来吗？",
  "倒下不可怕，可怕的是你连下场的勇气都没有。",
  "今天是龙虾的晚餐，明天轮到我。",
  "亏钱也要亏得有排面。",
];

export default function CyberPoster({
  trade,
  pnl,
  currentPrice,
  username,
  roi,
  openclawRoi,
  tournamentRank,
  onClose,
}: CyberPosterProps) {
  const posterRef = useRef<HTMLDivElement>(null);
  const [generating, setGenerating] = useState(false);
  const [imageUrl, setImageUrl] = useState<string | null>(null);
  const [taunt, setTaunt] = useState("");

  const isProfit = pnl >= 0;
  const pnlPercent = trade.margin > 0 ? (pnl / trade.margin) * 100 : 0;
  const fmtPnl = isProfit ? `+${pnl.toFixed(2)}` : pnl.toFixed(2);
  const fmtPercent = isProfit
    ? `+${pnlPercent.toFixed(1)}%`
    : `${pnlPercent.toFixed(1)}%`;
  const fmtRoi = roi >= 0
    ? `+${(roi * 100).toFixed(2)}%`
    : `${(roi * 100).toFixed(2)}%`;

  // Pick a random taunt on mount
  useEffect(() => {
    const pool = isProfit ? TAUNT_PROFIT : TAUNT_LOSS;
    setTaunt(pool[Math.floor(Math.random() * pool.length)]);
  }, [isProfit]);

  // Auto-generate on mount so user sees the poster immediately
  useEffect(() => {
    // Small delay to ensure off-screen DOM has painted
    const timer = setTimeout(() => { generatePoster(); }, 200);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const generatePoster = useCallback(async () => {
    if (!posterRef.current || generating) return;

    setGenerating(true);
    try {
      const html2canvas = (await import("html2canvas")).default;

      const canvas = await html2canvas(posterRef.current, {
        // RETINA FIX: Render at native device pixel ratio.
        // iPhone 15 Pro = 3x, most Android flagships = 2.75x.
        // Fallback to 2x for SSR/desktop edge cases.
        scale: typeof window !== "undefined" ? (window.devicePixelRatio || 2) : 2,

        useCORS: true,
        backgroundColor: null,
        logging: false,
        scrollX: 0,
        scrollY: 0,
        // Explicit dimensions prevent html2canvas from reading
        // the off-screen position as "zero-size element".
        width: 390,
        height: 640,
        windowWidth: 390,
        windowHeight: 640,
      });

      const dataUrl = canvas.toDataURL("image/png", 1.0);
      setImageUrl(dataUrl);

      window.Telegram?.WebApp?.HapticFeedback?.notificationOccurred("success");
    } catch (err) {
      console.error("[CyberPoster] Generation failed:", err);
    } finally {
      setGenerating(false);
    }
  }, [generating]);

  const handleShare = useCallback(async () => {
    if (!imageUrl) return;

    const shareText = `${isProfit ? "🟢" : "🔴"} ${fmtPercent} on ${trade.symbol} ${trade.direction.toUpperCase()} ${trade.leverage}x — Alpha Arena`;

    // Try Telegram native inline share first (TG Web App SDK >= 6.9)
    const tgWebApp = window.Telegram?.WebApp;
    if (tgWebApp && typeof tgWebApp.switchInlineQuery === "function") {
      try {
        tgWebApp.switchInlineQuery(shareText, ["users", "groups", "channels"]);
        return;
      } catch {
        // Fall through to Web Share API
      }
    }

    // Web Share API (works on most mobile browsers)
    if (navigator.share && navigator.canShare) {
      try {
        const blob = await fetch(imageUrl).then((r) => r.blob());
        const file = new File([blob], "openclaw-battle-report.png", {
          type: "image/png",
        });
        if (navigator.canShare({ files: [file] })) {
          await navigator.share({
            files: [file],
            title: "Alpha Arena",
            text: shareText,
          });
          return;
        }
      } catch {
        // Fall through to download
      }
    }

    // Fallback: direct download
    const link = document.createElement("a");
    link.href = imageUrl;
    link.download = "openclaw-battle-report.png";
    link.click();
  }, [imageUrl, isProfit, fmtPercent, trade]);

  // ── Neon color resolved for inline styles (html2canvas needs inline) ──
  const neonColor = isProfit ? "#00FF88" : "#FF6B35";
  const neonGlow = isProfit
    ? "0 0 40px rgba(0,255,136,0.6), 0 0 100px rgba(0,255,136,0.25)"
    : "0 0 40px rgba(255,107,53,0.6), 0 0 100px rgba(255,107,53,0.25)";
  const neonTextGlow = isProfit
    ? "0 0 20px rgba(0,255,136,0.7), 0 0 60px rgba(0,255,136,0.3), 0 0 120px rgba(0,255,136,0.15)"
    : "0 0 20px rgba(255,107,53,0.7), 0 0 60px rgba(255,107,53,0.3), 0 0 120px rgba(255,107,53,0.15)";

  return (
    <>
      {/* ================================================================
          OFF-SCREEN POSTER DOM
          ================================================================
          This div is positioned at left: -9999px. It is NEVER visible
          to the user. html2canvas reads its computed styles and paints
          them onto a <canvas> — visibility/position doesn't matter.

          DO NOT use display:none or visibility:hidden — those collapse
          the element's layout and html2canvas would capture a 0x0 box.
          ================================================================ */}
      <div
        ref={posterRef}
        style={{
          position: "absolute",
          left: "-9999px",
          top: 0,
          width: 390,
          height: 640,
          overflow: "hidden",
          // Prevent any page interaction with the off-screen element
          pointerEvents: "none",
        }}
      >
        {/* ── Background layers ── */}
        {/* Base gradient */}
        <div
          style={{
            position: "absolute",
            inset: 0,
            background: isProfit
              ? "linear-gradient(160deg, #08080A 0%, #081A10 35%, #0A120A 60%, #08080A 100%)"
              : "linear-gradient(160deg, #08080A 0%, #1A0C08 35%, #120A0A 60%, #08080A 100%)",
          }}
        />

        {/* Giant lobster watermark — tilted, ultra-low opacity */}
        <div
          style={{
            position: "absolute",
            top: "50%",
            left: "50%",
            transform: "translate(-50%, -50%) rotate(-25deg)",
            fontSize: 280,
            opacity: 0.04,
            lineHeight: 1,
            userSelect: "none",
            // html2canvas renders emoji as text — this is intentional
          }}
        >
          🦞
        </div>

        {/* Subtle grid pattern overlay for cyberpunk texture */}
        <div
          style={{
            position: "absolute",
            inset: 0,
            opacity: 0.03,
            backgroundImage:
              "linear-gradient(rgba(255,255,255,0.1) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.1) 1px, transparent 1px)",
            backgroundSize: "24px 24px",
          }}
        />

        {/* ── Content ── */}
        <div
          style={{
            position: "relative",
            zIndex: 10,
            padding: 28,
            display: "flex",
            flexDirection: "column",
            height: "100%",
            fontFamily: "'Space Grotesk', monospace",
          }}
        >
          {/* ─── HEADER: Logo + Event Tag ─── */}
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 8 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{ fontSize: 28 }}>🦞</span>
              <div>
                <div style={{ color: "#ffffff", fontWeight: 700, fontSize: 14, letterSpacing: 2 }}>
                  ALPHA ARENA
                </div>
                <div style={{ color: "#52525b", fontSize: 10, letterSpacing: 3, marginTop: 1 }}>
                  TG BATTLE
                </div>
              </div>
            </div>
            <span style={{ fontSize: 24 }}>{isProfit ? "🏆" : "💀"}</span>
          </div>

          {/* Thin separator line with neon tint */}
          <div
            style={{
              height: 1,
              background: `linear-gradient(90deg, transparent, ${neonColor}40, transparent)`,
              marginBottom: 24,
            }}
          />

          {/* ─── CORE STRIKE ZONE ─── */}
          <div style={{ textAlign: "center", flex: 1, display: "flex", flexDirection: "column", justifyContent: "center" }}>
            {/* Trade info line */}
            <div style={{ color: "#a1a1aa", fontSize: 15, fontWeight: 500, letterSpacing: 1, marginBottom: 8 }}>
              {trade.symbol} | {trade.leverage}X {trade.direction.toUpperCase()}
            </div>

            {/* ── THE GIANT ROI NUMBER ── */}
            <div
              style={{
                color: neonColor,
                fontSize: 72,
                fontWeight: 900,
                lineHeight: 1,
                letterSpacing: -2,
                textShadow: neonTextGlow,
                marginTop: 4,
                marginBottom: 4,
              }}
            >
              {fmtPercent}
            </div>

            {/* PnL in USDT beneath */}
            <div style={{ color: "#71717a", fontSize: 14, marginBottom: 20 }}>
              {fmtPnl} USDT
            </div>

            {/* ── THE TAUNT ── */}
            <div
              style={{
                color: "#a1a1aa",
                fontSize: 12,
                fontStyle: "italic",
                lineHeight: 1.6,
                maxWidth: 280,
                margin: "0 auto",
                paddingTop: 8,
                borderTop: "1px solid rgba(255,255,255,0.06)",
              }}
            >
              &ldquo;{taunt}&rdquo;
            </div>
          </div>

          {/* ─── VS ALPHA AGENTS COMPARISON ─── */}
          {openclawRoi != null && (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                gap: 16,
                padding: "10px 0",
                borderTop: "1px solid rgba(255,255,255,0.06)",
                marginBottom: 8,
              }}
            >
              <div style={{ textAlign: "center" }}>
                <div style={{ color: "#52525b", fontSize: 9, letterSpacing: 1, marginBottom: 2 }}>👤 YOU</div>
                <div style={{ color: neonColor, fontSize: 16, fontWeight: 800 }}>{fmtRoi}</div>
              </div>
              <div style={{ color: "#3f3f46", fontSize: 14, fontWeight: 700, letterSpacing: 2 }}>VS</div>
              <div style={{ textAlign: "center" }}>
                <div style={{ color: "#52525b", fontSize: 9, letterSpacing: 1, marginBottom: 2 }}>🤖 THE ALPHAS</div>
                <div style={{
                  color: openclawRoi >= 0 ? "#00FF88" : "#FF6B35",
                  fontSize: 16,
                  fontWeight: 800,
                }}>
                  {openclawRoi >= 0 ? "+" : ""}{(openclawRoi * 100).toFixed(2)}%
                </div>
              </div>
            </div>
          )}

          {/* ─── TOURNAMENT RANK BADGE ─── */}
          {tournamentRank != null && (
            <div
              style={{
                textAlign: "center",
                padding: "6px 0",
                marginBottom: 4,
              }}
            >
              <span style={{
                background: "rgba(255,255,255,0.05)",
                border: `1px solid ${neonColor}30`,
                borderRadius: 8,
                padding: "4px 12px",
                color: neonColor,
                fontSize: 11,
                fontWeight: 700,
                letterSpacing: 1,
              }}>
                🏆 TOURNAMENT RANK #{tournamentRank}
              </span>
            </div>
          )}

          {/* ─── TRADE DETAILS STRIP ─── */}
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "1fr 1fr 1fr",
              gap: 12,
              padding: "12px 0",
              borderTop: "1px solid rgba(255,255,255,0.06)",
              borderBottom: "1px solid rgba(255,255,255,0.06)",
              marginBottom: 20,
            }}
          >
            <div style={{ textAlign: "center" }}>
              <div style={{ color: "#52525b", fontSize: 9, letterSpacing: 1, marginBottom: 2 }}>ENTRY</div>
              <div style={{ color: "#ffffff", fontSize: 12, fontWeight: 600 }}>${trade.entry_price.toLocaleString()}</div>
            </div>
            <div style={{ textAlign: "center" }}>
              <div style={{ color: "#52525b", fontSize: 9, letterSpacing: 1, marginBottom: 2 }}>EXIT</div>
              <div style={{ color: "#ffffff", fontSize: 12, fontWeight: 600 }}>${currentPrice.toLocaleString()}</div>
            </div>
            <div style={{ textAlign: "center" }}>
              <div style={{ color: "#52525b", fontSize: 9, letterSpacing: 1, marginBottom: 2 }}>TOTAL ROI</div>
              <div style={{ color: neonColor, fontSize: 12, fontWeight: 700 }}>{fmtRoi}</div>
            </div>
          </div>

          {/* ─── FOOTER: CTA + User ─── */}
          <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between" }}>
            {/* Left: QR placeholder + CTA */}
            <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
              {/* Simulated QR code placeholder */}
              <div
                style={{
                  width: 48,
                  height: 48,
                  borderRadius: 8,
                  border: `1px solid ${neonColor}30`,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  fontSize: 22,
                  background: "rgba(255,255,255,0.02)",
                }}
              >
                🦞
              </div>
              <div>
                <div style={{ color: "#a1a1aa", fontSize: 10, fontWeight: 600, letterSpacing: 0.5 }}>
                  @AlphaArenaBot
                </div>
                <div style={{ color: "#52525b", fontSize: 9, marginTop: 2 }}>
                  扫码入场，领取 10,000 U 初始资金
                </div>
              </div>
            </div>

            {/* Right: User + date */}
            <div style={{ textAlign: "right" }}>
              <div style={{ color: "#ffffff", fontSize: 11, fontWeight: 600 }}>{username}</div>
              <div style={{ color: "#3f3f46", fontSize: 9, marginTop: 1 }}>
                {new Date().toLocaleDateString("en-US", {
                  month: "short",
                  day: "numeric",
                  year: "numeric",
                })}
              </div>
            </div>
          </div>

          {/* Bottom neon glow bar */}
          <div
            style={{
              height: 2,
              borderRadius: 1,
              marginTop: 16,
              background: `linear-gradient(90deg, transparent, ${neonColor}, transparent)`,
              boxShadow: neonGlow,
            }}
          />
        </div>
      </div>

      {/* ================================================================
          VISIBLE MODAL OVERLAY
          ================================================================
          This is what the user sees — action buttons + generated image.
          The poster DOM above is invisible; only the PNG result shows here.
          ================================================================ */}
      <div className="fixed inset-0 z-50 bg-black/85 backdrop-blur-sm flex flex-col items-center justify-center p-4 overflow-y-auto">
        {/* Close button */}
        <button
          onClick={onClose}
          className="absolute top-4 right-4 text-zinc-500 hover:text-white text-2xl z-10"
          style={{ paddingTop: "var(--safe-area-top)" }}
        >
          ✕
        </button>

        {/* Loading state */}
        {generating && !imageUrl && (
          <div className="flex flex-col items-center gap-4">
            <div className="text-4xl animate-pulse">🦞</div>
            <p className="text-zinc-400 text-sm animate-pulse">Generating battle report...</p>
          </div>
        )}

        {/* Generated poster preview */}
        {imageUrl && (
          <>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={imageUrl}
              alt="Battle Report"
              className="max-w-[360px] w-full rounded-2xl border border-arena-border shadow-2xl"
            />

            {/* Action buttons */}
            <div className="flex gap-3 mt-6 w-full max-w-[360px]">
              <button
                onClick={handleShare}
                className={`flex-1 py-3.5 rounded-xl font-bold text-sm transition-all active:scale-95 ${
                  isProfit
                    ? "bg-neon-green text-arena-bg glow-green-intense"
                    : "bg-neon-orange text-arena-bg glow-orange-intense"
                }`}
              >
                Share Battle Report
              </button>
              <button
                onClick={() => {
                  setImageUrl(null);
                  setTimeout(() => generatePoster(), 100);
                }}
                className="px-5 py-3.5 rounded-xl border border-arena-border text-zinc-400 hover:text-white text-sm transition-colors"
              >
                Retry
              </button>
            </div>

            <p className="text-zinc-600 text-xs mt-3">
              Long press image to save &bull; Tap Share to send
            </p>
          </>
        )}
      </div>
    </>
  );
}
