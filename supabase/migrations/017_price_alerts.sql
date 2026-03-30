-- ============================================================
-- Migration : 017_price_alerts
-- Description: Implements the user price-alert system.
--              Creates public.price_alerts to store per-user
--              threshold alerts for crypto/asset symbols,
--              with RLS restricting all access to the owning
--              user. Alerting logic (price polling, trigger
--              detection, Telegram notification dispatch) runs
--              in a separate Edge Function / cron job that uses
--              the service role and is not defined here.
--
-- Security model
--   - price_alerts is readable, insertable, and deletable by
--     the owning authenticated user via RLS.
--   - UPDATE is intentionally not granted to authenticated
--     users: to change an alert the user must delete and
--     re-insert. This keeps the trigger/fired-at state
--     unambiguous and prevents client-side tampering with
--     triggered_at.
--   - The alert-scanner Edge Function runs as service_role and
--     is therefore not restricted by RLS. It performs the
--     triggered_at UPDATE and is_active = FALSE flip.
--   - anon has zero access.
--   - The "max 5 active alerts per user" business rule is
--     enforced in the Edge Function (INSERT path), not in the
--     database. A CHECK constraint would require a correlated
--     subquery, which cannot be indexed efficiently and would
--     serialize all alert inserts for a given user. The Edge
--     Function enforces the cap with a simple COUNT query
--     inside the same request handler.
--
-- Index strategy
--   idx_price_alerts_active   — supports user-facing "my alerts"
--                               list queries filtered to active only.
--   idx_price_alerts_scan     — supports the scanner's bulk sweep:
--                               for each (symbol, direction) bucket,
--                               find all active alerts whose
--                               target_price satisfies the current
--                               market price threshold.
--
-- Lock ordering (canonical — see docs/LOCK_ORDERING.md)
--   price_alerts is assigned canonical position 4 (after trades).
--   No existing RPC locks price_alerts, so no existing RPCs are
--   affected. Any future RPC that locks both users and price_alerts
--   must acquire the users lock first (position 2) and the
--   price_alerts lock second (position 4).
--
--   Updated canonical order:
--     1. tournaments
--     2. users
--     3. trades
--     4. price_alerts   ← new
--
-- Depends on : 001_initial_schema (public.users)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Main table: public.price_alerts
-- ------------------------------------------------------------

CREATE TABLE public.price_alerts (
  id            UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID           NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  symbol        TEXT           NOT NULL,
  direction     TEXT           NOT NULL CHECK (direction IN ('above', 'below')),
  target_price  NUMERIC(20, 8) NOT NULL CHECK (target_price > 0),
  is_active     BOOLEAN        NOT NULL DEFAULT TRUE,
  triggered_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.price_alerts IS
  'Per-user price threshold alerts. Each row represents one alert: '
  'notify when symbol trades above/below target_price. '
  'is_active flips to FALSE and triggered_at is stamped by the '
  'alert-scanner Edge Function once the threshold is crossed. '
  'Maximum 5 active alerts per user enforced in the Edge Function.';

COMMENT ON COLUMN public.price_alerts.symbol IS
  'Asset identifier as used by the price-feed API (e.g. BTCUSDT, ETHUSDT). '
  'Case-sensitive; must match the feed''s canonical ticker format.';

COMMENT ON COLUMN public.price_alerts.direction IS
  '"above": fire when market price rises to or above target_price. '
  '"below": fire when market price falls to or below target_price.';

COMMENT ON COLUMN public.price_alerts.target_price IS
  'Threshold price in the quote currency (typically USDT). '
  'Must be strictly positive.';

COMMENT ON COLUMN public.price_alerts.is_active IS
  'TRUE while the alert is waiting to be triggered. '
  'Set to FALSE by the scanner when the threshold is crossed, '
  'or by the user (via DELETE + re-insert) to cancel.';

COMMENT ON COLUMN public.price_alerts.triggered_at IS
  'UTC timestamp of when the scanner first detected the threshold breach. '
  'NULL while is_active = TRUE. Set atomically with is_active = FALSE '
  'by the scanner service role.';

-- ------------------------------------------------------------
-- Section 2 — Indexes
-- ------------------------------------------------------------

-- User-facing "show my active alerts" query.
-- Partial: inactive (triggered) alerts are excluded from the index
-- to keep it compact; historical alerts can be queried with a full
-- table scan if needed (expected low cardinality per user).
CREATE INDEX idx_price_alerts_active
  ON public.price_alerts (user_id, symbol)
  WHERE is_active = TRUE;

-- Scanner sweep: for a given (symbol, direction), find all active
-- alerts whose target_price would be satisfied by the current price.
-- The scanner queries:
--   WHERE symbol = $1 AND direction = 'above' AND target_price <= $current
--   WHERE symbol = $1 AND direction = 'below' AND target_price >= $current
-- Including target_price in the index supports both range predicates.
CREATE INDEX idx_price_alerts_scan
  ON public.price_alerts (symbol, direction, target_price)
  WHERE is_active = TRUE;

-- ------------------------------------------------------------
-- Section 3 — Row Level Security on public.price_alerts
-- ------------------------------------------------------------

ALTER TABLE public.price_alerts ENABLE ROW LEVEL SECURITY;

-- Owner may read their own alerts (active and historical).
CREATE POLICY "price_alerts: owner can select"
  ON public.price_alerts
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Owner may create new alerts.
-- The Edge Function enforces the 5-alert cap before calling INSERT.
CREATE POLICY "price_alerts: owner can insert"
  ON public.price_alerts
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Owner may delete (cancel) their own alerts.
-- Deletion is the canonical way to cancel: it keeps the schema
-- simple and avoids a client-writable is_active flag that could
-- be misused to re-activate triggered alerts.
CREATE POLICY "price_alerts: owner can delete"
  ON public.price_alerts
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- No UPDATE policy for authenticated users: the is_active / triggered_at
-- transition is exclusively the scanner's responsibility (service_role,
-- which bypasses RLS). Preventing client UPDATE eliminates any risk of
-- a user resetting triggered_at to re-arm a fired alert.

REVOKE ALL ON public.price_alerts FROM anon;

-- ------------------------------------------------------------
-- Lock ordering documentation update
-- (canonical position 4 assigned to price_alerts)
--
-- RPC Lock Acquisition Table — additions to docs/LOCK_ORDERING.md:
--
-- No new RPCs are introduced in this migration. The table entry
-- below is for future RPCs that lock price_alerts.
--
-- | RPC                  | Migration | Lock 1         | Lock 2           |
-- |----------------------|-----------|----------------|------------------|
-- | (future alert RPC)   | TBD       | users FOR UPDATE (pos 2) | price_alerts FOR UPDATE (pos 4) |
--
-- Deadlock analysis — price_alerts vs. existing RPCs:
--   No existing RPC (execute_trade_txn, close_trade_txn,
--   liquidate_trade_txn, join_tournament_txn, settle_tournament_txn,
--   award_daily_reward_txn, award_referral_bonus_txn) acquires a
--   FOR UPDATE lock on price_alerts. Therefore adding this table
--   to the canonical ordering at position 4 introduces no new
--   deadlock risk with any existing RPC.
-- ------------------------------------------------------------

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DROP TABLE IF EXISTS public.price_alerts;
-- -- Note: remove position-4 entry from docs/LOCK_ORDERING.md manually.
-- ============================================================
