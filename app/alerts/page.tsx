"use client";

// ============================================================
// Price Alerts Page — Set and manage price alerts for BTC/ETH.
// Calls manage-price-alerts Edge Function (POST / DELETE).
// ============================================================

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import type { PriceAlert } from "@/lib/types";

// ── Constants ─────────────────────────────────────────────────

const SYMBOLS = ["BTC/USDT", "ETH/USDT"] as const;
type AlertSymbol = (typeof SYMBOLS)[number];

const MAX_ACTIVE_ALERTS = 5;

// ── Helpers ───────────────────────────────────────────────────

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function fmtPrice(p: number): string {
  return p >= 1000
    ? p.toLocaleString("en-US", { maximumFractionDigits: 2 })
    : p.toFixed(4);
}

// ── Sub-components ────────────────────────────────────────────

function AlertRow({
  alert,
  onDelete,
  deleting,
}: {
  alert: PriceAlert;
  onDelete: (id: string) => void;
  deleting: boolean;
}) {
  const isAbove = alert.direction === "above";
  const isTriggered = alert.triggered_at !== null;

  return (
    <div
      className={`flex items-center justify-between py-3 border-b border-arena-border last:border-0 ${
        isTriggered ? "opacity-50" : ""
      }`}
    >
      <div className="min-w-0">
        <div className="flex items-center gap-2 mb-0.5">
          <span className="text-xs font-bold text-zinc-300">
            {alert.symbol.split("/")[0]}
          </span>
          <span
            className={`text-xs font-bold px-1.5 py-0.5 rounded ${
              isAbove
                ? "bg-neon-green/10 text-neon-green"
                : "bg-neon-orange/10 text-neon-orange"
            }`}
          >
            {isAbove ? "↑ Above" : "↓ Below"}
          </span>
          <span className="text-sm font-bold text-white tabular-nums">
            ${fmtPrice(alert.target_price)}
          </span>
        </div>
        <p className="text-xs text-zinc-600">
          {isTriggered
            ? `Triggered ${fmtDate(alert.triggered_at!)}`
            : `Set ${fmtDate(alert.created_at)}`}
        </p>
      </div>

      {!isTriggered && (
        <button
          onClick={() => onDelete(alert.id)}
          disabled={deleting}
          className="ml-3 flex-shrink-0 text-xs text-zinc-600 hover:text-neon-orange border border-arena-border hover:border-neon-orange/50 rounded-lg px-2.5 py-1.5 transition-all active:scale-95 disabled:opacity-50"
        >
          {deleting ? "..." : "Delete"}
        </button>
      )}
    </div>
  );
}

function NewAlertForm({
  onCreated,
}: {
  onCreated: (alert: PriceAlert) => void;
}) {
  const [symbol, setSymbol] = useState<AlertSymbol>("BTC/USDT");
  const [direction, setDirection] = useState<"above" | "below">("above");
  const [targetPrice, setTargetPrice] = useState<string>("");
  const [submitting, setSubmitting] = useState(false);
  const [formError, setFormError] = useState<string>("");

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setFormError("");

    const price = parseFloat(targetPrice);
    if (isNaN(price) || price <= 0) {
      setFormError("Please enter a valid target price.");
      return;
    }

    setSubmitting(true);
    try {
      const res = await supabase.functions.invoke("manage-price-alerts", {
        body: { symbol, direction, target_price: price },
        method: "POST",
      } as Parameters<typeof supabase.functions.invoke>[1]);

      if (res.error) {
        setFormError(res.error.message || "Failed to create alert.");
      } else {
        const newAlert = (res.data?.data ?? res.data) as PriceAlert;
        onCreated(newAlert);
        setTargetPrice("");
      }
    } catch {
      setFormError("Network error. Please try again.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="arena-card p-4 mb-4">
      <p className="text-xs text-zinc-500 uppercase tracking-wider mb-4">
        New Alert
      </p>

      {/* Symbol selector */}
      <div className="mb-4">
        <p className="text-xs text-zinc-500 mb-2">Asset</p>
        <div className="flex gap-2">
          {SYMBOLS.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => setSymbol(s)}
              className={`flex-1 py-2.5 rounded-xl text-sm font-bold transition-all active:scale-95 ${
                symbol === s
                  ? "bg-neon-green/10 text-neon-green border border-neon-green/30"
                  : "border border-arena-border text-zinc-500 hover:border-zinc-600"
              }`}
            >
              {s.split("/")[0]}
            </button>
          ))}
        </div>
      </div>

      {/* Direction toggle */}
      <div className="mb-4">
        <p className="text-xs text-zinc-500 mb-2">Direction</p>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => setDirection("above")}
            className={`flex-1 py-2.5 rounded-xl text-sm font-bold transition-all active:scale-95 ${
              direction === "above"
                ? "bg-neon-green text-arena-bg glow-green-intense"
                : "border border-arena-border text-zinc-500 hover:border-neon-green hover:text-neon-green"
            }`}
          >
            ↑ Above
          </button>
          <button
            type="button"
            onClick={() => setDirection("below")}
            className={`flex-1 py-2.5 rounded-xl text-sm font-bold transition-all active:scale-95 ${
              direction === "below"
                ? "bg-neon-orange text-arena-bg glow-orange-intense"
                : "border border-arena-border text-zinc-500 hover:border-neon-orange hover:text-neon-orange"
            }`}
          >
            ↓ Below
          </button>
        </div>
      </div>

      {/* Target price */}
      <div className="mb-4">
        <label className="text-xs text-zinc-500 block mb-2">
          Target Price (USDT)
        </label>
        <input
          type="number"
          value={targetPrice}
          onChange={(e) => setTargetPrice(e.target.value)}
          min={0}
          step="any"
          placeholder={symbol === "BTC/USDT" ? "e.g. 70000" : "e.g. 3500"}
          className="w-full bg-arena-bg border border-arena-border rounded-xl px-4 py-3 text-white text-base font-mono focus:outline-none focus:border-neon-green transition-colors"
          required
        />
      </div>

      {formError && (
        <p className="text-neon-orange text-xs mb-3">{formError}</p>
      )}

      <button
        type="submit"
        disabled={submitting}
        className="w-full py-3.5 rounded-xl font-bold text-sm bg-neon-green text-arena-bg glow-green-intense hover:brightness-110 transition-all active:scale-95 disabled:opacity-50"
      >
        {submitting ? "Creating..." : "Set Alert"}
      </button>
    </form>
  );
}

// ── Page ──────────────────────────────────────────────────────

export default function AlertsPage() {
  const [alerts, setAlerts] = useState<PriceAlert[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>("");
  const [deletingId, setDeletingId] = useState<string | null>(null);

  const fetchAlerts = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const res = await supabase.functions.invoke("manage-price-alerts", {
        method: "GET",
      } as Parameters<typeof supabase.functions.invoke>[1]);
      if (res.error) {
        setError(res.error.message || "Failed to load alerts.");
      } else {
        const raw = res.data?.data ?? res.data;
        const data = Array.isArray(raw) ? raw : (raw?.alerts ?? []);
        setAlerts(data as PriceAlert[]);
      }
    } catch {
      setError("Network error. Please try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchAlerts();
  }, [fetchAlerts]);

  async function handleDelete(id: string) {
    setDeletingId(id);
    try {
      const res = await supabase.functions.invoke("manage-price-alerts", {
        body: { alert_id: id },
        method: "DELETE",
      } as Parameters<typeof supabase.functions.invoke>[1]);
      if (!res.error) {
        setAlerts((prev) => prev.filter((a) => a.id !== id));
      } else {
        setError(res.error.message || "Failed to delete alert.");
      }
    } catch {
      setError("Network error. Please try again.");
    } finally {
      setDeletingId(null);
    }
  }

  function handleAlertCreated(newAlert: PriceAlert) {
    setAlerts((prev) => [newAlert, ...prev]);
  }

  const activeAlerts = alerts.filter(
    (a) => a.is_active && a.triggered_at === null
  );
  const triggeredAlerts = alerts.filter((a) => a.triggered_at !== null);
  const canAddMore = activeAlerts.length < MAX_ACTIVE_ALERTS;

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
            <span className="text-neon-green text-glow-green">Price</span>
            <span className="text-white ml-1.5">Alerts</span>
          </h1>
          <p className="text-zinc-500 text-xs mt-0.5">
            Get notified when prices hit your targets.
          </p>
        </div>
      </header>

      {/* ── Loading ── */}
      {loading && (
        <div className="arena-card p-8 flex items-center justify-center mb-4">
          <span className="text-zinc-500 text-sm animate-pulse">
            Loading alerts...
          </span>
        </div>
      )}

      {/* ── Error ── */}
      {!loading && error && (
        <div className="arena-card border-neon-orange/30 p-4 mb-4 text-center">
          <p className="text-neon-orange text-sm mb-3">{error}</p>
          <button
            onClick={fetchAlerts}
            className="text-xs text-zinc-400 border border-arena-border rounded-lg px-3 py-1.5 hover:border-neon-green hover:text-neon-green transition-colors"
          >
            Retry
          </button>
        </div>
      )}

      {/* ── Content ── */}
      {!loading && (
        <>
          {/* Quota bar */}
          <div className="flex items-center justify-between mb-3">
            <p className="text-xs text-zinc-500 uppercase tracking-wider">
              Active Alerts
            </p>
            <span
              className={`text-xs font-bold tabular-nums ${
                activeAlerts.length >= MAX_ACTIVE_ALERTS
                  ? "text-neon-orange"
                  : "text-zinc-400"
              }`}
            >
              {activeAlerts.length} / {MAX_ACTIVE_ALERTS}
            </span>
          </div>

          {/* Active alerts list */}
          <div className="arena-card p-4 mb-4">
            {activeAlerts.length === 0 ? (
              <div className="py-8 text-center">
                <p className="text-3xl mb-3">🔔</p>
                <p className="text-zinc-400 text-sm">No alerts yet.</p>
                <p className="text-zinc-600 text-xs mt-1">
                  Set your first price alert below.
                </p>
              </div>
            ) : (
              activeAlerts.map((alert) => (
                <AlertRow
                  key={alert.id}
                  alert={alert}
                  onDelete={handleDelete}
                  deleting={deletingId === alert.id}
                />
              ))
            )}
          </div>

          {/* Capacity warning */}
          {activeAlerts.length >= MAX_ACTIVE_ALERTS && (
            <div className="arena-card border-neon-orange/20 px-4 py-3 mb-4">
              <p className="text-neon-orange text-xs text-center">
                Maximum {MAX_ACTIVE_ALERTS} active alerts reached. Delete one to
                add a new alert.
              </p>
            </div>
          )}

          {/* New alert form — shown only when under the cap */}
          {canAddMore && <NewAlertForm onCreated={handleAlertCreated} />}

          {/* Triggered alerts */}
          {triggeredAlerts.length > 0 && (
            <>
              <p className="text-xs text-zinc-500 uppercase tracking-wider mb-3 mt-2">
                Triggered Alerts
              </p>
              <div className="arena-card p-4 mb-4">
                {triggeredAlerts.map((alert) => (
                  <AlertRow
                    key={alert.id}
                    alert={alert}
                    onDelete={handleDelete}
                    deleting={deletingId === alert.id}
                  />
                ))}
              </div>
            </>
          )}
        </>
      )}
    </main>
  );
}
