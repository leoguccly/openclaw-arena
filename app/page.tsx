"use client";

import { useEffect, useState, useRef } from "react";
import { initTelegramWebApp, getTelegramUser } from "@/lib/tg-auth";
import { supabase } from "@/lib/supabase";
import { subscribeBinancePrice } from "@/lib/binance-ws";
import type { Trade } from "@/lib/types";
import CyberPoster from "@/components/CyberPoster";
import Sparkline from "@/components/Sparkline";
import OpenClawWidget from "@/components/OpenClawWidget";
import StreakWidget from "@/components/StreakWidget";

// ============================================================
// Symbols
// ============================================================
const SYMBOLS = ["BTC/USDT", "ETH/USDT"] as const;
type Symbol = (typeof SYMBOLS)[number];

const SYMBOL_TO_BINANCE: Record<Symbol, string> = {
  "BTC/USDT": "BTCUSDT",
  "ETH/USDT": "ETHUSDT",
};

// ============================================================
// Main Trading Page
// ============================================================
export default function TradingPage() {
  // --- State ---
  const [tgUser, setTgUser] = useState<{ id: number; first_name: string } | null>(null);
  const [balance, setBalance] = useState<number>(10000);
  const [roi, setRoi] = useState<number>(0);
  const [symbol, setSymbol] = useState<Symbol>("BTC/USDT");
  const [direction, setDirection] = useState<"long" | "short">("long");
  const [leverage, setLeverage] = useState<number>(10);
  const [margin, setMargin] = useState<string>("100");
  const [price, setPrice] = useState<number | null>(null);
  const [openTrade, setOpenTrade] = useState<Trade | null>(null);
  const [floatingPnl, setFloatingPnl] = useState<number>(0);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string>("");
  const [showPoster, setShowPoster] = useState<boolean>(false);
  const [lastClosedTrade, setLastClosedTrade] = useState<Trade | null>(null);
  const [priceHistory, setPriceHistory] = useState<number[]>([]);
  const [accessToken, setAccessToken] = useState<string>("");
  const [debugInfo, setDebugInfo] = useState<string>("");
  const [showAddMargin, setShowAddMargin] = useState(false);
  const [addMarginAmount, setAddMarginAmount] = useState("");
  const [addMarginLoading, setAddMarginLoading] = useState(false);

  const SPARKLINE_MAX_POINTS = 50;

  // --- Init TG Web App + silent auth + referral code handling ---
  useEffect(() => {
    async function init() {
      const webapp = initTelegramWebApp();
      const user = getTelegramUser();
      if (user) {
        setTgUser({ id: user.id, first_name: user.first_name });
      }

      // 静默登录：用 Telegram initData 换取 Supabase session
      let token = "";
      const initData = window.Telegram?.WebApp?.initData;
      if (initData && initData.length > 0) {
        const { data, error } = await supabase.functions.invoke("tg-auth", {
          body: { initData },
        });
        if (!error && data?.access_token) {
          await supabase.auth.setSession({
            access_token: data.access_token,
            refresh_token: data.refresh_token ?? "",
          });
          token = data.access_token;
          setAccessToken(token);
        }
      } else {
        const tgId = window.Telegram?.WebApp?.initDataUnsafe?.user?.id;
        if (tgId) {
          const { data, error } = await supabase.functions.invoke("tg-auth", {
            body: { initData: `user=%7B%22id%22%3A${tgId}%7D` },
          });
          if (!error && data?.access_token) {
            await supabase.auth.setSession({
              access_token: data.access_token,
              refresh_token: data.refresh_token ?? "",
            });
            token = data.access_token;
            setAccessToken(token);
          }
        }
      }

      // 登录成功后立即加载用户数据（直接用 fetch + JWT，最可靠）
      if (token) {
        const baseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
        const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
        const headers = {
          "apikey": anonKey ?? "",
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
        };

        // 加载用户余额
        let dbg = `token=${token.slice(0,10)}... `;
        try {
          const userRes = await fetch(
            `${baseUrl}/rest/v1/users?select=balance,roi&limit=1`,
            { headers }
          );
          const userData = await userRes.json();
          dbg += `userHTTP=${userRes.status} rows=${Array.isArray(userData) ? userData.length : 'N/A'} `;
          if (Array.isArray(userData) && userData.length > 0) {
            setBalance(parseFloat(String(userData[0].balance)));
            setRoi(parseFloat(String(userData[0].roi)));
            dbg += `bal=${userData[0].balance} `;
          }
        } catch (e) {
          dbg += `userERR=${e} `;
        }

        // 加载 open trades
        try {
          const tradeRes = await fetch(
            `${baseUrl}/rest/v1/trades?select=*&status=eq.open&limit=1`,
            { headers }
          );
          const trades = await tradeRes.json();
          dbg += `tradeHTTP=${tradeRes.status} rows=${Array.isArray(trades) ? trades.length : 'N/A'}`;
          if (Array.isArray(trades) && trades.length > 0) {
            setOpenTrade(trades[0] as Trade);
          }
        } catch (e) {
          dbg += `tradeERR=${e}`;
        }
        setDebugInfo(dbg);
      }

      // Haptic feedback on load
      if (webapp) {
        webapp.HapticFeedback?.impactOccurred("medium");
      }

      // 处理 referral
      const startParam: string | undefined =
        window.Telegram?.WebApp?.initDataUnsafe?.start_param;
      if (startParam && startParam.startsWith("ref_")) {
        supabase.functions
          .invoke("register-referral", { body: { referral_code: startParam } })
          .catch(() => {});
      }
    }

    init();
  }, []);

  // --- Real-time price via Binance WebSocket ---
  // Subscribes to the trade stream for the selected symbol.
  // Updates arrive ~100ms apart (every trade on Binance), but we
  // throttle React state updates to avoid excessive re-renders.
  const lastPriceUpdateRef = useRef<number>(0);

  useEffect(() => {
    const binanceSymbol = SYMBOL_TO_BINANCE[symbol];

    // Reset sparkline on symbol change
    setPriceHistory([]);

    const unsubscribe = subscribeBinancePrice(binanceSymbol, (newPrice) => {
      // Throttle: update state at most every 500ms to avoid jank
      const now = Date.now();
      if (now - lastPriceUpdateRef.current < 500) return;
      lastPriceUpdateRef.current = now;

      setPrice(newPrice);

      // Push into sparkline history (fixed-length ring buffer)
      setPriceHistory((prev) => {
        const next = [...prev, newPrice];
        return next.length > SPARKLINE_MAX_POINTS
          ? next.slice(next.length - SPARKLINE_MAX_POINTS)
          : next;
      });
    });

    return unsubscribe;
  }, [symbol, SPARKLINE_MAX_POINTS]);

  // --- Compute floating PnL for open trade ---
  useEffect(() => {
    if (!openTrade || !price) {
      setFloatingPnl(0);
      return;
    }
    const entry = openTrade.entry_price;
    const qty = openTrade.quantity;
    if (openTrade.direction === "long") {
      setFloatingPnl(qty * (price - entry));
    } else {
      setFloatingPnl(qty * (entry - price));
    }
  }, [openTrade, price]);

  // User data is now loaded inside init() after auth completes

  // --- Execute trade ---
  async function handleOpenTrade() {
    if (!price || loading) return;
    const marginNum = parseFloat(margin);
    if (isNaN(marginNum) || marginNum < 10) {
      setError("Minimum margin is 10 USDT");
      return;
    }
    if (marginNum > balance) {
      setError("Insufficient balance");
      return;
    }

    setLoading(true);
    setError("");
    try {
      const res = await supabase.functions.invoke("execute-trade", {
        body: { symbol, direction, leverage, margin: marginNum },
        headers: { Authorization: `Bearer ${accessToken}` },
      });

      if (res.error) {
        setError(res.error.message || "Trade failed");
        return;
      }

      const trade = res.data?.data as Trade;
      setOpenTrade(trade);
      setBalance((b) => b - marginNum);

      // Haptic success
      const webapp = window.Telegram?.WebApp;
      webapp?.HapticFeedback?.notificationOccurred("success");
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }

  // --- Close trade ---
  async function handleCloseTrade() {
    if (!openTrade || loading) return;

    setLoading(true);
    setError("");
    try {
      const res = await supabase.functions.invoke("close-trade", {
        body: { trade_id: openTrade.id },
        headers: { Authorization: `Bearer ${accessToken}` },
      });

      if (res.error) {
        setError(res.error.message || "Close failed");
        return;
      }

      const result = res.data?.data;
      const settlement = result?.settlement ?? 0;
      setBalance((b) => b + settlement);
      setRoi(result?.roi ?? roi);
      const closedTrade = { ...openTrade, realised_pnl: result?.realised_pnl ?? floatingPnl };
      setLastClosedTrade(closedTrade);
      setOpenTrade(null);
      setFloatingPnl(0);

      // Auto-show battle report poster after closing
      setShowPoster(true);

      const webapp = window.Telegram?.WebApp;
      webapp?.HapticFeedback?.notificationOccurred(floatingPnl >= 0 ? "success" : "warning");
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }

  // --- Add margin to open trade ---
  async function handleAddMargin() {
    if (!openTrade || addMarginLoading) return;
    const amount = parseFloat(addMarginAmount);
    if (isNaN(amount) || amount < 10) {
      setError("Minimum additional margin is 10 USDT");
      return;
    }
    if (amount > balance) {
      setError("Insufficient balance");
      return;
    }
    setAddMarginLoading(true);
    setError("");
    try {
      const res = await supabase.functions.invoke("add-margin", {
        body: { trade_id: openTrade.id, amount },
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (res.error) {
        setError(res.error.message || "Failed to add margin");
        return;
      }
      const updatedTrade = res.data?.data;
      if (updatedTrade) {
        setOpenTrade(updatedTrade as Trade);
        setBalance((b) => b - amount);
      }
      setShowAddMargin(false);
      setAddMarginAmount("");
      window.Telegram?.WebApp?.HapticFeedback?.notificationOccurred("success");
    } catch {
      setError("Network error. Try again.");
    } finally {
      setAddMarginLoading(false);
    }
  }

  // --- Format helpers ---
  const fmtPrice = (p: number) =>
    p >= 1000 ? p.toLocaleString("en-US", { maximumFractionDigits: 2 }) : p.toFixed(4);
  const fmtPnl = (p: number) => (p >= 0 ? `+${p.toFixed(2)}` : p.toFixed(2));
  const fmtPercent = (r: number) => (r >= 0 ? `+${(r * 100).toFixed(2)}%` : `${(r * 100).toFixed(2)}%`);

  const isLong = direction === "long";

  // Liquidation proximity warning
  const liqProximity = openTrade && price
    ? Math.abs(price - openTrade.liquidation_price) / price
    : 1;
  const isNearLiq = liqProximity < 0.10;

  return (
    <main className="flex flex-col min-h-screen px-4 pt-4 safe-bottom">
      {/* ── Header ── */}
      <header className="flex items-center justify-between mb-4">
        <div>
          <h1 className="text-lg font-bold tracking-tight">
            <span className="text-neon-green text-glow-green">Alpha</span>
            <span className="text-zinc-500 text-sm ml-1">Arena</span>
          </h1>
          {tgUser && (
            <p className="text-zinc-500 text-xs mt-0.5">
              Welcome, {tgUser.first_name}
            </p>
          )}
        </div>
        <div className="flex items-center gap-2">
          <a
            href="/tournaments"
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            Tournaments
          </a>
          <a
            href="/leaderboard"
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            Leaderboard
          </a>
          <a
            href="/history"
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            History
          </a>
          <a
            href="/achievements"
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            Achievements
          </a>
          <a
            href="/referral"
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            Referral
          </a>
          <a
            href="/alerts"
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            Alerts
          </a>
        </div>
      </header>

      {/* ── OpenClaw Status Widget ── */}
      <OpenClawWidget />

      {/* ── Daily Streak Widget ── */}
      <StreakWidget />

      {/* ── Balance Card ── */}
      <div className="arena-card p-4 mb-4">
        <div className="flex justify-between items-baseline">
          <div>
            <p className="text-zinc-500 text-xs uppercase tracking-wider">Balance</p>
            <p className="text-2xl font-bold mt-1">${balance.toLocaleString("en-US", { maximumFractionDigits: 2 })}</p>
          </div>
          <div className="text-right">
            <p className="text-zinc-500 text-xs uppercase tracking-wider">ROI</p>
            <p className={`text-xl font-bold mt-1 ${roi >= 0 ? "text-neon-green text-glow-green" : "text-neon-orange text-glow-orange"}`}>
              {fmtPercent(roi)}
            </p>
          </div>
        </div>
      </div>

      {/* ── Price Display ── */}
      <div className="arena-card p-4 mb-4">
        <div className="flex items-center justify-between mb-3">
          {/* Symbol selector */}
          <div className="flex gap-2">
            {SYMBOLS.map((s) => (
              <button
                key={s}
                onClick={() => setSymbol(s)}
                className={`text-xs px-3 py-1.5 rounded-lg transition-all ${
                  symbol === s
                    ? "bg-neon-green/10 text-neon-green border border-neon-green/30"
                    : "text-zinc-500 border border-arena-border hover:border-zinc-600"
                }`}
              >
                {s.split("/")[0]}
              </button>
            ))}
          </div>
          <span className="text-zinc-600 text-xs">MARKET</span>
        </div>
        <p className="text-4xl font-bold tracking-tight animate-price-flash" key={price}>
          {price ? `$${fmtPrice(price)}` : "Loading..."}
        </p>

        {/* ── Live Sparkline ── */}
        {priceHistory.length >= 2 && (
          <div className="mt-3 -mx-1">
            <Sparkline data={priceHistory} height={48} />
          </div>
        )}

        {/* ── Entry / Liq reference when position is open ── */}
        {openTrade && openTrade.status === "open" && (
          <div className="flex justify-between items-center text-xs mt-2">
            <span className="text-zinc-600">Entry: ${fmtPrice(openTrade.entry_price)}</span>
            <span className="text-red-500/70">Liq: ${fmtPrice(openTrade.liquidation_price)}</span>
          </div>
        )}
      </div>

      {/* ── Open Position (if any) ── */}
      {openTrade && (
        <div className={`arena-card p-4 mb-4 border-l-4 ${
          openTrade.status === "liquidated"
            ? "border-l-neon-orange glow-orange"
            : floatingPnl >= 0
            ? "border-l-neon-green glow-green"
            : "border-l-neon-orange glow-orange"
        }`}>
          <div className="flex justify-between items-center mb-2">
            <div className="flex items-center gap-2">
              <span className={`text-xs font-bold px-2 py-0.5 rounded ${
                openTrade.status === "liquidated"
                  ? "bg-neon-orange/30 text-neon-orange"
                  : openTrade.direction === "long"
                  ? "bg-neon-green/20 text-neon-green"
                  : "bg-neon-orange/20 text-neon-orange"
              }`}>
                {openTrade.status === "liquidated"
                  ? "LIQUIDATED"
                  : `${openTrade.direction.toUpperCase()} ${openTrade.leverage}x`}
              </span>
              <span className="text-sm text-zinc-400">{openTrade.symbol}</span>
            </div>
            <span className="text-xs text-zinc-500">
              Entry: ${fmtPrice(openTrade.entry_price)}
            </span>
          </div>

          {/* Giant PnL — shows liquidation note when applicable */}
          {openTrade.status === "liquidated" ? (
            <div className="my-3">
              <p className="text-4xl font-bold text-neon-orange text-glow-orange">
                LIQUIDATED
              </p>
              <p className="text-xs text-zinc-500 mt-1">
                Position was closed at liq. price
              </p>
            </div>
          ) : (
            <p className={`text-5xl font-bold my-3 ${
              floatingPnl >= 0 ? "text-neon-green text-glow-green" : "text-neon-orange text-glow-orange"
            }`}>
              {fmtPnl(floatingPnl)} USDT
            </p>
          )}

          <div className="flex justify-between items-center text-xs text-zinc-500 mb-4">
            <span>Margin: ${openTrade.margin}</span>
            <span className={isNearLiq ? "text-red-500 font-bold animate-pulse" : "text-zinc-500"}>
              Liq: ${fmtPrice(openTrade.liquidation_price)}
            </span>
          </div>

          {isNearLiq && (
            <div className="mb-3 text-red-500 text-xs font-bold animate-pulse text-center">
              ⚠️ WARNING: Price is within {(liqProximity * 100).toFixed(1)}% of liquidation!
            </div>
          )}

          <div className="flex gap-2">
            <button
              onClick={handleCloseTrade}
              disabled={loading || openTrade.status === "liquidated"}
              className={`flex-1 py-3 rounded-xl font-bold text-sm transition-all active:scale-95 ${
                openTrade.status === "liquidated"
                  ? "bg-zinc-800 text-zinc-500 cursor-not-allowed"
                  : floatingPnl >= 0
                  ? "bg-neon-green text-arena-bg glow-green-intense hover:brightness-110"
                  : "bg-neon-orange text-arena-bg glow-orange-intense hover:brightness-110"
              } disabled:opacity-50`}
            >
              {loading
                ? "Closing..."
                : openTrade.status === "liquidated"
                ? "Position Liquidated"
                : `Close Position (${fmtPnl(floatingPnl)})`}
            </button>
            {/* Add margin button */}
            <button
              onClick={() => setShowAddMargin(!showAddMargin)}
              disabled={openTrade.status === "liquidated"}
              className="px-4 py-3 rounded-xl border border-arena-border text-zinc-400 hover:text-neon-green hover:border-neon-green transition-colors text-sm disabled:opacity-30"
              title="Add margin"
            >
              💰
            </button>
            {/* Generate battle report */}
            <button
              onClick={() => { setLastClosedTrade(openTrade); setShowPoster(true); }}
              className="px-4 py-3 rounded-xl border border-arena-border text-zinc-400 hover:text-neon-green hover:border-neon-green transition-colors text-sm"
              title="Generate battle report"
            >
              📸
            </button>
          </div>

          {/* Add margin inline form */}
          {showAddMargin && openTrade.status === "open" && (
            <div className="mt-3 flex gap-2">
              <input
                type="number"
                value={addMarginAmount}
                onChange={(e) => setAddMarginAmount(e.target.value)}
                placeholder="Amount (USDT)"
                min={10}
                className="flex-1 bg-arena-bg border border-arena-border rounded-xl px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-neon-green"
              />
              <button
                onClick={handleAddMargin}
                disabled={addMarginLoading}
                className="px-4 py-2 rounded-xl bg-neon-green text-arena-bg font-bold text-sm active:scale-95 disabled:opacity-50"
              >
                {addMarginLoading ? "..." : "Add"}
              </button>
            </div>
          )}
        </div>
      )}

      {/* ── Trade Controls (when no open position) ── */}
      {!openTrade && (
        <div className="arena-card p-4 mb-4">
          {/* Direction buttons */}
          <div className="grid grid-cols-2 gap-3 mb-5">
            <button
              onClick={() => setDirection("long")}
              className={`py-4 rounded-xl font-bold text-lg transition-all active:scale-95 ${
                isLong
                  ? "bg-neon-green text-arena-bg glow-green-intense"
                  : "border border-arena-border text-zinc-500 hover:border-neon-green hover:text-neon-green"
              }`}
            >
              LONG ↑
            </button>
            <button
              onClick={() => setDirection("short")}
              className={`py-4 rounded-xl font-bold text-lg transition-all active:scale-95 ${
                !isLong
                  ? "bg-neon-orange text-arena-bg glow-orange-intense"
                  : "border border-arena-border text-zinc-500 hover:border-neon-orange hover:text-neon-orange"
              }`}
            >
              SHORT ↓
            </button>
          </div>

          {/* Leverage slider */}
          <div className="mb-5">
            <div className="flex justify-between items-center mb-2">
              <span className="text-xs text-zinc-500 uppercase tracking-wider">Leverage</span>
              <span className={`text-lg font-bold ${isLong ? "text-neon-green" : "text-neon-orange"}`}>
                {leverage}x
              </span>
            </div>
            <input
              type="range"
              min={1}
              max={100}
              step={1}
              value={leverage}
              onChange={(e) => setLeverage(parseInt(e.target.value))}
              className="w-full"
            />
            <div className="flex justify-between text-xs text-zinc-600 mt-1">
              <span>1x</span>
              <span>25x</span>
              <span>50x</span>
              <span>100x</span>
            </div>
          </div>

          {/* Margin input */}
          <div className="mb-5">
            <label className="text-xs text-zinc-500 uppercase tracking-wider block mb-2">
              Margin (USDT)
            </label>
            <div className="relative">
              <input
                type="number"
                value={margin}
                onChange={(e) => setMargin(e.target.value)}
                min={10}
                max={balance}
                placeholder="100"
                className="w-full bg-arena-bg border border-arena-border rounded-xl px-4 py-3 text-white text-lg font-mono focus:outline-none focus:border-neon-green transition-colors"
              />
              <button
                onClick={() => setMargin(String(Math.floor(balance)))}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-zinc-500 hover:text-neon-green transition-colors"
              >
                MAX
              </button>
            </div>
          </div>

          {/* Execute button */}
          <button
            onClick={handleOpenTrade}
            disabled={loading || !price}
            className={`w-full py-4 rounded-xl font-bold text-lg transition-all active:scale-95 disabled:opacity-50 ${
              isLong
                ? "bg-neon-green text-arena-bg glow-green-intense hover:brightness-110"
                : "bg-neon-orange text-arena-bg glow-orange-intense hover:brightness-110"
            }`}
          >
            {loading
              ? "Executing..."
              : `${direction.toUpperCase()} ${symbol.split("/")[0]} @ ${price ? "$" + fmtPrice(price) : "..."}`}
          </button>
        </div>
      )}

      {/* Error message */}
      {error && (
        <div className="arena-card border-neon-orange/30 p-3 mb-4 text-neon-orange text-sm text-center">
          {error}
        </div>
      )}

      {/* ── Battle Report Poster (hidden until triggered) ── */}
      {showPoster && lastClosedTrade && price && (
        <CyberPoster
          trade={lastClosedTrade}
          pnl={lastClosedTrade.realised_pnl ?? floatingPnl}
          currentPrice={price}
          username={tgUser?.first_name ?? "Anon"}
          roi={roi}
          onClose={() => setShowPoster(false)}
        />
      )}
    </main>
  );
}
