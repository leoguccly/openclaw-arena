-- =============================================================================
-- Migration: 005_tournaments
-- Description: Tournament schema — tables, indexes, RLS, leaderboard view,
--              and a nullable tournament_id column backfilled onto trades.
-- Created: 2026-03-29
--
-- New objects:
--   ENUM   public.tournament_status
--   TABLE  public.tournaments
--   TABLE  public.tournament_participants
--   COLUMN public.trades.tournament_id  (nullable FK; NULL = non-tournament trade)
--   VIEW   public.tournament_leaderboard_view
--
-- Security model:
--   tournaments:
--     - anon / authenticated : SELECT only (public competition info)
--     - service_role         : full access
--   tournament_participants:
--     - anon / authenticated : SELECT only (public rankings)
--     - service_role         : full access
--   tournament_leaderboard_view:
--     - anon / authenticated : SELECT only
--     - No user_id or balance is exposed; entry_balance is shown because
--       it is agreed-to public context for the competition.
--   trades.tournament_id:
--     - No additional RLS change needed; existing trades policies apply.
-- =============================================================================

BEGIN;

-- =============================================================================
-- ENUM: public.tournament_status
-- =============================================================================
-- State machine for a tournament lifecycle:
--
--   upcoming  → active  : cron job transitions at start_at
--   active    → settling: settle_tournament_txn sets this as a guard flag
--   settling  → completed: settle_tournament_txn sets this after ranking
--
-- The 'settling' state prevents new trades from being tagged to the tournament
-- and signals the scanner that no further state changes should occur mid-run.
-- =============================================================================

CREATE TYPE public.tournament_status AS ENUM (
  'upcoming',    -- registered but not yet started
  'active',      -- accepting trades; participants can join
  'settling',    -- Edge Function is computing final ranks; transitional
  'completed'    -- all ranks assigned; read-only historical record
);


-- =============================================================================
-- TABLE: public.tournaments
-- =============================================================================

CREATE TABLE public.tournaments (
  id               UUID                      PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Human-readable competition name, e.g. "Weekend Scalp-Off #3".
  name             TEXT                      NOT NULL,

  -- Optional longer description shown in the tournament detail view.
  description      TEXT                      NOT NULL DEFAULT '',

  -- Wall-clock window for the competition. Enforced by CHECK; also used by
  -- the cron job to transition status automatically.
  start_at         TIMESTAMPTZ               NOT NULL,
  end_at           TIMESTAMPTZ               NOT NULL,

  -- Current lifecycle state.
  status           public.tournament_status  NOT NULL DEFAULT 'upcoming',

  -- Hard cap on participant count. join_tournament_txn enforces this atomically.
  max_participants INT                       NOT NULL DEFAULT 100,

  -- Minimum balance (USDT) required to enter. Prevents zero-balance accounts
  -- from padding participant counts. join_tournament_txn enforces this.
  min_balance      NUMERIC(18, 4)            NOT NULL DEFAULT 100,

  created_at       TIMESTAMPTZ               NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ               NOT NULL DEFAULT NOW(),

  -- Structural guard: end time must come after start time.
  CONSTRAINT tournaments_time_valid CHECK (end_at > start_at)
);

-- Index: cron job and status-filter queries.
CREATE INDEX idx_tournaments_status
  ON public.tournaments (status);

-- Index: time-window queries ("which tournaments are active right now?").
CREATE INDEX idx_tournaments_dates
  ON public.tournaments (start_at, end_at);

-- Trigger: keep updated_at current.
CREATE TRIGGER trg_tournaments_updated_at
  BEFORE UPDATE ON public.tournaments
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ---------------------------------------------------------------------------
-- RLS: public.tournaments
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournaments ENABLE ROW LEVEL SECURITY;

-- Policy: tournaments metadata is public knowledge — anyone may read.
CREATE POLICY "tournaments: anyone can select"
  ON public.tournaments
  FOR SELECT
  TO anon, authenticated
  USING (TRUE);

-- No INSERT / UPDATE / DELETE policies for any client role.
-- Tournament lifecycle is managed exclusively by Edge Functions (service_role).


-- =============================================================================
-- TABLE: public.tournament_participants
-- =============================================================================
-- One row per (tournament, user) entry. Populated by join_tournament_txn.
-- final_roi and rank are NULL until settle_tournament_txn runs.
-- =============================================================================

CREATE TABLE public.tournament_participants (
  id              UUID           PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The competition this entry belongs to.
  tournament_id   UUID           NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,

  -- The arena participant who entered.
  user_id         UUID           NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

  -- Snapshot of the user's balance at the moment they joined.
  -- Used by settle_tournament_txn to compute per-tournament ROI independently
  -- of the user's global balance (which includes gains/losses from other events).
  entry_balance   NUMERIC(18, 4) NOT NULL,

  -- ROI = (current_balance - entry_balance) / entry_balance.
  -- NULL until settlement; populated atomically by settle_tournament_txn.
  final_roi       NUMERIC(10, 6),

  -- Rank by final_roi DESC, ties broken by joined_at ASC (earlier = better).
  -- NULL until settlement.
  rank            INT,

  -- When the participant confirmed their entry.
  joined_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

  -- Prevents double-entry: one active entry per user per tournament.
  CONSTRAINT tp_unique_entry UNIQUE (tournament_id, user_id)
);

-- Index: "show me all participants for tournament X" — tournament detail page.
CREATE INDEX idx_tp_tournament
  ON public.tournament_participants (tournament_id);

-- Index: "which tournaments has user Y entered?" — profile / history page.
CREATE INDEX idx_tp_user
  ON public.tournament_participants (user_id);

-- Index: settlement and leaderboard ranking within a tournament.
CREATE INDEX idx_tp_tournament_roi
  ON public.tournament_participants (tournament_id, final_roi DESC NULLS LAST);


-- ---------------------------------------------------------------------------
-- RLS: public.tournament_participants
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournament_participants ENABLE ROW LEVEL SECURITY;

-- Policy: participant lists are public — this is a competition, not a secret.
CREATE POLICY "tournament_participants: anyone can select"
  ON public.tournament_participants
  FOR SELECT
  TO anon, authenticated
  USING (TRUE);

-- No INSERT / UPDATE / DELETE policies for any client role.
-- All mutations are performed by join_tournament_txn and settle_tournament_txn
-- (both SECURITY DEFINER, service_role context).


-- =============================================================================
-- ALTER: public.trades — add nullable tournament_id
-- =============================================================================
-- Trades opened during a tournament window are tagged with tournament_id so
-- settle_tournament_txn can force-close them via the Edge Function before
-- calling the settlement RPC.
--
-- NULL means the trade was opened outside any tournament context.
-- This is additive and non-breaking: existing trades remain NULL by default.
-- =============================================================================

ALTER TABLE public.trades
  ADD COLUMN tournament_id UUID REFERENCES public.tournaments(id);

-- Partial index: only non-NULL rows are indexed; keeps the index tight.
CREATE INDEX idx_trades_tournament
  ON public.trades (tournament_id)
  WHERE tournament_id IS NOT NULL;


-- =============================================================================
-- VIEW: public.tournament_leaderboard_view
-- =============================================================================
-- Serves the in-tournament and post-tournament rankings.
-- security_barrier = TRUE prevents predicate push-down that could leak
-- internal user state through the base tables.
--
-- WHAT IS NOT EXPOSED:
--   - user_id    (internal UUID — not needed by the frontend for display)
--   - balance    (current private balance unrelated to the tournament)
--
-- entry_balance IS exposed — it is the agreed public starting point for
-- each participant's per-tournament ROI and is not sensitive.
-- =============================================================================

CREATE OR REPLACE VIEW public.tournament_leaderboard_view
  WITH (security_barrier = true)
AS
  SELECT
    tp.tournament_id,
    u.display_name,
    u.username,
    u.is_human,
    tp.entry_balance,
    tp.final_roi,
    tp.rank,
    tp.joined_at
  FROM public.tournament_participants tp
  JOIN public.users u ON u.id = tp.user_id;

-- Grant read-only access to both client roles.
GRANT SELECT ON public.tournament_leaderboard_view TO anon;
GRANT SELECT ON public.tournament_leaderboard_view TO authenticated;


COMMIT;


-- =============================================================================
-- SECURITY MODEL ADDENDUM (005)
-- =============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ Object                        │ anon       │ authenticated │ svc_role  │
-- ├───────────────────────────────┼────────────┼───────────────┼───────────┤
-- │ tournaments                   │ SELECT     │ SELECT        │ all       │
-- │ tournament_participants        │ SELECT     │ SELECT        │ all       │
-- │ tournament_leaderboard_view   │ SELECT     │ SELECT        │ all       │
-- │ trades.tournament_id          │ (via RLS)  │ own rows only │ all       │
-- ├───────────────────────────────┴────────────┴───────────────┴───────────┤
-- │ Why public SELECT on tournament_participants?                            │
-- │   Leaderboards are inherently public in a competitive context. Exposing  │
-- │   display_name, username, and ROI rankings is the product intent.        │
-- │   user_id is withheld via the view projection to avoid UUID harvesting.  │
-- └─────────────────────────────────────────────────────────────────────────┘
-- =============================================================================
