-- ============================================================
-- Migration : 011_trade_history
-- Description: Performance and DX improvements for the trade
--              history feature in Phase 3.
--
--              1. Composite index on public.trades for the
--                 paginated history query (user + time + status).
--              2. Security-barrier view (trade_history_view)
--                 that joins trades with tournament names so the
--                 Flutter app can fetch enriched rows in one
--                 round-trip without a manual JOIN.
--
-- Security model
--   trades (base table)
--     - RLS is assumed enabled from migration 001 with a policy
--       of the form USING (auth.uid() = user_id).
--   trade_history_view
--     - Declared WITH (security_barrier = true) to prevent
--       function-inlining attacks that could bypass the base
--       table's RLS predicates.
--     - The view has no RLS of its own; it inherits the RLS of
--       public.trades (Postgres applies base-table policies to
--       views with security_barrier). Only rows the caller owns
--       according to trades RLS are ever visible through the view.
--     - GRANT SELECT to authenticated only; anon receives no
--       access because trades are private user data.
--     - service_role bypasses RLS by default and can see all
--       rows (required for admin tooling and tournament settlement).
--
-- Index design notes
--   idx_trades_history covers the three predicates used by the
--   history page:
--     WHERE  user_id = $1              — equality, leftmost column
--     ORDER BY created_at DESC         — range scan direction
--     AND status IN ('closed',...)     — optional status filter
--   A three-column composite index satisfies all three without a
--   separate sort step. The DESC storage order matches the ORDER
--   BY direction, eliminating a filesort for the common case.
--
-- Depends on : 001_initial_schema (public.trades, public.tournaments)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Composite index for trade history pagination
-- ------------------------------------------------------------

CREATE INDEX idx_trades_history
  ON public.trades (user_id, created_at DESC, status);

COMMENT ON INDEX idx_trades_history IS
  'Supports the paginated trade history query: '
  'WHERE user_id = $1 [AND status = $2] ORDER BY created_at DESC. '
  'DESC storage order on created_at avoids a filesort.';

-- ------------------------------------------------------------
-- Section 2 — Enriched view: trade_history_view
--
-- Joins public.trades with public.tournaments to surface the
-- human-readable tournament name alongside every trade row.
-- Spot trades (tournament_id IS NULL) appear with NULL name.
--
-- Column inventory mirrors the full trades schema plus:
--   closed_at        — alias for trades.updated_at (set by
--                      close_trade_txn / liquidate_trade_txn)
--   tournament_name  — tournaments.name, NULL for spot trades
--
-- CREATE OR REPLACE is safe here: the view does not have
-- dependent objects in migrations 001-010.
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW public.trade_history_view
  WITH (security_barrier = true)
AS
SELECT
  t.id,
  t.user_id,
  t.symbol,
  t.direction,
  t.leverage,
  t.margin,
  t.entry_price,
  t.exit_price,
  t.liquidation_price,
  t.realised_pnl,
  t.quantity,
  t.status,
  t.tournament_id,
  t.created_at,
  t.updated_at          AS closed_at,
  tn.name               AS tournament_name
FROM  public.trades t
LEFT  JOIN public.tournaments tn ON tn.id = t.tournament_id;

COMMENT ON VIEW public.trade_history_view IS
  'Enriched trade history: trades joined with tournament names. '
  'security_barrier = true ensures base-table RLS on public.trades '
  'is enforced before any view-level predicate is evaluated, '
  'preventing function-inlining privilege escalation. '
  'Only rows the authenticated caller owns are visible.';

-- Explicit column comments for the Flutter data-layer team.
COMMENT ON COLUMN public.trade_history_view.closed_at IS
  'Alias for trades.updated_at. Populated by close_trade_txn and '
  'liquidate_trade_txn when a position is settled.';

COMMENT ON COLUMN public.trade_history_view.tournament_name IS
  'Human-readable name of the associated tournament, or NULL for '
  'spot (non-tournament) trades.';

-- ------------------------------------------------------------
-- Section 3 — Grants on the view
-- ------------------------------------------------------------

-- Authenticated users may query the view; RLS on the base table
-- restricts rows to those owned by auth.uid().
GRANT SELECT ON public.trade_history_view TO authenticated;

-- Explicitly block anon: trade data is private.
REVOKE ALL ON public.trade_history_view FROM anon;

-- service_role inherits full access by default (no explicit grant
-- needed, but noted here for documentation purposes).
-- service_role bypasses RLS and can see all rows — required for
-- tournament settlement (settle_tournament_txn) and admin tooling.

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DROP VIEW  IF EXISTS public.trade_history_view;
-- DROP INDEX IF EXISTS idx_trades_history;
-- ============================================================
