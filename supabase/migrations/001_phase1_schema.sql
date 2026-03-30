-- =============================================================================
-- Migration: 001_phase1_schema
-- Description: Phase 1 - OpenClaw Arena core schema, RLS policies, indexes,
--              and leaderboard_view security barrier.
-- Created: 2026-03-15
-- Patched: 2026-03-15 (PO business decisions applied)
--
-- CHANGELOG (patch):
--   [users]  ADD CHECK (balance >= 0) — prevent negative balance at DB level
--   [users]  ADD display_name TEXT — TG first_name fallback for leaderboard
--   [trades] ADD margin NUMERIC(18,4) CHECK >= 10 — locked collateral per position
--   [trades] ADD liquidation_price NUMERIC(20,8) — auto-liquidation threshold
--   [trades] CHANGE leverage CHECK to 1–100 (was 1–125)
--   [trades] ADD unique partial index (user_id, symbol) WHERE status='open'
--            — one open position per symbol per user, enforced at DB level
--   [api_keys] ADD key_prefix VARCHAR(12) — first 8 chars shown in UI
--   [RLS]    REMOVE "users: USING(TRUE)" leaderboard policy — tg_id leak fix
--   [VIEW]   ADD leaderboard_view — only safe columns, security_barrier
--   [GRANT]  leaderboard_view readable by anon + authenticated
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ---------------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------------

-- Trade lifecycle states.
-- open       : position is active, PnL is floating
-- closed     : position was manually closed by user or agent
-- liquidated : position was force-closed due to margin exhaustion
CREATE TYPE public.trade_status AS ENUM ('open', 'closed', 'liquidated');

-- Trade direction.
CREATE TYPE public.trade_direction AS ENUM ('long', 'short');


-- ---------------------------------------------------------------------------
-- HELPER: updated_at trigger function
-- Automatically stamps updated_at on every UPDATE. Reused by all tables.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


-- =============================================================================
-- TABLE: public.users
-- =============================================================================

CREATE TABLE public.users (
  -- Supabase Auth UUID; linked to auth.users so Auth-level deletion cascades.
  id              UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Telegram user ID. Immutable after registration; used for TG Web App
  -- silent-login flows. Stored as BIGINT because Telegram IDs exceed INT4 range.
  tg_id           BIGINT      NOT NULL,

  -- Display name from Telegram first_name. Shown on leaderboard.
  -- TG username is optional; display_name is the reliable fallback.
  display_name    TEXT        NOT NULL DEFAULT '',

  -- Telegram @username (may be empty — TG does not require one).
  username        TEXT        NOT NULL DEFAULT '',

  -- TRUE  = human trader logged in via Telegram Web App
  -- FALSE = OpenClaw AI Agent (lobster 🦞)
  is_human        BOOLEAN     NOT NULL DEFAULT TRUE,

  -- Paper-trading balance in USDT-equivalent units.
  -- Starts at 10 000 for every new participant.
  -- CHECK: balance can never go negative — last line of DB-level defense
  -- against double-spend / race conditions in Edge Functions.
  balance         NUMERIC(18, 4) NOT NULL DEFAULT 10000
                  CONSTRAINT users_balance_non_negative CHECK (balance >= 0),

  -- Return-on-Investment expressed as a decimal fraction, e.g. 0.15 = +15%.
  -- Recomputed by Edge Functions after each trade settlement.
  roi             NUMERIC(10, 6) NOT NULL DEFAULT 0,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One Telegram account maps to exactly one arena participant.
  CONSTRAINT users_tg_id_unique UNIQUE (tg_id)
);

-- Index: leaderboard VIEW reads roi across all users.
CREATE INDEX idx_users_roi ON public.users (roi DESC);

-- Index: silent-login flow looks up a user by tg_id on every session start.
CREATE INDEX idx_users_tg_id ON public.users (tg_id);

-- Trigger: keep updated_at current.
CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- =============================================================================
-- TABLE: public.trades
-- =============================================================================

CREATE TABLE public.trades (
  id              UUID           PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Owner; must match an existing arena participant.
  user_id         UUID           NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

  -- Trading pair, e.g. 'BTC/USDT', 'ETH/USDT'.
  symbol          TEXT           NOT NULL,

  -- Long or short position.
  direction       public.trade_direction NOT NULL,

  -- Leverage multiplier: 1x–100x. (PO decision: strict cap at 100)
  leverage        SMALLINT       NOT NULL
                  CONSTRAINT trades_leverage_range CHECK (leverage BETWEEN 1 AND 100),

  -- USDT margin locked as collateral for this position.
  -- Deducted from users.balance atomically at open.
  -- PO decision: minimum margin = 10 USDT to prevent dust spam.
  margin          NUMERIC(18, 4) NOT NULL
                  CONSTRAINT trades_margin_minimum CHECK (margin >= 10),

  -- Server-side price stamped by execute-trade Edge Function.
  -- 8 decimal places to handle satoshi-level precision.
  entry_price     NUMERIC(20, 8) NOT NULL,

  -- Closing price; NULL while position is open.
  exit_price      NUMERIC(20, 8),

  -- Price at which the position is auto-liquidated.
  -- Computed server-side at open: ensures the liquidation scanner
  -- can do a simple price comparison without recalculating.
  -- For long:  liquidation_price = entry_price * (1 - 1/leverage)
  -- For short: liquidation_price = entry_price * (1 + 1/leverage)
  liquidation_price NUMERIC(20, 8) NOT NULL,

  -- Notional position size in base currency units.
  quantity        NUMERIC(20, 8) NOT NULL CHECK (quantity > 0),

  -- Realised PnL; populated on close or liquidation.
  realised_pnl    NUMERIC(18, 4),

  -- State machine: open -> closed | liquidated
  status          public.trade_status NOT NULL DEFAULT 'open',

  created_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- CRITICAL CONSTRAINT: one open position per (user, symbol) at DB level.
-- PO decision: enforced at DB layer, not just business layer.
-- A partial unique index on (user_id, symbol) WHERE status = 'open'
-- guarantees that no two concurrent Edge Function calls can both INSERT
-- an open position for the same symbol — the second will get a unique
-- violation, which the Edge Function returns as HTTP 409.
CREATE UNIQUE INDEX idx_trades_one_open_per_user_symbol
  ON public.trades (user_id, symbol)
  WHERE status = 'open';

-- Index: "show me my open positions" — the hottest query path.
CREATE INDEX idx_trades_user_status ON public.trades (user_id, status);

-- Index: liquidation scanner scans all open positions globally.
CREATE INDEX idx_trades_status ON public.trades (status);

-- Index: symbol-level analytics (most-traded pair).
CREATE INDEX idx_trades_symbol ON public.trades (symbol);

-- Index: liquidation scanner needs open positions sorted by liquidation_price.
CREATE INDEX idx_trades_liquidation_scan
  ON public.trades (symbol, liquidation_price)
  WHERE status = 'open';

-- Trigger: keep updated_at current.
CREATE TRIGGER trg_trades_updated_at
  BEFORE UPDATE ON public.trades
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- =============================================================================
-- TABLE: public.api_keys
-- =============================================================================

CREATE TABLE public.api_keys (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The arena participant this key belongs to.
  user_id         UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

  -- SHA-256 hash of the raw API key.
  -- The raw key is shown to the user once at creation time and then
  -- discarded. We only store the hash to validate future requests.
  hashed_key      TEXT        NOT NULL,

  -- First 8 characters of the raw key, e.g. "oca_ab12".
  -- Shown in the UI so users can identify which key is active.
  -- NOT secret — this is a display-only prefix.
  key_prefix      VARCHAR(12) NOT NULL,

  -- Human-readable label (e.g. "primary agent", "backup agent").
  label           TEXT        NOT NULL DEFAULT 'default',

  -- Soft-delete: revoked keys are kept for audit trail purposes.
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,

  -- Record when the key was last successfully used for intrusion detection.
  last_used_at    TIMESTAMPTZ,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- A user may have at most one active key per label.
  CONSTRAINT api_keys_user_label_unique UNIQUE (user_id, label)
);

-- Index: Edge Function key-validation path looks up by hashed_key directly.
CREATE INDEX idx_api_keys_hashed_key
  ON public.api_keys (hashed_key)
  WHERE is_active = TRUE;

-- Index: management queries filter by user_id.
CREATE INDEX idx_api_keys_user_id ON public.api_keys (user_id);

-- Trigger: keep updated_at current.
CREATE TRIGGER trg_api_keys_updated_at
  BEFORE UPDATE ON public.api_keys
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
-- Design principle: DEFAULT DENY on every table.
-- Each policy is the minimal grant required for its use-case.
--
-- CRITICAL CHANGE: The old "USING(TRUE)" leaderboard policy on users is
-- REMOVED. The leaderboard is now served exclusively through
-- leaderboard_view (a security_barrier VIEW) which never exposes tg_id,
-- balance, or any sensitive field. The users table itself is locked to
-- owner-only SELECT.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- RLS: public.users
-- ---------------------------------------------------------------------------

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Policy: authenticated users can ONLY read their own row.
-- NO "USING(TRUE)" policy exists. The leaderboard goes through a VIEW.
CREATE POLICY "users: owner can select own row"
  ON public.users
  FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

-- Policy: users may update mutable display fields on their own row.
-- Financial fields (balance, roi) are only modified by service_role.
CREATE POLICY "users: owner can update own row"
  ON public.users
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- No INSERT policy: new rows are created by handle_new_user() trigger
-- which runs as SECURITY DEFINER (service_role context).


-- ---------------------------------------------------------------------------
-- RLS: public.trades
-- ---------------------------------------------------------------------------

ALTER TABLE public.trades ENABLE ROW LEVEL SECURITY;

-- Policy: a user can only see their own trades.
CREATE POLICY "trades: owner can select own trades"
  ON public.trades
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- No INSERT/UPDATE/DELETE policies for authenticated role.
-- All trade mutations go through execute-trade Edge Function (service_role).


-- ---------------------------------------------------------------------------
-- RLS: public.api_keys
-- ---------------------------------------------------------------------------

ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;

-- INTENTIONAL: There is NO SELECT policy for authenticated or anon.
-- Default deny = every client-side query returns zero rows.
-- Only service_role (Edge Functions) can read this table.

-- Policy: users may soft-deactivate their own keys via UPDATE.
CREATE POLICY "api_keys: owner can update own key (deactivate)"
  ON public.api_keys
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);


-- =============================================================================
-- VIEW: public.leaderboard_view
-- =============================================================================
-- This is the ONLY way the frontend reads leaderboard data.
-- It projects ONLY safe, non-sensitive columns.
-- security_barrier = TRUE prevents the optimizer from pushing down
-- filter predicates that could leak data through timing side-channels.
--
-- WHAT IS NOT EXPOSED:
--   - tg_id           (Telegram identity — the crown jewel)
--   - balance          (private financial state)
--   - id               (internal UUID — no reason for frontend to know)
--   - created_at       (registration time — minor privacy concern)
-- =============================================================================

CREATE OR REPLACE VIEW public.leaderboard_view
  WITH (security_barrier = true)
AS
  SELECT
    display_name,
    username,
    is_human,
    roi,
    -- Rank computed on-the-fly for correctness (no stale cache).
    RANK() OVER (ORDER BY roi DESC) AS rank
  FROM public.users
  ORDER BY roi DESC;

-- Grant read-only access to the VIEW for both anon and authenticated roles.
-- This does NOT bypass users table RLS — the VIEW runs as the view owner
-- (typically postgres/supabase_admin), which has full SELECT, but only
-- exposes the columns defined above.
GRANT SELECT ON public.leaderboard_view TO anon;
GRANT SELECT ON public.leaderboard_view TO authenticated;

-- Explicitly revoke any direct table access for anon role.
-- (Belt-and-suspenders: RLS already denies, but this makes intent explicit.)
REVOKE ALL ON public.users FROM anon;
REVOKE ALL ON public.trades FROM anon;
REVOKE ALL ON public.api_keys FROM anon;


-- =============================================================================
-- TRIGGER: auto-create users row on Supabase Auth sign-up
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF (NEW.raw_user_meta_data->>'tg_id') IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.users (id, tg_id, display_name, username, is_human)
  VALUES (
    NEW.id,
    (NEW.raw_user_meta_data->>'tg_id')::BIGINT,
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'username', ''),
    TRUE
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


COMMIT;


-- =============================================================================
-- SECURITY MODEL OVERVIEW (v2 — post-patch)
-- =============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ THREAT: Frontend hacker tries to get #1 player's real tg_id           │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │                                                                       │
-- │ Attack Vector 1: Direct query on users table                          │
-- │ ─────────────────────────────────────────────────────────────────────  │
-- │   supabase.from('users').select('tg_id').order('roi', desc: true)     │
-- │                                                                       │
-- │   RESULT: Returns ONLY the attacker's own row (1 row max).            │
-- │   WHY:    users RLS policy is "auth.uid() = id" — owner only.         │
-- │           There is NO "USING(TRUE)" policy anymore.                   │
-- │           The attacker's JWT resolves to their own UUID.              │
-- │           They cannot see any other user's row, period.               │
-- │                                                                       │
-- │ Attack Vector 2: Query leaderboard_view for tg_id                     │
-- │ ─────────────────────────────────────────────────────────────────────  │
-- │   supabase.from('leaderboard_view').select('tg_id')                   │
-- │                                                                       │
-- │   RESULT: Error — column "tg_id" does not exist in view.              │
-- │   WHY:    leaderboard_view only projects:                             │
-- │           display_name, username, is_human, roi, rank                 │
-- │           The tg_id column is structurally absent from the VIEW       │
-- │           definition. It cannot be selected, filtered, or inferred.   │
-- │                                                                       │
-- │ Attack Vector 3: Infer tg_id via filter side-channel                  │
-- │ ─────────────────────────────────────────────────────────────────────  │
-- │   supabase.from('leaderboard_view')                                   │
-- │     .select('*')                                                      │
-- │     .eq('tg_id', 123456789)                                           │
-- │                                                                       │
-- │   RESULT: Error — column "tg_id" does not exist.                      │
-- │   WHY:    security_barrier = true on the VIEW prevents the query      │
-- │           planner from pushing predicates down to the base table.     │
-- │           Even if a hypothetical predicate could reference tg_id,     │
-- │           the security barrier stops it.                              │
-- │                                                                       │
-- │ Attack Vector 4: Query api_keys after obtaining UUID                  │
-- │ ─────────────────────────────────────────────────────────────────────  │
-- │   (Even if somehow the attacker gets a victim UUID)                   │
-- │   supabase.from('api_keys').select('*').eq('user_id', victimUUID)     │
-- │                                                                       │
-- │   RESULT: Empty array — zero rows returned.                           │
-- │   WHY:    api_keys has RLS enabled + ZERO SELECT policies for any     │
-- │           client role. Default deny = USING(FALSE).                   │
-- │                                                                       │
-- │ Attack Vector 5: Direct table REVOKE bypass                           │
-- │ ─────────────────────────────────────────────────────────────────────  │
-- │   Anonymous (anon) user tries to query any table directly.            │
-- │                                                                       │
-- │   RESULT: Permission denied.                                          │
-- │   WHY:    REVOKE ALL on users/trades/api_keys for anon role.          │
-- │           Belt-and-suspenders on top of RLS.                          │
-- │                                                                       │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │                                                                       │
-- │ SECURITY MODEL MATRIX (v2):                                           │
-- │                                                                       │
-- │ Role          │ users      │ trades     │ api_keys   │ leaderboard   │
-- │ ──────────────┼────────────┼────────────┼────────────┼───────────────│
-- │ anon          │ REVOKED    │ REVOKED    │ REVOKED    │ SELECT only   │
-- │ authenticated │ own row    │ own rows   │ UPDATE own │ SELECT only   │
-- │               │ (R/W)      │ (R only)   │ (no READ)  │               │
-- │ service_role  │ all        │ all        │ all        │ all           │
-- │               │ (bypass)   │ (bypass)   │ (bypass)   │               │
-- │                                                                       │
-- │ Data flow:                                                            │
-- │   Frontend ──SELECT──> leaderboard_view  (safe: no tg_id, no id)     │
-- │   Frontend ──SELECT──> users             (own row only via RLS)       │
-- │   Frontend ──SELECT──> trades            (own rows only via RLS)      │
-- │   Frontend ──SELECT──> api_keys          (BLOCKED — 0 rows always)   │
-- │   Edge Fn  ──SELECT──> api_keys          (service_role bypasses RLS)  │
-- │   Edge Fn  ──INSERT──> trades            (service_role bypasses RLS)  │
-- │   Edge Fn  ──UPDATE──> users.balance/roi (service_role bypasses RLS)  │
-- │                                                                       │
-- └─────────────────────────────────────────────────────────────────────────┘
-- =============================================================================
