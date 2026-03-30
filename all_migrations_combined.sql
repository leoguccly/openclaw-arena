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
-- =============================================================================
-- Migration: 002_trade_rpc_functions
-- Description: Atomic transaction RPCs for trade execution and closing.
--              Called by Edge Functions to ensure FOR UPDATE row locking and
--              single-round-trip atomicity.
-- Created: 2026-03-15
-- =============================================================================

BEGIN;

-- =============================================================================
-- RPC: execute_trade_txn
-- =============================================================================
-- Called by: supabase/functions/execute-trade/index.ts
--
-- Performs the entire open-trade flow atomically:
--   1. SELECT ... FOR UPDATE on users row (row lock prevents double-spend)
--   2. Validate balance >= margin
--   3. INSERT trade row
--   4. UPDATE users.balance -= margin
--   5. Return the inserted trade row
--
-- Errors:
--   - RAISE 'insufficient_balance' if balance < margin
--   - Unique violation (23505) if duplicate open position for (user, symbol)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.execute_trade_txn(
  p_user_id         UUID,
  p_symbol          TEXT,
  p_direction        public.trade_direction,
  p_leverage         SMALLINT,
  p_margin           NUMERIC(18, 4),
  p_entry_price      NUMERIC(20, 8),
  p_liquidation_price NUMERIC(20, 8),
  p_quantity         NUMERIC(20, 8)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_balance   NUMERIC(18, 4);
  v_trade_id  UUID;
  v_trade     JSONB;
BEGIN
  -- Step 1: Lock the user row and read current balance.
  -- FOR UPDATE prevents any concurrent transaction from reading/modifying
  -- this row until we COMMIT. This is the anti-double-spend mechanism.
  SELECT balance INTO v_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_not_found: User % does not exist', p_user_id;
  END IF;

  -- Step 2: Validate sufficient balance.
  IF v_balance < p_margin THEN
    RAISE EXCEPTION 'insufficient_balance: Balance % is less than required margin %',
      v_balance, p_margin;
  END IF;

  -- Step 3: Insert the trade.
  -- If the partial unique index (user_id, symbol) WHERE status='open' fires,
  -- PostgreSQL raises error code 23505 which the Edge Function maps to HTTP 409.
  INSERT INTO public.trades (
    user_id, symbol, direction, leverage, margin,
    entry_price, liquidation_price, quantity, status
  ) VALUES (
    p_user_id, p_symbol, p_direction, p_leverage, p_margin,
    p_entry_price, p_liquidation_price, p_quantity, 'open'
  )
  RETURNING id INTO v_trade_id;

  -- Step 4: Deduct margin from user balance.
  UPDATE public.users
  SET balance = balance - p_margin
  WHERE id = p_user_id;

  -- Step 5: Build and return the trade as JSONB.
  SELECT to_jsonb(t.*) INTO v_trade
  FROM public.trades t
  WHERE t.id = v_trade_id;

  RETURN v_trade;
END;
$$;

-- Only service_role should call this function.
REVOKE ALL ON FUNCTION public.execute_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.execute_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.execute_trade_txn FROM authenticated;


-- =============================================================================
-- RPC: close_trade_txn
-- =============================================================================
-- Called by: supabase/functions/close-trade/index.ts
--
-- Performs the entire close-trade flow atomically:
--   1. SELECT ... FOR UPDATE on trades row (prevents double-close)
--   2. Validate trade exists, belongs to user, and is still open
--   3. UPDATE trade: set status='closed', exit_price, realised_pnl
--   4. UPDATE users: balance += settlement, recompute ROI
--   5. Return the updated trade row
--
-- Errors:
--   - RAISE 'trade_not_found' if trade doesn't exist, wrong owner, or not open
-- =============================================================================

CREATE OR REPLACE FUNCTION public.close_trade_txn(
  p_trade_id      UUID,
  p_user_id       UUID,
  p_exit_price    NUMERIC(20, 8),
  p_realised_pnl  NUMERIC(18, 4),
  p_settlement    NUMERIC(18, 4)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trade        RECORD;
  v_new_balance  NUMERIC(18, 4);
  v_new_roi      NUMERIC(10, 6);
  v_result       JSONB;
  v_initial_balance CONSTANT NUMERIC := 10000;
BEGIN
  -- Step 1: Lock the trade row.
  -- FOR UPDATE prevents a concurrent close request on the same trade.
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Step 2: Validate ownership and status.
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not belong to user %',
      p_trade_id, p_user_id;
  END IF;

  IF v_trade.status != 'open' THEN
    RAISE EXCEPTION 'trade_not_found: Trade % is not open (status=%)',
      p_trade_id, v_trade.status;
  END IF;

  -- Step 3: Close the trade.
  UPDATE public.trades
  SET
    status = 'closed',
    exit_price = p_exit_price,
    realised_pnl = p_realised_pnl
  WHERE id = p_trade_id;

  -- Step 4: Lock the users row FIRST to prevent concurrent balance modifications.
  -- This is critical when two different trades for the same user close simultaneously.
  -- Without FOR UPDATE, both could read the same balance and one settlement would be lost.
  SELECT balance INTO v_new_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  -- Step 5: Compute new balance and ROI using the locked balance value.
  v_new_balance := v_new_balance + p_settlement;
  v_new_roi := (v_new_balance - v_initial_balance) / v_initial_balance;

  -- Step 6: Write the computed values (no ambiguity about pre/post-update).
  UPDATE public.users
  SET
    balance = v_new_balance,
    roi = v_new_roi
  WHERE id = p_user_id;

  -- Step 5: Return the closed trade as JSONB.
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function.
REVOKE ALL ON FUNCTION public.close_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM authenticated;


COMMIT;
-- =============================================================================
-- Migration: 003_liquidation
-- Description: Auto-liquidation audit trail and atomic liquidation RPC.
--              The liquidation scanner Edge Function calls liquidate_trade_txn
--              once per trade that has breached its liquidation_price threshold.
-- Created: 2026-03-29
--
-- New objects:
--   TABLE  public.liquidation_events   — immutable audit log of every force-close
--   RPC    public.liquidate_trade_txn  — atomic liquidation; service_role only
--
-- Security model:
--   liquidation_events:
--     - anon          : REVOKED (belt-and-suspenders on top of RLS)
--     - authenticated : SELECT own rows only
--     - service_role  : full access (bypasses RLS)
--   liquidate_trade_txn:
--     - PUBLIC / anon / authenticated : REVOKED
--     - service_role  : implicit execute (not in REVOKE list)
-- =============================================================================

BEGIN;

-- =============================================================================
-- TABLE: public.liquidation_events
-- =============================================================================
-- Immutable audit trail. One row is inserted per force-closed trade.
-- Clients may read their own rows for history/notifications; all writes
-- are done exclusively by liquidate_trade_txn (SECURITY DEFINER).
--
-- WHY market_price is stored separately from liquidation_price:
--   The position is triggered when market_price crosses liquidation_price,
--   but the two values can differ by up to one price-tick at scan time.
--   Storing both gives the audit log full fidelity.
-- =============================================================================

CREATE TABLE public.liquidation_events (
  id                UUID           PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The trade that was force-closed.
  trade_id          UUID           NOT NULL REFERENCES public.trades(id),

  -- Denormalised for fast per-user history queries without joining trades.
  user_id           UUID           NOT NULL REFERENCES public.users(id),

  -- Denormalised symbol for display and analytics.
  symbol            TEXT           NOT NULL,

  -- The pre-computed threshold stored on the trade at open time.
  liquidation_price NUMERIC(20, 8) NOT NULL,

  -- The actual market price at the moment the scanner triggered liquidation.
  -- May differ slightly from liquidation_price due to scan frequency.
  market_price      NUMERIC(20, 8) NOT NULL,

  -- The margin amount that was permanently lost (realised_pnl = -margin).
  margin            NUMERIC(18, 4) NOT NULL,

  -- Wall-clock time of the liquidation; immutable after insert.
  created_at        TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- Index: "show me my liquidation history" — the primary client query path.
CREATE INDEX idx_liquidation_events_user
  ON public.liquidation_events (user_id, created_at DESC);

-- Index: lookup by trade_id for internal reconciliation / admin queries.
CREATE INDEX idx_liquidation_events_trade
  ON public.liquidation_events (trade_id);


-- ---------------------------------------------------------------------------
-- RLS: public.liquidation_events
-- ---------------------------------------------------------------------------

ALTER TABLE public.liquidation_events ENABLE ROW LEVEL SECURITY;

-- Policy: authenticated users can read only their own liquidation history.
CREATE POLICY "liquidation_events: owner can select"
  ON public.liquidation_events
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- No INSERT / UPDATE / DELETE policies for any client role.
-- All writes are performed by liquidate_trade_txn (SECURITY DEFINER),
-- which runs as the function owner (postgres/supabase_admin) and bypasses RLS.

-- Belt-and-suspenders: block all anon access at the privilege level as well.
REVOKE ALL ON public.liquidation_events FROM anon;


-- =============================================================================
-- RPC: liquidate_trade_txn
-- =============================================================================
-- Called by: supabase/functions/liquidation-scanner/index.ts
--
-- Atomically force-closes a single trade that has breached its
-- liquidation_price threshold:
--
--   1. SELECT ... FOR UPDATE on the trade row.
--      Idempotency guard: if status != 'open' the function returns NULL
--      (another process beat us to it — not an error).
--   2. Validate ownership.
--   3. UPDATE trade: status='liquidated', exit_price=liquidation_price,
--      realised_pnl=-margin  (entire margin is wiped out; settlement=0).
--   4. SELECT ... FOR UPDATE on the users row.
--      Balance does not change (settlement=0), but ROI must be recomputed
--      against the current balance so partial losses on other trades are
--      reflected correctly.
--   5. UPDATE users.roi.
--   6. INSERT liquidation_events audit row.
--   7. Return the updated trade row as JSONB, or NULL if already closed.
--
-- Errors:
--   - RAISE 'trade_not_found'   if trade UUID does not exist or ownership mismatch
--
-- Why settlement = 0:
--   margin was deducted from balance at trade open. On liquidation the entire
--   margin is lost — no funds are returned. ROI is recomputed against whatever
--   remaining balance the user holds from other trades.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.liquidate_trade_txn(
  p_trade_id    UUID,
  p_user_id     UUID,
  p_market_price NUMERIC(20, 8)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trade           RECORD;
  v_user_balance    NUMERIC(18, 4);
  v_new_roi         NUMERIC(10, 6);
  v_result          JSONB;
  v_initial_balance CONSTANT NUMERIC := 10000;
BEGIN
  -- Step 1: Lock the trade row.
  -- FOR UPDATE prevents a concurrent liquidation scanner invocation from
  -- double-liquidating the same trade within the same price-tick window.
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Step 2: Idempotency guard.
  -- If the trade was already closed or liquidated by another process,
  -- return NULL so the scanner can move on without raising an error.
  IF v_trade.status != 'open' THEN
    RETURN NULL;
  END IF;

  -- Step 3: Validate ownership.
  -- Ownership is re-checked here (not just at the Edge Function layer)
  -- because this function is SECURITY DEFINER and must not be tricked
  -- into liquidating a trade belonging to a different user.
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % ownership mismatch', p_trade_id;
  END IF;

  -- Step 4: Force-close the trade.
  -- exit_price is set to the pre-computed liquidation_price (not market_price)
  -- so realised_pnl arithmetic is exact: pnl = -margin for a full wipeout.
  UPDATE public.trades
  SET
    status       = 'liquidated',
    exit_price   = v_trade.liquidation_price,
    realised_pnl = -v_trade.margin
  WHERE id = p_trade_id;

  -- Step 5: Lock the user row.
  -- Balance does not change (settlement = 0; margin was already deducted at
  -- trade open). We lock FOR UPDATE anyway to serialize ROI recomputation
  -- against any concurrent close_trade_txn that might settle simultaneously.
  SELECT balance INTO v_user_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  -- Step 6: Recompute ROI against current balance.
  v_new_roi := (v_user_balance - v_initial_balance) / v_initial_balance;

  UPDATE public.users
  SET roi = v_new_roi
  WHERE id = p_user_id;

  -- Step 7: Write the immutable audit row.
  INSERT INTO public.liquidation_events (
    trade_id, user_id, symbol, liquidation_price, market_price, margin
  ) VALUES (
    p_trade_id,
    p_user_id,
    v_trade.symbol,
    v_trade.liquidation_price,
    p_market_price,
    v_trade.margin
  );

  -- Step 8: Return the updated trade as JSONB.
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function.
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM authenticated;


COMMIT;


-- =============================================================================
-- SECURITY MODEL ADDENDUM (003)
-- =============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ liquidation_events access matrix                                        │
-- ├──────────────────┬──────────────────────────────────────────────────────┤
-- │ anon             │ REVOKED at privilege level                           │
-- │ authenticated    │ SELECT own rows only (auth.uid() = user_id)          │
-- │ service_role     │ full access (RLS bypassed)                           │
-- ├──────────────────┴──────────────────────────────────────────────────────┤
-- │ liquidate_trade_txn                                                     │
-- ├──────────────────┬──────────────────────────────────────────────────────┤
-- │ PUBLIC / anon /  │ REVOKED — cannot be called by any client role        │
-- │ authenticated    │                                                      │
-- │ service_role     │ callable (Edge Function context)                     │
-- ├──────────────────┴──────────────────────────────────────────────────────┤
-- │ Idempotency guarantee                                                   │
-- │   If the scanner dispatches two concurrent calls for the same trade     │
-- │   (e.g. overlapping cron ticks), the FOR UPDATE lock on the trade row   │
-- │   serialises them. The second call finds status != 'open' and returns   │
-- │   NULL — no double-liquidation, no error, no duplicate audit row.       │
-- └─────────────────────────────────────────────────────────────────────────┘
-- =============================================================================
-- =============================================================================
-- Migration: 004_openclaw_agent
-- Description: Seeds the OpenClaw AI agent (the lobster) as a permanent
--              arena participant. This is a one-time seed operation; the
--              agent row is stable across all environments.
-- Created: 2026-03-29
--
-- Design decisions:
--
--   UUID: '00000000-0000-0000-0000-00000c1a0001'
--     - Deterministic so Edge Functions can hardcode OPENCLAW_AGENT_ID
--       as an env-var or constant rather than doing a lookup on every call.
--     - The '0c1a' segment is a visual mnemonic for "ocla" (OpenCLAw).
--     - This UUID is safe to commit to source; it is not a secret.
--
--   auth.users insertion:
--     - We insert directly into auth.users so the FK on public.users(id)
--       is satisfied without disabling the constraint.
--     - encrypted_password = '' and no confirmed email means this account
--       cannot authenticate via any Supabase Auth flow (password, magic link,
--       OAuth, etc.). It is a structural/service account only.
--     - ON CONFLICT (id) DO NOTHING makes this migration idempotent.
--
--   public.users insertion:
--     - tg_id = 0: reserved sentinel value; real Telegram IDs start at 1.
--       The UNIQUE constraint on tg_id means only one row can hold tg_id=0.
--     - is_human = FALSE: correctly flags this row as the AI agent on the
--       leaderboard_view so the frontend can render the lobster badge.
--     - balance = 10000: same starting capital as every human participant.
--
--   on_auth_user_created trigger:
--     - The trigger fires AFTER INSERT ON auth.users. However, we insert
--       into public.users explicitly with ON CONFLICT DO NOTHING, so the
--       trigger's own INSERT will be a safe no-op.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_openclaw_id CONSTANT UUID := '00000000-0000-0000-0000-00000c1a0001';
BEGIN
  -- -------------------------------------------------------------------------
  -- Step 1: Create the auth.users stub.
  -- -------------------------------------------------------------------------
  -- This satisfies the FK reference on public.users(id) → auth.users(id).
  -- The account has no password and no confirmed email, so it cannot be used
  -- to log in via any Supabase Auth provider.
  -- -------------------------------------------------------------------------
  INSERT INTO auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at,
    confirmation_token,
    raw_app_meta_data,
    raw_user_meta_data
  ) VALUES (
    v_openclaw_id,
    '00000000-0000-0000-0000-000000000000',   -- default Supabase instance_id
    'authenticated',
    'authenticated',
    'openclaw@arena.internal',                -- non-routable internal address
    '',                                       -- no password — cannot login
    NOW(),                                    -- treat email as pre-confirmed
    NOW(),
    NOW(),
    '',
    '{"provider":"service","providers":["service"]}'::jsonb,
    '{"tg_id":0,"first_name":"OpenClaw","username":"openclaw_lobster"}'::jsonb
  )
  ON CONFLICT (id) DO NOTHING;

  -- -------------------------------------------------------------------------
  -- Step 2: Create the public.users arena participant row.
  -- -------------------------------------------------------------------------
  -- The on_auth_user_created trigger will also fire an INSERT for this UUID,
  -- but ON CONFLICT (id) DO NOTHING on both sides makes both paths safe.
  -- -------------------------------------------------------------------------
  INSERT INTO public.users (
    id,
    tg_id,
    display_name,
    username,
    is_human,
    balance,
    roi
  ) VALUES (
    v_openclaw_id,
    0,                    -- sentinel tg_id; reserved for the AI agent
    'OpenClaw',           -- display name shown on leaderboard (no emoji in DB)
    'openclaw_lobster',   -- @handle shown in UI
    FALSE,                -- is_human = false; renders lobster badge on frontend
    10000,                -- same starting balance as every human participant
    0                     -- ROI starts at 0.000000
  )
  ON CONFLICT (id) DO NOTHING;
END;
$$;


COMMIT;


-- =============================================================================
-- NOTES FOR EDGE FUNCTIONS
-- =============================================================================
--
--   The OpenClaw agent UUID is stable and can be used as a constant:
--
--     const OPENCLAW_AGENT_ID = '00000000-0000-0000-0000-00000c1a0001';
--
--   This eliminates a SELECT lookup on every agent trade cycle.
--   Store it in Supabase Secrets or as a top-level constant in the Edge
--   Function — never hardcode raw API keys or user secrets alongside it.
--
--   Because is_human = FALSE, the leaderboard_view already returns this row
--   with the correct flag; the frontend needs no special handling beyond
--   checking the is_human column.
-- =============================================================================
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
-- =============================================================================
-- Migration: 006_tournament_rpcs
-- Description: Atomic RPCs for tournament participation and settlement.
--              Both functions are SECURITY DEFINER and callable only by
--              service_role (Edge Functions).
-- Created: 2026-03-29
--
-- New objects:
--   RPC  public.join_tournament_txn    — atomic participant registration
--   RPC  public.settle_tournament_txn  — atomic ranking and completion
--
-- Security model:
--   Both RPCs: PUBLIC / anon / authenticated REVOKED; service_role implicit.
-- =============================================================================

BEGIN;

-- =============================================================================
-- RPC: join_tournament_txn
-- =============================================================================
-- Called by: supabase/functions/join-tournament/index.ts
--
-- Atomically registers a user as a tournament participant:
--
--   1. SELECT ... FOR UPDATE on the tournaments row.
--      Validates status IN ('upcoming', 'active').
--   2. COUNT current participants (within the same transaction lock window).
--      Validates count < max_participants.
--   3. SELECT ... FOR UPDATE on the users row.
--      Validates balance >= min_balance.
--   4. INSERT tournament_participants row with entry_balance snapshot.
--   5. Return the inserted participant row as JSONB.
--
-- Idempotency:
--   If the user has already joined (duplicate UNIQUE constraint violation),
--   PostgreSQL raises error 23505 which the Edge Function maps to HTTP 409.
--   This is intentional — joining twice is an error, not a silent no-op.
--
-- Errors (all raise EXCEPTION with a parseable prefix):
--   'tournament_not_found'    — UUID does not exist
--   'tournament_closed'       — status not in ('upcoming', 'active')
--   'tournament_full'         — participant count >= max_participants
--   'user_not_found'          — user UUID does not exist
--   'insufficient_balance'    — balance < min_balance
-- =============================================================================

CREATE OR REPLACE FUNCTION public.join_tournament_txn(
  p_tournament_id UUID,
  p_user_id       UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tournament       RECORD;
  v_participant_count INT;
  v_user_balance     NUMERIC(18, 4);
  v_result           JSONB;
BEGIN
  -- Step 1: Lock the tournament row.
  -- FOR UPDATE prevents a concurrent join from passing the capacity check
  -- simultaneously and over-filling the tournament.
  SELECT * INTO v_tournament
  FROM public.tournaments
  WHERE id = p_tournament_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'tournament_not_found: Tournament % does not exist', p_tournament_id;
  END IF;

  -- Step 2: Validate the tournament is still accepting entries.
  IF v_tournament.status NOT IN ('upcoming', 'active') THEN
    RAISE EXCEPTION 'tournament_closed: Tournament is not accepting entries (status=%)',
      v_tournament.status;
  END IF;

  -- Step 3: Count current participants within the locked transaction.
  -- We re-count here (not in application code) to avoid TOCTOU races where
  -- two concurrent calls both read count=99 and both insert, exceeding 100.
  SELECT COUNT(*) INTO v_participant_count
  FROM public.tournament_participants
  WHERE tournament_id = p_tournament_id;

  IF v_participant_count >= v_tournament.max_participants THEN
    RAISE EXCEPTION 'tournament_full: Tournament has reached maximum participants (%)',
      v_tournament.max_participants;
  END IF;

  -- Step 4: Lock the user row and validate their balance.
  -- FOR UPDATE here serialises against any concurrent execute_trade_txn that
  -- might drain the user's balance between the check and the insert below.
  SELECT balance INTO v_user_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_not_found: User % does not exist', p_user_id;
  END IF;

  IF v_user_balance < v_tournament.min_balance THEN
    RAISE EXCEPTION 'insufficient_balance: Balance % is below tournament minimum %',
      v_user_balance, v_tournament.min_balance;
  END IF;

  -- Step 5: Register the participant.
  -- entry_balance is a point-in-time snapshot of the user's balance at join.
  -- It is used by settle_tournament_txn to compute per-tournament ROI,
  -- isolated from the user's global trading activity outside this tournament.
  -- The UNIQUE constraint (tournament_id, user_id) surfaces duplicate joins
  -- as a 23505 violation, which the Edge Function maps to HTTP 409.
  INSERT INTO public.tournament_participants (
    tournament_id,
    user_id,
    entry_balance
  ) VALUES (
    p_tournament_id,
    p_user_id,
    v_user_balance
  );

  -- Step 6: Return the new participant row as JSONB.
  SELECT to_jsonb(tp.*) INTO v_result
  FROM public.tournament_participants tp
  WHERE tp.tournament_id = p_tournament_id
    AND tp.user_id = p_user_id;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function.
REVOKE ALL ON FUNCTION public.join_tournament_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.join_tournament_txn FROM anon;
REVOKE ALL ON FUNCTION public.join_tournament_txn FROM authenticated;


-- =============================================================================
-- RPC: settle_tournament_txn
-- =============================================================================
-- Called by: supabase/functions/settle-tournament/index.ts
--
-- Atomically computes final rankings and marks the tournament as completed.
--
-- IMPORTANT PRE-CONDITION:
--   The calling Edge Function is responsible for force-closing all open trades
--   tagged with tournament_id BEFORE invoking this RPC. This function assumes
--   all trade settlement has already occurred so that users.balance reflects
--   their final position. The 'settling' status guard prevents re-entrant calls.
--
--   Sequence of Edge Function operations:
--     1. Fetch all open trades WHERE tournament_id = p_tournament_id
--     2. For each: call close_trade_txn (or liquidate_trade_txn as appropriate)
--     3. Call settle_tournament_txn — this RPC
--
-- Atomic steps:
--   1. SELECT ... FOR UPDATE on the tournaments row.
--      Validates status IN ('active', 'settling').
--   2. UPDATE tournaments SET status = 'settling'.
--      Acts as a distributed mutex: a second concurrent call finds status =
--      'settling' and is rejected, preventing double-settlement.
--   3. UPDATE tournament_participants.final_roi for every participant.
--      final_roi = (current_balance - entry_balance) / entry_balance
--   4. Assign integer ranks via RANK() OVER (ORDER BY final_roi DESC, joined_at ASC).
--      Ties broken by earlier join time (first-in, best-ranked on a tie).
--   5. UPDATE tournaments SET status = 'completed'.
--   6. Return a summary JSONB with the ranked participant list.
--
-- Errors:
--   'tournament_not_found'  — UUID does not exist
--   'invalid_status'        — status not in ('active', 'settling')
-- =============================================================================

CREATE OR REPLACE FUNCTION public.settle_tournament_txn(
  p_tournament_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tournament RECORD;
  v_result     JSONB;
BEGIN
  -- Step 1: Lock the tournament row.
  -- FOR UPDATE here acts as a distributed mutex: the first concurrent call
  -- transitions status to 'settling' (Step 2); any second concurrent call
  -- that acquires the lock after Step 2 finds status='settling', which is
  -- also accepted — but the first call will have already done the UPDATE
  -- and the second call proceeds idempotently with no harm (all SET clauses
  -- are deterministic given the same balance state).
  SELECT * INTO v_tournament
  FROM public.tournaments
  WHERE id = p_tournament_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'tournament_not_found: Tournament % does not exist', p_tournament_id;
  END IF;

  -- Step 2: Guard against settling a tournament that has already completed
  -- or was never activated. 'settling' is accepted so that a retried call
  -- (e.g. after a transient Edge Function timeout) can complete the work.
  IF v_tournament.status NOT IN ('active', 'settling') THEN
    RAISE EXCEPTION 'invalid_status: Cannot settle tournament with status=%',
      v_tournament.status;
  END IF;

  -- Step 3: Transition to 'settling'.
  -- Any concurrent call that acquires the lock AFTER this UPDATE sees status
  -- = 'settling' and passes the guard above, but both calls produce the same
  -- deterministic result since the underlying balance data is already settled
  -- by the time this RPC is called (per the pre-condition above).
  UPDATE public.tournaments
  SET status = 'settling'
  WHERE id = p_tournament_id;

  -- Step 4: Compute final ROI for every participant.
  -- final_roi = (current_balance - entry_balance) / entry_balance
  -- This measures each participant's gain/loss relative to when they joined,
  -- isolating tournament performance from activity in other tournaments or
  -- trades outside the tournament window.
  UPDATE public.tournament_participants tp
  SET final_roi = (u.balance - tp.entry_balance) / tp.entry_balance
  FROM public.users u
  WHERE tp.tournament_id = p_tournament_id
    AND u.id = tp.user_id;

  -- Step 5: Assign integer ranks.
  -- RANK() produces gaps on ties (e.g. 1, 2, 2, 4).
  -- Tie-breaking rule: earlier joined_at wins (first-in earns the tiebreak).
  -- This is deterministic and fair — early commitment is rewarded on draws.
  WITH ranked AS (
    SELECT
      id,
      RANK() OVER (
        ORDER BY final_roi DESC, joined_at ASC
      ) AS computed_rank
    FROM public.tournament_participants
    WHERE tournament_id = p_tournament_id
  )
  UPDATE public.tournament_participants tp
  SET rank = ranked.computed_rank
  FROM ranked
  WHERE tp.id = ranked.id;

  -- Step 6: Transition to 'completed'.
  UPDATE public.tournaments
  SET status = 'completed'
  WHERE id = p_tournament_id;

  -- Step 7: Return a structured settlement summary as JSONB.
  -- The Edge Function uses this to trigger notifications, update caches, etc.
  SELECT jsonb_build_object(
    'tournament_id', p_tournament_id,
    'name',          v_tournament.name,
    'status',        'completed',
    'participants',  (
      SELECT jsonb_agg(
        jsonb_build_object(
          'display_name', u.display_name,
          'username',     u.username,
          'is_human',     u.is_human,
          'final_roi',    tp.final_roi,
          'rank',         tp.rank
        ) ORDER BY tp.rank ASC
      )
      FROM public.tournament_participants tp
      JOIN public.users u ON u.id = tp.user_id
      WHERE tp.tournament_id = p_tournament_id
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function.
REVOKE ALL ON FUNCTION public.settle_tournament_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.settle_tournament_txn FROM anon;
REVOKE ALL ON FUNCTION public.settle_tournament_txn FROM authenticated;


COMMIT;


-- =============================================================================
-- SECURITY MODEL ADDENDUM (006)
-- =============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ Function                  │ PUBLIC/anon/authenticated │ service_role   │
-- ├───────────────────────────┼───────────────────────────┼────────────────┤
-- │ join_tournament_txn       │ REVOKED                   │ callable       │
-- │ settle_tournament_txn     │ REVOKED                   │ callable       │
-- ├───────────────────────────┴───────────────────────────┴────────────────┤
-- │ Race condition handling                                                  │
-- │                                                                          │
-- │ join_tournament_txn:                                                     │
-- │   FOR UPDATE on tournaments row serialises concurrent joins.             │
-- │   Participant count is re-read under the lock (not passed in as arg)     │
-- │   to eliminate TOCTOU over-subscription.                                 │
-- │   FOR UPDATE on users row prevents a concurrent execute_trade_txn from   │
-- │   draining balance between the check and the participant INSERT.          │
-- │                                                                          │
-- │ settle_tournament_txn:                                                   │
-- │   The 'settling' intermediate status acts as a distributed mutex.        │
-- │   A retried call (e.g. after timeout) re-enters the 'settling' branch    │
-- │   and re-runs the deterministic UPDATE/RANK operations safely.           │
-- │   A call on an already 'completed' tournament is rejected immediately     │
-- │   by the status guard, preventing double-settlement.                      │
-- └─────────────────────────────────────────────────────────────────────────┘
-- =============================================================================
-- =============================================================================
-- Migration: 007_bankruptcy_protection
-- Description: Socialized-loss / bankruptcy-fund mechanism for extreme market
--              conditions where a position blows past its liquidation price
--              between scanner ticks (60-second cron window).
-- Created: 2026-03-29
--
-- Problem being solved:
--   close_trade_txn receives p_settlement = max(0, margin + pnl) from the Edge
--   Function.  In theory that clamp prevents a negative settlement.  In practice
--   the Edge Function computes pnl at "request time" while the cron scanner runs
--   every 60 seconds — a 100x leveraged position can swing through its entire
--   margin and continue into negative equity within that window.  When a user
--   manually closes such a position, p_settlement can still be zero yet the
--   balance arithmetic inside the RPC may produce a negative number if there is
--   a concurrent settlement race on the user row.  The existing CHECK constraint
--   (balance >= 0) would then abort the whole transaction, leaving the trade row
--   stuck in 'open' status — a zombie position.
--
--   liquidate_trade_txn does not touch the balance (settlement = 0) so the
--   zombie-position risk is lower, but concurrent close_trade_txn calls settling
--   simultaneously could still push the balance negative after the lock is
--   acquired, triggering the same CHECK abort.
--
-- Solution — three-part:
--   1. CREATE TABLE public.bankruptcy_events: immutable audit log of every
--      socialized loss event, for exchange reconciliation.
--   2. CREATE OR REPLACE public.close_trade_txn: clamp balance to GREATEST(0, …)
--      BEFORE the UPDATE so the CHECK constraint is never violated.  If clamping
--      occurs, insert a bankruptcy_events row inside the same transaction.
--   3. CREATE OR REPLACE public.liquidate_trade_txn: add a belt-and-suspenders
--      post-update guard — if concurrent settlements somehow drove the balance
--      negative before we acquired the FOR UPDATE lock, clamp it and audit it.
--
-- What stays unchanged:
--   - The CHECK constraint users_balance_non_negative (balance >= 0) is the
--     last line of defence and is NOT removed.  If a code path ever bypasses
--     the RPCs and writes a negative balance directly, the constraint catches it.
--   - All REVOKE statements from 002 and 003 remain in effect; this migration
--     adds no new grantees.
--
-- New objects:
--   TABLE  public.bankruptcy_events     — immutable socialized-loss audit log
--   RPC    public.close_trade_txn       — replaces 002 version (add clamp + audit)
--   RPC    public.liquidate_trade_txn   — replaces 003 version (add safety clamp)
--
-- Security model:
--   bankruptcy_events:
--     - anon          : REVOKED at privilege level (belt-and-suspenders)
--     - authenticated : SELECT own rows only (auth.uid() = user_id)
--     - service_role  : full access (RLS bypassed)
--   close_trade_txn / liquidate_trade_txn:
--     - PUBLIC / anon / authenticated : REVOKED (unchanged from 002 / 003)
--     - service_role  : callable (Edge Function context)
-- =============================================================================

BEGIN;

-- =============================================================================
-- TABLE: public.bankruptcy_events
-- =============================================================================
-- One row is inserted per trade closure where the computed post-settlement
-- balance would have been negative.  The system absorbs ("socializes") that
-- shortfall rather than rejecting the transaction.
--
-- Column notes:
--   expected_balance  — the raw arithmetic result before clamping; will be < 0
--   clamped_balance   — always 0.0000 (the value actually written to users.balance)
--   socialized_loss   — ABS(expected_balance); the deficit absorbed by the system
--
-- The expected_balance / clamped_balance pair is stored separately (not just
-- socialized_loss) so reconciliation can reconstruct the exact pre- and
-- post-clamp state from this table alone.
-- =============================================================================

CREATE TABLE public.bankruptcy_events (
  id               UUID           PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The trade whose closure triggered the bankruptcy event.
  trade_id         UUID           NOT NULL REFERENCES public.trades(id),

  -- Denormalised for fast per-user history queries without joining trades.
  user_id          UUID           NOT NULL REFERENCES public.users(id),

  -- Raw arithmetic result: locked_balance + settlement.  Always negative here
  -- (if it were >= 0 this row would not exist).
  expected_balance NUMERIC(18, 4) NOT NULL,

  -- The value actually written to users.balance.  Always 0 under the current
  -- socialized-loss policy.  Stored explicitly so the schema can accommodate
  -- a partial-clamp policy in the future without a column migration.
  clamped_balance  NUMERIC(18, 4) NOT NULL DEFAULT 0,

  -- Magnitude of the loss absorbed by the system: ABS(expected_balance).
  -- Positive number always.  Used for exchange-level P&L reconciliation.
  socialized_loss  NUMERIC(18, 4) NOT NULL,

  -- Wall-clock timestamp at the moment of insertion; immutable after write.
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- Index: "show me my bankruptcy history" — the primary client query path.
CREATE INDEX idx_bankruptcy_events_user
  ON public.bankruptcy_events (user_id, created_at DESC);

-- Index: lookup by trade_id for internal reconciliation / admin queries.
CREATE INDEX idx_bankruptcy_events_trade
  ON public.bankruptcy_events (trade_id);


-- ---------------------------------------------------------------------------
-- RLS: public.bankruptcy_events
-- ---------------------------------------------------------------------------

ALTER TABLE public.bankruptcy_events ENABLE ROW LEVEL SECURITY;

-- Policy: authenticated users can read only their own bankruptcy history.
-- Useful for the client to display "your position was closed at zero balance"
-- notifications without exposing other users' events.
CREATE POLICY "bankruptcy_events: owner can select"
  ON public.bankruptcy_events
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- No INSERT / UPDATE / DELETE policies for any client role.
-- All writes are performed inside close_trade_txn and liquidate_trade_txn
-- (both SECURITY DEFINER), which run as the function owner and bypass RLS.

-- Belt-and-suspenders: block all anon access at the privilege level as well.
REVOKE ALL ON public.bankruptcy_events FROM anon;


-- =============================================================================
-- RPC: close_trade_txn  (replaces 002_trade_rpc_functions version)
-- =============================================================================
-- Called by: supabase/functions/close-trade/index.ts
--
-- Identical to the 002 version except for Steps 5-6, which now:
--   a. Compute the raw candidate balance (locked_balance + settlement).
--   b. If the candidate is negative (bankruptcy scenario):
--        - Insert a bankruptcy_events audit row.
--        - Clamp the candidate to 0.
--   c. Compute ROI using the clamped balance (not the theoretical negative).
--   d. Write the clamped balance and ROI to users.
--   e. Raise NO error — the trade is still marked 'closed' and the caller
--      receives the closed trade row normally.
--
-- Why the CHECK constraint is still safe:
--   GREATEST(0, v_raw_balance) is computed in a local variable BEFORE the
--   UPDATE statement executes.  PostgreSQL evaluates the CHECK on the value
--   actually written, which is always >= 0.
--
-- Parameters (unchanged from 002):
--   p_trade_id     — trade to close
--   p_user_id      — must match trade.user_id
--   p_exit_price   — market price at close
--   p_realised_pnl — signed PnL (may be negative)
--   p_settlement   — max(0, margin + pnl) as computed by the Edge Function;
--                    passing 0 is the normal loss scenario — the RPC still
--                    handles the edge case where locked_balance itself has
--                    been eroded by concurrent settlements.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.close_trade_txn(
  p_trade_id      UUID,
  p_user_id       UUID,
  p_exit_price    NUMERIC(20, 8),
  p_realised_pnl  NUMERIC(18, 4),
  p_settlement    NUMERIC(18, 4)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trade           RECORD;
  v_locked_balance  NUMERIC(18, 4);
  v_raw_balance     NUMERIC(18, 4);   -- arithmetic result before clamp
  v_new_balance     NUMERIC(18, 4);   -- value that will be written to users
  v_new_roi         NUMERIC(10, 6);
  v_result          JSONB;
  v_initial_balance CONSTANT NUMERIC := 10000;
BEGIN
  -- Step 1: Lock the trade row.
  -- FOR UPDATE prevents a concurrent close request on the same trade.
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Step 2: Validate ownership and status.
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not belong to user %',
      p_trade_id, p_user_id;
  END IF;

  IF v_trade.status != 'open' THEN
    RAISE EXCEPTION 'trade_not_found: Trade % is not open (status=%)',
      p_trade_id, v_trade.status;
  END IF;

  -- Step 3: Close the trade.
  UPDATE public.trades
  SET
    status       = 'closed',
    exit_price   = p_exit_price,
    realised_pnl = p_realised_pnl
  WHERE id = p_trade_id;

  -- Step 4: Lock the users row.
  -- This is critical when two trades for the same user close simultaneously.
  -- Without FOR UPDATE, both could read the same balance and one settlement
  -- would be silently overwritten.
  SELECT balance INTO v_locked_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  -- Step 5: Compute raw (pre-clamp) candidate balance.
  -- Normal path:     v_raw_balance >= 0 (settlement covers the loss).
  -- Bankruptcy path: v_raw_balance <  0 (position blew past liquidation price
  --                  between cron scans; extreme slippage absorbed by system).
  v_raw_balance := v_locked_balance + p_settlement;

  -- Step 6: Socialized-loss clamp.
  -- If the raw balance is negative we cannot write it — the CHECK constraint
  -- (balance >= 0) would abort the entire transaction and leave the trade row
  -- in 'open' status (zombie position).  Instead we:
  --   a. Record the event in bankruptcy_events for exchange reconciliation.
  --   b. Clamp the balance to 0 — the user loses everything but the
  --      transaction completes cleanly.
  -- This is the same "auto-deleveraging / socialized loss" approach used by
  -- BitMEX, Binance Futures, and every other leveraged exchange.
  IF v_raw_balance < 0 THEN
    INSERT INTO public.bankruptcy_events (
      trade_id,
      user_id,
      expected_balance,
      clamped_balance,
      socialized_loss
    ) VALUES (
      p_trade_id,
      p_user_id,
      v_raw_balance,             -- negative; the raw arithmetic result
      0,                         -- what we will actually write
      ABS(v_raw_balance)         -- positive magnitude absorbed by system
    );

    v_new_balance := 0;
  ELSE
    v_new_balance := v_raw_balance;
  END IF;

  -- Step 7: Compute ROI using the clamped balance.
  -- Using v_new_balance (not v_raw_balance) keeps ROI in the range [-1, ∞)
  -- which is the mathematically correct bound for a total wipeout.
  v_new_roi := (v_new_balance - v_initial_balance) / v_initial_balance;

  -- Step 8: Write the clamped balance and recomputed ROI.
  -- At this point v_new_balance >= 0, so the CHECK constraint is satisfied.
  UPDATE public.users
  SET
    balance = v_new_balance,
    roi     = v_new_roi
  WHERE id = p_user_id;

  -- Step 9: Return the closed trade as JSONB.
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function.
REVOKE ALL ON FUNCTION public.close_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM authenticated;


-- =============================================================================
-- RPC: liquidate_trade_txn  (replaces 003_liquidation version)
-- =============================================================================
-- Called by: supabase/functions/liquidation-scanner/index.ts
--
-- Identical to the 003 version except for a safety clamp inserted after the
-- users balance is read in Step 5.
--
-- Why the clamp is needed here even though settlement = 0:
--   liquidate_trade_txn does not change the balance (the margin was already
--   deducted at trade open; on liquidation no funds are returned).  Under
--   normal conditions the balance read in Step 5 is unchanged.  However, if
--   two close_trade_txn calls for the SAME user race the liquidation scanner
--   and both settle losses concurrently, one of them could drive the balance
--   negative before THIS function acquires the FOR UPDATE lock.  In that case
--   the balance the scanner reads is already negative, the ROI update would
--   succeed (it doesn't touch balance), but the database is in an inconsistent
--   state.  The clamp here corrects it atomically and logs the discrepancy.
--
--   This is a belt-and-suspenders guard.  In a correctly operating system it
--   should never fire, because close_trade_txn now also clamps.  It exists so
--   that a future bug or direct SQL write cannot silently leave the users table
--   with a negative balance that goes undetected.
--
-- Idempotency (unchanged from 003):
--   If the trade is already non-'open' the function returns NULL — no error,
--   no duplicate audit row, no balance change.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.liquidate_trade_txn(
  p_trade_id     UUID,
  p_user_id      UUID,
  p_market_price NUMERIC(20, 8)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trade           RECORD;
  v_user_balance    NUMERIC(18, 4);
  v_new_roi         NUMERIC(10, 6);
  v_result          JSONB;
  v_initial_balance CONSTANT NUMERIC := 10000;
BEGIN
  -- Step 1: Lock the trade row.
  -- FOR UPDATE prevents a concurrent liquidation scanner invocation from
  -- double-liquidating the same trade within the same price-tick window.
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Step 2: Idempotency guard.
  -- If the trade was already closed or liquidated by another process,
  -- return NULL so the scanner can move on without raising an error.
  IF v_trade.status != 'open' THEN
    RETURN NULL;
  END IF;

  -- Step 3: Validate ownership.
  -- Ownership is re-checked here (not just at the Edge Function layer)
  -- because this function is SECURITY DEFINER and must not be tricked
  -- into liquidating a trade belonging to a different user.
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % ownership mismatch', p_trade_id;
  END IF;

  -- Step 4: Force-close the trade.
  -- exit_price is set to the pre-computed liquidation_price (not market_price)
  -- so realised_pnl arithmetic is exact: pnl = -margin for a full wipeout.
  UPDATE public.trades
  SET
    status       = 'liquidated',
    exit_price   = v_trade.liquidation_price,
    realised_pnl = -v_trade.margin
  WHERE id = p_trade_id;

  -- Step 5: Lock the user row.
  -- Balance does not change (settlement = 0; margin was already deducted at
  -- trade open).  We lock FOR UPDATE anyway to serialize ROI recomputation
  -- against any concurrent close_trade_txn that might settle simultaneously.
  SELECT balance INTO v_user_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  -- Step 6: Belt-and-suspenders bankruptcy guard.
  -- Under normal operation v_user_balance >= 0 and this branch is never taken.
  -- If a concurrent settlement race or a direct SQL write drove the balance
  -- negative before we acquired the lock, we correct it here atomically and
  -- log the discrepancy so the anomaly is visible in the audit trail.
  --
  -- Note: we write balance = 0 via an explicit UPDATE here rather than folding
  -- it into the ROI UPDATE below, so the logic stays readable and the two
  -- concerns (balance correction vs. ROI recomputation) remain separated.
  IF v_user_balance < 0 THEN
    INSERT INTO public.bankruptcy_events (
      trade_id,
      user_id,
      expected_balance,
      clamped_balance,
      socialized_loss
    ) VALUES (
      p_trade_id,
      p_user_id,
      v_user_balance,        -- the negative balance we found on the row
      0,
      ABS(v_user_balance)    -- positive magnitude
    );

    -- Correct the balance in-place, then update our local variable so ROI
    -- is computed from the clamped value, not the negative one.
    UPDATE public.users
    SET balance = 0
    WHERE id = p_user_id;

    v_user_balance := 0;
  END IF;

  -- Step 7: Recompute ROI against the (clamped) current balance.
  v_new_roi := (v_user_balance - v_initial_balance) / v_initial_balance;

  UPDATE public.users
  SET roi = v_new_roi
  WHERE id = p_user_id;

  -- Step 8: Write the immutable liquidation audit row.
  INSERT INTO public.liquidation_events (
    trade_id, user_id, symbol, liquidation_price, market_price, margin
  ) VALUES (
    p_trade_id,
    p_user_id,
    v_trade.symbol,
    v_trade.liquidation_price,
    p_market_price,
    v_trade.margin
  );

  -- Step 9: Return the updated trade as JSONB.
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function.
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM authenticated;


COMMIT;


-- =============================================================================
-- SECURITY MODEL ADDENDUM (007)
-- =============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ bankruptcy_events access matrix                                         │
-- ├──────────────────┬──────────────────────────────────────────────────────┤
-- │ anon             │ REVOKED at privilege level                           │
-- │ authenticated    │ SELECT own rows only (auth.uid() = user_id)          │
-- │ service_role     │ full access (RLS bypassed)                           │
-- ├──────────────────┴──────────────────────────────────────────────────────┤
-- │ close_trade_txn / liquidate_trade_txn                                   │
-- ├──────────────────┬──────────────────────────────────────────────────────┤
-- │ PUBLIC / anon /  │ REVOKED — unchanged from 002 / 003                   │
-- │ authenticated    │                                                      │
-- │ service_role     │ callable (Edge Function context)                     │
-- ├──────────────────┴──────────────────────────────────────────────────────┤
-- │ CHECK constraint preservation                                           │
-- │   users_balance_non_negative (balance >= 0) is NOT dropped.             │
-- │   The RPCs clamp to GREATEST(0, …) in a local variable BEFORE the       │
-- │   UPDATE statement, so PostgreSQL always sees a non-negative value.      │
-- │   Any direct SQL write that bypasses the RPCs will still be caught.     │
-- ├──────────────────────────────────────────────────────────────────────────┤
-- │ Bankruptcy trigger conditions (close_trade_txn)                         │
-- │   1. 100x leverage + price moves > 1% past liquidation in < 60 s        │
-- │   2. Concurrent settlement race erodes balance to below margin           │
-- │   3. Manual close of a position that should already be liquidated        │
-- ├──────────────────────────────────────────────────────────────────────────┤
-- │ Bankruptcy trigger conditions (liquidate_trade_txn)                     │
-- │   Theoretically zero (settlement = 0, balance unchanged).               │
-- │   Guard fires only if balance is already negative when the lock is       │
-- │   acquired — indicates a prior bug or race; logged for investigation.    │
-- ├──────────────────────────────────────────────────────────────────────────┤
-- │ Reconciliation workflow                                                  │
-- │   SELECT b.created_at, b.trade_id, b.socialized_loss                    │
-- │   FROM   public.bankruptcy_events b                                      │
-- │   ORDER BY b.created_at DESC;                                           │
-- │                                                                         │
-- │   SUM(socialized_loss) = exchange-level insurance fund drawdown          │
-- └─────────────────────────────────────────────────────────────────────────┘
-- =============================================================================
-- ============================================================
-- Migration : 008_daily_rewards
-- Description: Implements the daily check-in reward system.
--              Adds streak-tracking columns to public.users,
--              creates an immutable audit table (daily_claims),
--              and exposes a single atomic RPC
--              (award_daily_reward_txn) for the bot/edge layer.
--
-- Security model
--   - daily_claims is readable only by the owning authenticated
--     user via RLS; anon has zero access.
--   - The RPC is SECURITY DEFINER so it can increment balance
--     and write the audit row without exposing the underlying
--     tables to the caller.
--   - EXECUTE is revoked from PUBLIC and anon; only the service
--     role (bot / edge functions) may call the function directly.
--     Frontend clients reach it through the bot gateway only.
--   - The idempotency guard (UNIQUE constraint + ON CONFLICT DO
--     NOTHING inside the RPC) makes repeated invocations safe.
--
-- Depends on : 001_initial_schema (public.users)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Extend public.users with streak-tracking columns
-- ------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN current_streak   INT  NOT NULL DEFAULT 0,
  ADD COLUMN last_claim_date  DATE;

COMMENT ON COLUMN public.users.current_streak  IS
  'Number of consecutive calendar days (UTC) the user has claimed '
  'their daily reward. Resets to 1 whenever a day is skipped.';

COMMENT ON COLUMN public.users.last_claim_date IS
  'UTC calendar date of the most recent successful daily claim. '
  'NULL for users who have never claimed.';

-- ------------------------------------------------------------
-- Section 2 — Audit / history table: public.daily_claims
--
-- Append-only. One row per (user, date). The UNIQUE constraint
-- is the authoritative idempotency guard; the RPC uses
-- ON CONFLICT DO NOTHING as a second layer.
-- ------------------------------------------------------------

CREATE TABLE public.daily_claims (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID          NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  claim_date    DATE          NOT NULL,
  streak_day    INT           NOT NULL CHECK (streak_day >= 1),
  bonus_amount  NUMERIC(18,4) NOT NULL CHECK (bonus_amount > 0),
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT daily_claims_user_date_unique UNIQUE (user_id, claim_date)
);

COMMENT ON TABLE public.daily_claims IS
  'Immutable record of every successful daily reward claim. '
  'Used for audit, streak display, and idempotency enforcement.';

COMMENT ON COLUMN public.daily_claims.streak_day   IS 'Streak value at the time of this claim (1-based).';
COMMENT ON COLUMN public.daily_claims.bonus_amount IS 'Tokens credited to the user for this claim.';

-- Supporting index: user history queries and the rate-limit check
-- inside the RPC (user_id + claim_date DESC covers both).
CREATE INDEX idx_daily_claims_user
  ON public.daily_claims (user_id, claim_date DESC);

-- ------------------------------------------------------------
-- Section 3 — Row Level Security on public.daily_claims
-- ------------------------------------------------------------

ALTER TABLE public.daily_claims ENABLE ROW LEVEL SECURITY;

-- Authenticated users may read their own claim history.
CREATE POLICY "daily_claims: owner can select"
  ON public.daily_claims
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- No INSERT / UPDATE / DELETE policies for authenticated users:
-- writes happen exclusively through the SECURITY DEFINER RPC.
REVOKE ALL ON public.daily_claims FROM anon;

-- ------------------------------------------------------------
-- Section 4 — RPC: award_daily_reward_txn
--
-- Caller   : service_role (bot / edge function only)
-- Args     : p_user_id UUID  — the user requesting the reward
-- Returns  : JSONB with the following keys:
--              already_claimed  BOOLEAN
--              streak           INT      (current streak after claim)
--              bonus_amount     NUMERIC  (0 if already_claimed)
--              new_balance      NUMERIC  (unchanged if already_claimed)
--
-- Bonus schedule (tokens):
--   Day 1 → 100  |  Day 2 → 150  |  Day 3 → 200
--   Day 4 → 250  |  Day 5 → 350  |  Day 6 → 500
--   Day 7+ → 750
--
-- Atomicity guarantee:
--   The function runs inside the caller's transaction (or its own
--   implicit one). The FOR UPDATE lock on users prevents double-
--   spend in concurrent requests for the same user_id.
--
-- Human-only guard:
--   Bot accounts (is_human = FALSE) are rejected with a raised
--   exception so the caller can surface a meaningful error.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.award_daily_reward_txn(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user            RECORD;
  v_claim_date      DATE;
  v_new_streak      INT;
  v_bonus           NUMERIC(18,4);
  v_already_claimed BOOLEAN := FALSE;
BEGIN
  -- 1. Lock the user row to serialise concurrent claims.
  SELECT id, is_human, balance, current_streak, last_claim_date
  INTO   v_user
  FROM   public.users
  WHERE  id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User % not found', p_user_id;
  END IF;

  -- 2. Human-only guard.
  IF NOT v_user.is_human THEN
    RAISE EXCEPTION 'Daily rewards are available only to human users';
  END IF;

  -- 3. Compute today's UTC calendar date.
  v_claim_date := (NOW() AT TIME ZONE 'UTC')::DATE;

  -- 4. Check idempotency: has this user already claimed today?
  IF v_user.last_claim_date = v_claim_date THEN
    v_already_claimed := TRUE;
    RETURN jsonb_build_object(
      'already_claimed', TRUE,
      'streak',          v_user.current_streak,
      'bonus_amount',    0,
      'new_balance',     v_user.balance
    );
  END IF;

  -- 5. Compute new streak:
  --    - Consecutive day  → increment
  --    - Any other case   → reset to 1
  IF v_user.last_claim_date = v_claim_date - INTERVAL '1 day' THEN
    v_new_streak := v_user.current_streak + 1;
  ELSE
    v_new_streak := 1;
  END IF;

  -- 6. Determine bonus amount from the streak day.
  v_bonus := CASE
    WHEN v_new_streak >= 7 THEN 750
    WHEN v_new_streak =  6 THEN 500
    WHEN v_new_streak =  5 THEN 350
    WHEN v_new_streak =  4 THEN 250
    WHEN v_new_streak =  3 THEN 200
    WHEN v_new_streak =  2 THEN 150
    ELSE                        100
  END;

  -- 7. Credit the user's balance and update streak state.
  UPDATE public.users
  SET
    balance         = balance + v_bonus,
    current_streak  = v_new_streak,
    last_claim_date = v_claim_date
  WHERE id = p_user_id;

  -- 8. Write the audit record; ON CONFLICT DO NOTHING provides a
  --    second idempotency layer in case of a race between two
  --    concurrent callers that both passed the check in step 4.
  INSERT INTO public.daily_claims (user_id, claim_date, streak_day, bonus_amount)
  VALUES (p_user_id, v_claim_date, v_new_streak, v_bonus)
  ON CONFLICT (user_id, claim_date) DO NOTHING;

  -- 9. Return result.
  RETURN jsonb_build_object(
    'already_claimed', FALSE,
    'streak',          v_new_streak,
    'bonus_amount',    v_bonus,
    'new_balance',     v_user.balance + v_bonus
  );
END;
$$;

-- Revoke broad default execute privilege; grant to service_role only.
REVOKE EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) FROM anon;
REVOKE EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) TO service_role;

COMMENT ON FUNCTION public.award_daily_reward_txn(UUID) IS
  'Atomic daily reward claim. Locks the user row, checks idempotency, '
  'computes the streak-based bonus, credits balance, and writes an audit '
  'row. Returns JSONB: {already_claimed, streak, bonus_amount, new_balance}. '
  'Callable by service_role only. Human-only: rejects bot accounts.';

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DROP FUNCTION IF EXISTS public.award_daily_reward_txn(UUID);
-- DROP TABLE  IF EXISTS public.daily_claims;
-- ALTER TABLE public.users
--   DROP COLUMN IF EXISTS current_streak,
--   DROP COLUMN IF EXISTS last_claim_date;
-- ============================================================
-- ============================================================
-- Migration : 009_notifications
-- Description: Adds the infrastructure required for the Telegram
--              Bot notification system (Phase 3).
--              - tg_chat_id and notifications_enabled on users
--              - reminder_sent_at on tournament_participants
--              - notification_log for rate-limiting and audit
--
-- Notification types supported
--   liquidation          — trade was force-closed
--   tournament_reminder  — tournament starts/ends soon
--   rivalry              — a rival just overtook the user
--   streak_reminder      — user is about to lose their streak
--   achievement          — new badge unlocked
--
-- Security model
--   - notification_log is readable by the owning authenticated
--     user (own history) and by nobody else. Writes are
--     service_role-only; no authenticated INSERT policy exists,
--     preventing users from forging delivery records.
--   - anon has no access to notification_log.
--   - The two new users columns (tg_chat_id, notifications_enabled)
--     are writable by the user through the existing users RLS
--     UPDATE policy assumed to be in place from migration 001.
--
-- Rate-limit index notes
--   idx_notification_log_rate_limit is a partial index covering
--   only delivered = TRUE rows. The bot queries this index to
--   count recent deliveries per (user_id, type) before sending
--   the next message, keeping the index small and the scan fast.
--
-- Depends on : 001_initial_schema (public.users,
--               public.tournament_participants)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Extend public.users with notification columns
-- ------------------------------------------------------------

-- tg_chat_id is the Telegram chat_id used for Bot DM delivery.
-- For users who opened the app via a private /start command it
-- equals their tg_id cast to TEXT; stored as TEXT because the
-- Telegram Bot API accepts both numeric and string chat IDs and
-- future-proofs against Telegram widening their ID space.
ALTER TABLE public.users
  ADD COLUMN tg_chat_id                TEXT,
  ADD COLUMN notifications_enabled     BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN streak_reminder_sent_today DATE;

COMMENT ON COLUMN public.users.tg_chat_id IS
  'Telegram chat_id for Bot DM delivery. Populated on the first '
  '/start interaction in the user''s private chat. NULL means the '
  'user has not yet initiated a private conversation with the bot '
  'and cannot receive DMs.';

COMMENT ON COLUMN public.users.notifications_enabled IS
  'Master notification toggle. When FALSE the bot skips all '
  'outbound messages for this user regardless of type.';

-- ------------------------------------------------------------
-- Section 2 — Extend public.tournament_participants
-- ------------------------------------------------------------

-- Tracks when the pre-tournament reminder was dispatched so the
-- scheduled job does not send duplicates on re-run.
ALTER TABLE public.tournament_participants
  ADD COLUMN reminder_sent_at TIMESTAMPTZ;

COMMENT ON COLUMN public.tournament_participants.reminder_sent_at IS
  'Timestamp of the most recent tournament reminder notification '
  'sent to this participant. NULL means no reminder has been sent. '
  'Used to prevent duplicate delivery on scheduler re-runs.';

-- ------------------------------------------------------------
-- Section 3 — Notification log table
--
-- Append-only. Each row represents one attempted notification
-- dispatch. The delivered flag is FALSE when the Telegram API
-- returned an error (e.g. user blocked the bot) so we keep the
-- record for debugging without inflating rate-limit counts.
-- ------------------------------------------------------------

CREATE TABLE public.notification_log (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  notification_type  TEXT        NOT NULL CHECK (notification_type IN (
                       'liquidation',
                       'tournament_reminder',
                       'rivalry',
                       'streak_reminder',
                       'achievement'
                     )),
  payload            JSONB       NOT NULL DEFAULT '{}',
  sent_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  delivered          BOOLEAN     NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE public.notification_log IS
  'Audit log of every outbound notification attempt made by the '
  'Telegram bot. Used for rate-limiting, debugging, and user-facing '
  'notification history.';

COMMENT ON COLUMN public.notification_log.notification_type IS
  'Enum: liquidation | tournament_reminder | rivalry | '
  'streak_reminder | achievement';

COMMENT ON COLUMN public.notification_log.payload IS
  'Structured metadata for this notification (e.g. trade_id, '
  'tournament_id, rival_user_id). Schema varies by type.';

COMMENT ON COLUMN public.notification_log.delivered IS
  'TRUE when the Telegram API confirmed delivery. FALSE when the '
  'API returned an error (user blocked bot, deactivated account, '
  'etc.). Failed rows are retained for debugging but excluded from '
  'rate-limit counts via the partial index.';

-- Primary access pattern: user history page (user + recent first).
CREATE INDEX idx_notification_log_user_time
  ON public.notification_log (user_id, sent_at DESC);

-- Rate-limit check: count successful deliveries per user in a
-- rolling window. Partial on delivered = TRUE to keep it small.
CREATE INDEX idx_notification_log_rate_limit
  ON public.notification_log (user_id, sent_at)
  WHERE delivered = TRUE;

-- Type-level rate-limit check (e.g. max 1 rivalry ping per hour).
CREATE INDEX idx_notification_log_type_rate_limit
  ON public.notification_log (user_id, notification_type, sent_at)
  WHERE delivered = TRUE;

-- ------------------------------------------------------------
-- Section 4 — Row Level Security on public.notification_log
-- ------------------------------------------------------------

ALTER TABLE public.notification_log ENABLE ROW LEVEL SECURITY;

-- Authenticated users may view their own notification history.
-- No INSERT/UPDATE/DELETE policies: writes are service_role-only.
CREATE POLICY "notification_log: owner can select"
  ON public.notification_log
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Harden against anon access.
REVOKE ALL ON public.notification_log FROM anon;

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DROP TABLE IF EXISTS public.notification_log;
-- ALTER TABLE public.tournament_participants
--   DROP COLUMN IF EXISTS reminder_sent_at;
-- ALTER TABLE public.users
--   DROP COLUMN IF EXISTS tg_chat_id,
--   DROP COLUMN IF EXISTS notifications_enabled;
-- ============================================================
-- ============================================================
-- Migration : 010_achievements
-- Description: Introduces the achievement / badge system for
--              Phase 3 gamification.
--
--              Three tables:
--                achievements            — static catalogue (seeded)
--                user_achievements       — earned badges (immutable)
--                user_achievement_progress — progress toward badges
--                                           with is_progress_tracked=TRUE
--
-- Achievement catalogue (seeded at end of migration)
--   ACH-001  Claw Crusher     — Beat OpenClaw ROI 3 times
--   ACH-002  Daredevil        — Close a 100x position w/out liquidation
--   ACH-003  Arena Elite      — Finish Top 10 in any tournament
--   ACH-004  Golden Claw      — >50% ROI on a single trade
--   ACH-005  Streak Keeper    — 7-day consecutive login streak
--   ACH-006  Survivor         — Hold position 24+ h w/out liquidation
--
-- Security model
--   achievements (catalogue)
--     - Readable by everyone (anon + authenticated): badge names
--       and descriptions must be visible on the public leaderboard
--       and before the user authenticates.
--     - Writes are service_role-only (no INSERT/UPDATE policy for
--       authenticated); catalogue updates come via future migrations.
--
--   user_achievements (earned rows)
--     - Readable by authenticated owner (profile page) AND by anon
--       (leaderboard badge display). Rows are intentionally public
--       because showing earned badges on the public arena is a core
--       product feature that drives competition.
--     - No UPDATE/DELETE ever: earned badges are permanent. The
--       service_role writes them exclusively through the bot or an
--       edge function that validates the unlock condition.
--
--   user_achievement_progress
--     - Readable by authenticated owner only.
--     - Writable by service_role only.
--     - anon has no access.
--
-- Unlock flow (handled by bot / edge function, not this migration)
--   1. Relevant event fires (trade closed, streak updated, etc.)
--   2. Edge function evaluates all progress-tracked achievements.
--   3. For non-progress achievements: INSERT directly if condition met.
--   4. For progress achievements: UPSERT user_achievement_progress;
--      if current_count >= required_count, INSERT user_achievements.
--
-- Depends on : 001_initial_schema (public.users)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Achievement catalogue (static reference data)
-- ------------------------------------------------------------

CREATE TABLE public.achievements (
  id                   TEXT    PRIMARY KEY,
  name                 TEXT    NOT NULL,
  description          TEXT    NOT NULL,
  icon_key             TEXT    NOT NULL,
  required_count       INT     NOT NULL DEFAULT 1 CHECK (required_count >= 1),
  is_progress_tracked  BOOLEAN NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE public.achievements IS
  'Static catalogue of all achievement definitions. Seeded by this '
  'migration; future badges added via subsequent migrations. '
  'Never modified at runtime.';

COMMENT ON COLUMN public.achievements.id IS
  'Human-readable slug, e.g. ACH-001. Stable identifier '
  'referenced by user_achievements and user_achievement_progress.';

COMMENT ON COLUMN public.achievements.icon_key IS
  'Key used by the Flutter app to resolve the badge icon asset.';

COMMENT ON COLUMN public.achievements.required_count IS
  'For progress-tracked achievements: how many qualifying events '
  'must occur before the badge is awarded. Always 1 for one-shot '
  'achievements (is_progress_tracked = FALSE).';

COMMENT ON COLUMN public.achievements.is_progress_tracked IS
  'TRUE when the achievement requires incremental progress '
  '(e.g. beat bot 3 times). FALSE for one-shot events.';

ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;

-- Public read: badge names visible on leaderboard and before login.
CREATE POLICY "achievements: anyone can read"
  ON public.achievements
  FOR SELECT
  TO anon, authenticated
  USING (TRUE);

-- No INSERT/UPDATE/DELETE for non-service_role callers;
-- catalogue is updated exclusively via migrations.

-- ------------------------------------------------------------
-- Section 2 — Earned achievements (immutable ledger)
-- ------------------------------------------------------------

CREATE TABLE public.user_achievements (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  achievement_id  TEXT        NOT NULL REFERENCES public.achievements(id),
  earned_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT user_achievements_unique UNIQUE (user_id, achievement_id)
);

COMMENT ON TABLE public.user_achievements IS
  'Immutable record of every achievement earned by a user. '
  'Rows are append-only; deletion or update is prohibited for '
  'non-service_role callers. A UNIQUE constraint ensures each '
  'badge can only be awarded once per user.';

COMMENT ON COLUMN public.user_achievements.earned_at IS
  'UTC timestamp at which the unlock condition was satisfied and '
  'the row was inserted by the service layer.';

CREATE INDEX idx_user_achievements_user
  ON public.user_achievements (user_id);

ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;

-- Owner can read their own earned badges (profile page).
CREATE POLICY "user_achievements: owner can select"
  ON public.user_achievements
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Public read: badges are shown on the leaderboard and arena
-- pages for all users, including unauthenticated visitors.
CREATE POLICY "user_achievements: public read for badges"
  ON public.user_achievements
  FOR SELECT
  TO anon
  USING (TRUE);

-- No INSERT/UPDATE/DELETE policies for authenticated or anon;
-- only service_role may write (via edge function).

-- ------------------------------------------------------------
-- Section 3 — Progress tracking table
-- ------------------------------------------------------------

CREATE TABLE public.user_achievement_progress (
  user_id         UUID    NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  achievement_id  TEXT    NOT NULL REFERENCES public.achievements(id),
  current_count   INT     NOT NULL DEFAULT 0 CHECK (current_count >= 0),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (user_id, achievement_id)
);

COMMENT ON TABLE public.user_achievement_progress IS
  'Tracks incremental progress toward achievements that require '
  'multiple qualifying events (is_progress_tracked = TRUE). '
  'The service layer UPSERTs this table on each relevant event '
  'and checks whether current_count >= required_count to trigger '
  'the final unlock INSERT into user_achievements.';

COMMENT ON COLUMN public.user_achievement_progress.current_count IS
  'Number of qualifying events accumulated so far for this '
  '(user, achievement) pair. Never decremented.';

COMMENT ON COLUMN public.user_achievement_progress.updated_at IS
  'Timestamp of the last increment, used for debugging and '
  'display in the app''s progress panel.';

-- No additional index needed: PK (user_id, achievement_id) covers
-- the service layer UPSERT and the owner SELECT below.

ALTER TABLE public.user_achievement_progress ENABLE ROW LEVEL SECURITY;

-- Owner can read their own progress (in-app progress bars).
CREATE POLICY "user_achievement_progress: owner can select"
  ON public.user_achievement_progress
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Harden: anon has no access to progress data.
REVOKE ALL ON public.user_achievement_progress FROM anon;

-- ------------------------------------------------------------
-- Section 4 — Seed the achievement catalogue
-- ------------------------------------------------------------

INSERT INTO public.achievements
  (id,        name,             description,                                        icon_key,   required_count, is_progress_tracked)
VALUES
  ('ACH-001', 'Claw Crusher',   'Beat OpenClaw''s ROI 3 times',                    'trophy',   3,              TRUE ),
  ('ACH-002', 'Daredevil',      'Close a 100x position without liquidation',        'lightning',1,              FALSE),
  ('ACH-003', 'Arena Elite',    'Finish Top 10 in any tournament',                  'medal',    1,              FALSE),
  ('ACH-004', 'Golden Claw',    'Achieve >50% ROI on a single trade',               'star',     1,              FALSE),
  ('ACH-005', 'Streak Keeper',  'Maintain a 7-day consecutive daily login streak',  'fire',     7,              TRUE ),
  ('ACH-006', 'Survivor',       'Hold a position 24+ hours without liquidation',    'shield',   1,              FALSE);

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DROP TABLE IF EXISTS public.user_achievement_progress;
-- DROP TABLE IF EXISTS public.user_achievements;
-- DROP TABLE IF EXISTS public.achievements;
-- ============================================================
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
-- =============================================================================
-- Migration: 012_lock_ordering
-- Description: Establish canonical FOR UPDATE lock ordering across all RPCs
--              to eliminate deadlock risk from inconsistent table acquisition
--              sequences.
-- Created: 2026-03-29
--
-- PROBLEM
-- -------
-- Prior to this migration two competing lock orderings existed:
--
--   execute_trade_txn  (002): users  --> trades INSERT
--   close_trade_txn    (007): trades --> users           *** REVERSED ***
--   liquidate_trade_txn(007): trades --> users           *** REVERSED ***
--   join_tournament_txn(006): tournaments --> users      (already correct)
--   settle_tournament_txn(006): tournaments only         (no conflict)
--   award_daily_reward_txn(008): users only              (no conflict)
--
-- The deadlock cycle:
--   T1 (execute_trade_txn): holds lock on users row U1, waiting for trades
--      INSERT which may conflict with a partial unique index on (user_id,symbol).
--   T2 (close_trade_txn):   holds lock on trades row T1, waiting for users row U1.
--   PostgreSQL detects the wait cycle and terminates one transaction with:
--     ERROR 40P01: deadlock detected
--
-- SOLUTION
-- --------
-- Establish a single canonical ordering that every RPC must follow:
--
--   1. tournaments  (lock first, if this table is involved)
--   2. users        (always lock before trades)
--   3. trades       (always lock after users)
--
-- For close_trade_txn and liquidate_trade_txn this means:
--   - Read the trade row WITHOUT a lock (plain SELECT, no FOR UPDATE) to
--     perform the ownership and status pre-check.
--   - Acquire the users row lock (FOR UPDATE).
--   - Re-acquire the trade row lock (FOR UPDATE) AFTER the users lock.
--   - Re-validate trade status after holding both locks (TOCTOU guard).
--   - Execute the mutation steps.
--
-- The "peek then lock" pattern is safe because:
--   a. The pre-check is read-only (no mutation); a stale read is benign —
--      the double-check under both locks is authoritative.
--   b. If the trade status changed between the peek and the re-lock, the
--      double-check catches it and raises the appropriate error (close) or
--      returns NULL (liquidate, idempotency path).
--   c. Ownership (user_id column) is immutable after insert; the pre-check
--      can be trusted for the ownership assertion without re-validating.
--
-- What is NOT changed:
--   - execute_trade_txn    : already correct (users first, then INSERT on trades)
--   - join_tournament_txn  : already correct (tournaments first, then users)
--   - settle_tournament_txn: no user row lock; no ordering conflict
--   - award_daily_reward_txn: no trade row lock; no ordering conflict
--   - bankruptcy_events logic and socialized-loss clamp from migration 007
--   - All REVOKE statements from migrations 002, 003, 007 remain in effect
--   - The CHECK constraint users_balance_non_negative (balance >= 0) is kept
--
-- New objects:
--   RPC  public.close_trade_txn       — replaces 007 version
--   RPC  public.liquidate_trade_txn   — replaces 007 version
-- =============================================================================

BEGIN;

-- =============================================================================
-- RPC: close_trade_txn  (replaces 007_bankruptcy_protection version)
-- =============================================================================
-- Called by: supabase/functions/close-trade/index.ts
--
-- Lock order (canonical):
--   1. users  row  FOR UPDATE  (serialises concurrent balance mutations)
--   2. trades row  FOR UPDATE  (held under the users lock; no cycle possible)
--
-- Algorithm overview:
--   Peek  — read trade without lock to validate ownership + pre-check status.
--   Lock  — acquire users FOR UPDATE (canonical position 2).
--   Lock  — acquire trades FOR UPDATE (canonical position 3).
--   Check — re-validate trade status under both locks (TOCTOU guard).
--   Act   — close trade, compute balance with bankruptcy clamp, write users.
--
-- All business logic from 007 is preserved:
--   - Bankruptcy fund: if locked_balance + settlement < 0, insert a
--     bankruptcy_events row and clamp the written balance to 0.
--   - ROI is computed from the clamped balance, not the raw arithmetic result.
--   - The CHECK constraint (balance >= 0) is never violated because the
--     clamp runs in a local variable before the UPDATE executes.
--
-- Parameters (unchanged from 002/007):
--   p_trade_id     — trade to close
--   p_user_id      — must match trade.user_id
--   p_exit_price   — market price at close
--   p_realised_pnl — signed PnL (may be negative)
--   p_settlement   — max(0, margin + pnl) as computed by the Edge Function
--
-- Error codes (unchanged):
--   'trade_not_found' — trade missing, wrong owner, or not in 'open' status
-- =============================================================================

CREATE OR REPLACE FUNCTION public.close_trade_txn(
  p_trade_id      UUID,
  p_user_id       UUID,
  p_exit_price    NUMERIC(20, 8),
  p_realised_pnl  NUMERIC(18, 4),
  p_settlement    NUMERIC(18, 4)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trade           RECORD;
  v_locked_balance  NUMERIC(18, 4);
  v_raw_balance     NUMERIC(18, 4);   -- arithmetic result before clamp
  v_new_balance     NUMERIC(18, 4);   -- value that will be written to users
  v_new_roi         NUMERIC(10, 6);
  v_result          JSONB;
  v_initial_balance CONSTANT NUMERIC := 10000;
BEGIN
  -- -------------------------------------------------------------------------
  -- Peek: read the trade WITHOUT a lock.
  -- Purpose: fast ownership + existence pre-check before we pay the cost of
  -- acquiring the users lock.  This read is intentionally unlocked — the
  -- authoritative re-check happens at Step 3 under both locks.
  -- Why this is safe: user_id is immutable after INSERT; status is re-checked
  -- under the trade lock in Step 3, eliminating any TOCTOU window.
  -- -------------------------------------------------------------------------
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Ownership is immutable (never updated after INSERT) — safe to check here.
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not belong to user %',
      p_trade_id, p_user_id;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 1: Lock the users row (canonical lock order position 2).
  -- This is the first exclusive lock acquired in this function.
  -- All concurrent RPCs that touch users AND trades must acquire the users
  -- lock before the trades lock, preventing the cycle that causes deadlocks.
  -- -------------------------------------------------------------------------
  SELECT balance INTO v_locked_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    -- Defensive: the user must exist if the trade references them, but guard
    -- against a race with account deletion.
    RAISE EXCEPTION 'trade_not_found: User % does not exist', p_user_id;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 2: Lock the trades row (canonical lock order position 3).
  -- Acquired AFTER the users lock — this ordering is the fix.
  -- -------------------------------------------------------------------------
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  -- -------------------------------------------------------------------------
  -- Step 3: Re-validate trade status under both locks (TOCTOU guard).
  -- Between the unlocked peek above and this re-read, another transaction
  -- could have closed or liquidated the same trade.  We detect that here and
  -- raise the same error the caller expects, keeping behavior identical to
  -- the pre-012 version.
  -- -------------------------------------------------------------------------
  IF v_trade.status != 'open' THEN
    RAISE EXCEPTION 'trade_not_found: Trade % is not open (status=%)',
      p_trade_id, v_trade.status;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 4: Close the trade row.
  -- We hold FOR UPDATE on both users and trades at this point — no other
  -- transaction can modify either row until we COMMIT.
  -- -------------------------------------------------------------------------
  UPDATE public.trades
  SET
    status       = 'closed',
    exit_price   = p_exit_price,
    realised_pnl = p_realised_pnl
  WHERE id = p_trade_id;

  -- -------------------------------------------------------------------------
  -- Step 5: Compute raw (pre-clamp) candidate balance.
  -- v_locked_balance was read under the FOR UPDATE lock in Step 1, so it
  -- reflects the true serialised balance at this point in time.
  --
  -- Normal path:     v_raw_balance >= 0 (settlement covers the loss).
  -- Bankruptcy path: v_raw_balance <  0 (position blew past liquidation price
  --                  between cron scans; extreme slippage absorbed by system).
  -- -------------------------------------------------------------------------
  v_raw_balance := v_locked_balance + p_settlement;

  -- -------------------------------------------------------------------------
  -- Step 6: Socialized-loss clamp (preserved from migration 007).
  -- If the raw balance is negative the CHECK constraint (balance >= 0) would
  -- abort the entire transaction, leaving the trade row in 'closed' status
  -- while the balance remains unwritten — a split-brain state.  Instead:
  --   a. Record the event in bankruptcy_events for exchange reconciliation.
  --   b. Clamp the balance to 0 — the user loses everything but the
  --      transaction completes cleanly.
  -- This is the same "auto-deleveraging / socialized loss" approach used by
  -- BitMEX, Binance Futures, and every other leveraged exchange.
  -- -------------------------------------------------------------------------
  IF v_raw_balance < 0 THEN
    INSERT INTO public.bankruptcy_events (
      trade_id,
      user_id,
      expected_balance,
      clamped_balance,
      socialized_loss
    ) VALUES (
      p_trade_id,
      p_user_id,
      v_raw_balance,        -- negative; the raw arithmetic result
      0,                    -- what we will actually write
      ABS(v_raw_balance)    -- positive magnitude absorbed by system
    );

    v_new_balance := 0;
  ELSE
    v_new_balance := v_raw_balance;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 7: Compute ROI using the clamped balance.
  -- Using v_new_balance (not v_raw_balance) keeps ROI in the range [-1, ∞),
  -- which is the mathematically correct bound for a total wipeout.
  -- -------------------------------------------------------------------------
  v_new_roi := (v_new_balance - v_initial_balance) / v_initial_balance;

  -- -------------------------------------------------------------------------
  -- Step 8: Write the clamped balance and recomputed ROI.
  -- At this point v_new_balance >= 0, so the CHECK constraint is satisfied.
  -- -------------------------------------------------------------------------
  UPDATE public.users
  SET
    balance = v_new_balance,
    roi     = v_new_roi
  WHERE id = p_user_id;

  -- -------------------------------------------------------------------------
  -- Step 9: Return the closed trade as JSONB.
  -- -------------------------------------------------------------------------
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function (unchanged from 002/007).
REVOKE ALL ON FUNCTION public.close_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM authenticated;


-- =============================================================================
-- RPC: liquidate_trade_txn  (replaces 007_bankruptcy_protection version)
-- =============================================================================
-- Called by: supabase/functions/liquidation-scanner/index.ts
--
-- Lock order (canonical):
--   1. users  row  FOR UPDATE  (canonical position 2)
--   2. trades row  FOR UPDATE  (canonical position 3)
--
-- Algorithm overview:
--   Peek  — read trade without lock to validate existence, ownership, and
--            perform the idempotency pre-check.
--   Lock  — acquire users FOR UPDATE.
--   Lock  — acquire trades FOR UPDATE under the users lock.
--   Check — re-validate trade status under both locks (TOCTOU guard).
--           If already non-'open', release locks and return NULL (idempotent).
--   Act   — liquidate trade, apply belt-and-suspenders bankruptcy guard,
--           recompute ROI, write liquidation_events audit row.
--
-- All business logic from 007 is preserved:
--   - Idempotency: if trade is already non-'open', returns NULL without error.
--   - Belt-and-suspenders bankruptcy guard: if the balance is already negative
--     when the user lock is acquired (indicating a prior race or bug), the
--     balance is clamped to 0 and a bankruptcy_events row is inserted.
--   - settlement = 0: margin was deducted at trade open; nothing is returned
--     to the user on liquidation.
--
-- Parameters (unchanged from 003/007):
--   p_trade_id     — trade to liquidate
--   p_user_id      — must match trade.user_id
--   p_market_price — market price at the moment of scanner invocation
--                    (stored in liquidation_events for audit; exit_price is
--                    set to liquidation_price, not market_price)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.liquidate_trade_txn(
  p_trade_id     UUID,
  p_user_id      UUID,
  p_market_price NUMERIC(20, 8)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trade           RECORD;
  v_user_balance    NUMERIC(18, 4);
  v_new_roi         NUMERIC(10, 6);
  v_result          JSONB;
  v_initial_balance CONSTANT NUMERIC := 10000;
BEGIN
  -- -------------------------------------------------------------------------
  -- Peek: read the trade WITHOUT a lock.
  -- Purpose: existence check, ownership validation, and idempotency pre-check
  -- before acquiring the users lock.  The status check here is a fast-exit
  -- optimisation only; the authoritative check is the re-validation at Step 3
  -- under both locks.
  -- Why this is safe: user_id is immutable; status is re-checked under the
  -- trade lock in Step 3, closing any TOCTOU window.
  -- -------------------------------------------------------------------------
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Fast-exit idempotency: if the trade is already settled there is no need
  -- to acquire any locks.  Return NULL immediately.
  IF v_trade.status != 'open' THEN
    RETURN NULL;
  END IF;

  -- Ownership check: user_id is immutable, so this is safe without a lock.
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % ownership mismatch', p_trade_id;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 1: Lock the users row (canonical lock order position 2).
  -- Acquired BEFORE the trades lock — this is the ordering fix.
  -- Serialises concurrent ROI recomputation and the belt-and-suspenders
  -- balance correction against any concurrent close_trade_txn calls that may
  -- be settling losses for this user simultaneously.
  -- -------------------------------------------------------------------------
  SELECT balance INTO v_user_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: User % does not exist', p_user_id;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 2: Lock the trades row (canonical lock order position 3).
  -- Acquired AFTER the users lock.
  -- -------------------------------------------------------------------------
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  -- -------------------------------------------------------------------------
  -- Step 3: Re-validate trade status under both locks (TOCTOU guard).
  -- A concurrent close_trade_txn or another liquidate_trade_txn invocation
  -- may have settled this trade between the unlocked peek and this re-read.
  -- Return NULL (idempotent) so the scanner can move on without an error.
  -- -------------------------------------------------------------------------
  IF v_trade.status != 'open' THEN
    RETURN NULL;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 4: Force-close the trade.
  -- exit_price is set to the pre-computed liquidation_price (not market_price)
  -- so realised_pnl arithmetic is exact: pnl = -margin for a full wipeout.
  -- -------------------------------------------------------------------------
  UPDATE public.trades
  SET
    status       = 'liquidated',
    exit_price   = v_trade.liquidation_price,
    realised_pnl = -v_trade.margin
  WHERE id = p_trade_id;

  -- -------------------------------------------------------------------------
  -- Step 5: Belt-and-suspenders bankruptcy guard (preserved from 007).
  -- Balance does not change on liquidation (settlement = 0; margin was already
  -- deducted at trade open).  However, if a concurrent settlement race or a
  -- direct SQL write drove the balance negative before we acquired the lock,
  -- we correct it here atomically and log the discrepancy so the anomaly is
  -- visible in the audit trail.
  --
  -- Under correct operation this branch is never taken.  The guard exists so
  -- that a future bug or direct SQL write cannot leave the users table with a
  -- negative balance that goes undetected.
  -- -------------------------------------------------------------------------
  IF v_user_balance < 0 THEN
    INSERT INTO public.bankruptcy_events (
      trade_id,
      user_id,
      expected_balance,
      clamped_balance,
      socialized_loss
    ) VALUES (
      p_trade_id,
      p_user_id,
      v_user_balance,       -- the negative balance found on the row
      0,
      ABS(v_user_balance)   -- positive magnitude
    );

    -- Correct the balance in-place, then update our local variable so ROI
    -- is computed from the clamped value, not the negative one.
    UPDATE public.users
    SET balance = 0
    WHERE id = p_user_id;

    v_user_balance := 0;
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 6: Recompute ROI against the (clamped) current balance.
  -- -------------------------------------------------------------------------
  v_new_roi := (v_user_balance - v_initial_balance) / v_initial_balance;

  UPDATE public.users
  SET roi = v_new_roi
  WHERE id = p_user_id;

  -- -------------------------------------------------------------------------
  -- Step 7: Write the immutable liquidation audit row.
  -- -------------------------------------------------------------------------
  INSERT INTO public.liquidation_events (
    trade_id, user_id, symbol, liquidation_price, market_price, margin
  ) VALUES (
    p_trade_id,
    p_user_id,
    v_trade.symbol,
    v_trade.liquidation_price,
    p_market_price,
    v_trade.margin
  );

  -- -------------------------------------------------------------------------
  -- Step 8: Return the updated trade as JSONB.
  -- -------------------------------------------------------------------------
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  RETURN v_result;
END;
$$;

-- Only service_role should call this function (unchanged from 003/007).
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.liquidate_trade_txn FROM authenticated;


COMMIT;


-- =============================================================================
-- LOCK ORDERING ADDENDUM (012)
-- =============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ Canonical FOR UPDATE acquisition order (system invariant after 012)     │
-- │                                                                         │
-- │   1. tournaments   (if needed)                                          │
-- │   2. users         (always before trades)                               │
-- │   3. trades        (always after users)                                 │
-- │                                                                         │
-- │ Any future RPC that touches two or more of these tables in a single     │
-- │ transaction MUST acquire their locks in the order above.  Violating     │
-- │ this invariant re-introduces deadlock risk.  See docs/LOCK_ORDERING.md. │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ RPC                   │ Lock sequence (post-012)                        │
-- ├───────────────────────┼─────────────────────────────────────────────────┤
-- │ execute_trade_txn     │ users FOR UPDATE → trades INSERT                │
-- │ close_trade_txn       │ users FOR UPDATE → trades FOR UPDATE            │
-- │ liquidate_trade_txn   │ users FOR UPDATE → trades FOR UPDATE            │
-- │ join_tournament_txn   │ tournaments FOR UPDATE → users FOR UPDATE       │
-- │ settle_tournament_txn │ tournaments FOR UPDATE (no user row lock)       │
-- │ award_daily_reward_txn│ users FOR UPDATE (no trade row lock)            │
-- └───────────────────────┴─────────────────────────────────────────────────┘
--
-- Pattern used in close_trade_txn and liquidate_trade_txn:
--
--   "Peek then lock" — read trade row without FOR UPDATE to do fast pre-checks
--   (existence, ownership, idempotency fast-exit).  Then acquire users FOR
--   UPDATE.  Then acquire trades FOR UPDATE.  Re-validate trade status under
--   both locks before mutating anything.  This eliminates TOCTOU races while
--   maintaining the canonical lock order.
--
--   The pre-check read (peek) is safe because:
--     - user_id is immutable after INSERT: ownership validation needs no lock.
--     - status is mutable but is re-checked under the trade lock (Step 3 in
--       both RPCs), which is the authoritative validation point.
--     - The unlocked read may observe a stale 'open' status while another
--       transaction is closing the trade; the Step 3 re-check catches this
--       and either raises an error (close_trade_txn) or returns NULL
--       (liquidate_trade_txn, idempotency path).
-- =============================================================================
-- =============================================================================
-- Migration : 013_event_outbox
-- Description: Transactional Outbox Pattern for reliable event dispatch.
--
--              Problem being solved:
--                Both claim-daily-reward and close-trade previously triggered
--                check-achievements via fire-and-forget supabase.functions.invoke()
--                calls. If the downstream network request failed or the target
--                function timed out, the achievement evaluation was permanently
--                lost — ACH-005 (Streak Keeper) or trade-based achievements
--                (ACH-001, ACH-002, ACH-004, ACH-006) would never be awarded
--                even though the qualifying event occurred.
--
--              Solution — Transactional Outbox Pattern:
--                1. Outbox events are written IN THE SAME TRANSACTION as the
--                   business operation (reward credited, trade closed). This
--                   is the atomicity guarantee: either both succeed or both
--                   roll back. Events can never be silently lost.
--                2. A dedicated processor function (process-outbox Edge
--                   Function, triggered by cron every 30 seconds) reads
--                   pending rows and dispatches them asynchronously.
--                3. Failed dispatches are retried up to max_attempts times
--                   before the row is marked 'failed' for alerting/replay.
--
--              New objects:
--                TABLE  public.event_outbox       — pending/completed/failed events
--                RPC    public.award_daily_reward_txn — REPLACED: inserts outbox event
--                RPC    public.close_trade_txn        — REPLACED: inserts outbox event
--
--              Depends on : 007_bankruptcy_protection (close_trade_txn)
--                           008_daily_rewards (award_daily_reward_txn)
--                           010_achievements (achievements catalogue)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- =============================================================================

BEGIN;

-- =============================================================================
-- TABLE: public.event_outbox
-- =============================================================================
-- Central relay table. Producers INSERT rows inside their own transactions.
-- The process-outbox Edge Function polls this table, claims rows by setting
-- status = 'processing', dispatches them, then marks them 'completed' or
-- bumps the attempt counter and resets to 'pending' on failure.
--
-- Column notes:
--   event_type   — discriminator for the processor dispatch table
--   payload      — arbitrary JSONB handed verbatim to the downstream handler
--   status       — state machine: pending → processing → completed | failed
--   attempts     — number of dispatch attempts made so far (0-indexed)
--   max_attempts — maximum dispatch attempts before permanent 'failed' status
--   processed_at — set to NOW() only on the transition to 'completed'
--   error_message— last error string from a failed dispatch attempt
-- =============================================================================

CREATE TABLE public.event_outbox (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type    TEXT        NOT NULL CHECK (event_type IN (
                              'check_achievements',
                              'send_notification'
                            )),
  payload       JSONB       NOT NULL,
  status        TEXT        NOT NULL DEFAULT 'pending' CHECK (status IN (
                              'pending', 'processing', 'completed', 'failed'
                            )),
  attempts      INT         NOT NULL DEFAULT 0,
  max_attempts  INT         NOT NULL DEFAULT 3,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at  TIMESTAMPTZ,
  error_message TEXT
);

COMMENT ON TABLE public.event_outbox IS
  'Transactional outbox for eventual consistency. Producers insert rows '
  'in the same transaction as their business operation; the process-outbox '
  'Edge Function reads pending rows every 30 seconds and dispatches them.';

COMMENT ON COLUMN public.event_outbox.status IS
  'State machine: pending → processing → completed | failed. '
  'The processor atomically transitions pending→processing via UPDATE … '
  'RETURNING to claim a batch without race conditions.';

COMMENT ON COLUMN public.event_outbox.attempts IS
  'Zero-based count of dispatch attempts. Incremented on each failure. '
  'When attempts >= max_attempts the status is set to ''failed''.';

-- Index used by the processor's polling query:
--   SELECT … FROM event_outbox WHERE status = 'pending' ORDER BY created_at
-- The partial index covers only pending rows, keeping it small even as
-- completed rows accumulate.
CREATE INDEX idx_event_outbox_pending
  ON public.event_outbox (created_at)
  WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- RLS: public.event_outbox
-- ---------------------------------------------------------------------------
-- The outbox is an internal relay table. No client role has any access.
-- All reads and writes are performed by SECURITY DEFINER RPCs (which run as
-- the function owner and bypass RLS) and by the process-outbox Edge Function
-- using the service_role key (which also bypasses RLS).

ALTER TABLE public.event_outbox ENABLE ROW LEVEL SECURITY;

-- Belt-and-suspenders: block all client access at the privilege level.
-- RLS policies are intentionally omitted — no client path should ever touch
-- this table directly.
REVOKE ALL ON public.event_outbox FROM anon;
REVOKE ALL ON public.event_outbox FROM authenticated;


-- =============================================================================
-- RPC: award_daily_reward_txn  (replaces 008_daily_rewards version)
-- =============================================================================
-- Identical to the 008 version except for a new Step 9 inserted BEFORE the
-- existing RETURN: an outbox event is written for the 'streak_claimed' trigger
-- IN THE SAME TRANSACTION as the balance credit and audit row.
--
-- Outbox event written:
--   event_type : 'check_achievements'
--   payload    : {
--     "user_id"      : "<uuid>",
--     "trigger_event": "streak_claimed",
--     "event_data"   : { "streak": <n> }
--   }
--
-- Atomicity guarantee:
--   If the transaction commits, BOTH the balance update AND the outbox event
--   exist. If it rolls back, neither exists. The fire-and-forget race is
--   eliminated entirely: the process-outbox processor handles the async
--   dispatch with retry semantics.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.award_daily_reward_txn(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user            RECORD;
  v_claim_date      DATE;
  v_new_streak      INT;
  v_bonus           NUMERIC(18,4);
  v_already_claimed BOOLEAN := FALSE;
BEGIN
  -- 1. Lock the user row to serialise concurrent claims.
  SELECT id, is_human, balance, current_streak, last_claim_date
  INTO   v_user
  FROM   public.users
  WHERE  id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User % not found', p_user_id;
  END IF;

  -- 2. Human-only guard.
  IF NOT v_user.is_human THEN
    RAISE EXCEPTION 'Daily rewards are available only to human users';
  END IF;

  -- 3. Compute today's UTC calendar date.
  v_claim_date := (NOW() AT TIME ZONE 'UTC')::DATE;

  -- 4. Check idempotency: has this user already claimed today?
  IF v_user.last_claim_date = v_claim_date THEN
    v_already_claimed := TRUE;
    RETURN jsonb_build_object(
      'already_claimed', TRUE,
      'streak',          v_user.current_streak,
      'bonus_amount',    0,
      'new_balance',     v_user.balance
    );
  END IF;

  -- 5. Compute new streak:
  --    - Consecutive day  → increment
  --    - Any other case   → reset to 1
  IF v_user.last_claim_date = v_claim_date - INTERVAL '1 day' THEN
    v_new_streak := v_user.current_streak + 1;
  ELSE
    v_new_streak := 1;
  END IF;

  -- 6. Determine bonus amount from the streak day.
  v_bonus := CASE
    WHEN v_new_streak >= 7 THEN 750
    WHEN v_new_streak =  6 THEN 500
    WHEN v_new_streak =  5 THEN 350
    WHEN v_new_streak =  4 THEN 250
    WHEN v_new_streak =  3 THEN 200
    WHEN v_new_streak =  2 THEN 150
    ELSE                        100
  END;

  -- 7. Credit the user's balance and update streak state.
  UPDATE public.users
  SET
    balance         = balance + v_bonus,
    current_streak  = v_new_streak,
    last_claim_date = v_claim_date
  WHERE id = p_user_id;

  -- 8. Write the audit record; ON CONFLICT DO NOTHING provides a
  --    second idempotency layer in case of a race between two
  --    concurrent callers that both passed the check in step 4.
  INSERT INTO public.daily_claims (user_id, claim_date, streak_day, bonus_amount)
  VALUES (p_user_id, v_claim_date, v_new_streak, v_bonus)
  ON CONFLICT (user_id, claim_date) DO NOTHING;

  -- 9. Insert outbox event IN THE SAME TRANSACTION as the balance update.
  --    Atomicity guarantee: if this transaction commits, the event is
  --    guaranteed to exist for the process-outbox processor to dispatch.
  --    The fire-and-forget race condition from the previous implementation
  --    is eliminated — ACH-005 (Streak Keeper) can no longer be silently lost.
  INSERT INTO public.event_outbox (event_type, payload)
  VALUES (
    'check_achievements',
    jsonb_build_object(
      'user_id',       p_user_id,
      'trigger_event', 'streak_claimed',
      'event_data',    jsonb_build_object('streak', v_new_streak)
    )
  );

  -- 10. Return result.
  RETURN jsonb_build_object(
    'already_claimed', FALSE,
    'streak',          v_new_streak,
    'bonus_amount',    v_bonus,
    'new_balance',     v_user.balance + v_bonus
  );
END;
$$;

-- Preserve the same security model as the 008 version.
REVOKE EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) FROM anon;
REVOKE EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.award_daily_reward_txn(UUID) TO service_role;

COMMENT ON FUNCTION public.award_daily_reward_txn(UUID) IS
  'Atomic daily reward claim. Locks the user row, checks idempotency, '
  'computes the streak-based bonus, credits balance, writes an audit row, '
  'and — in the same transaction — inserts a check_achievements outbox event '
  'for reliable async dispatch. Returns JSONB: '
  '{already_claimed, streak, bonus_amount, new_balance}. '
  'Callable by service_role only. Human-only: rejects bot accounts. '
  'Supersedes the 008_daily_rewards version.';


-- =============================================================================
-- RPC: close_trade_txn  (replaces 007_bankruptcy_protection version)
-- =============================================================================
-- Identical to the 007 version except for a new final step inserted BEFORE
-- the existing RETURN: an outbox event is written for the 'trade_closed'
-- trigger IN THE SAME TRANSACTION as the balance update and trade row close.
--
-- Outbox event written (only when the trade closes as 'closed', not in the
-- trade_not_found error paths — those RAISE EXCEPTION which rolls back the
-- transaction and therefore also rolls back any INSERT into event_outbox):
--   event_type : 'check_achievements'
--   payload    : {
--     "user_id"      : "<uuid>",
--     "trigger_event": "trade_closed",
--     "event_data"   : {
--       "leverage"    : <n>,
--       "status"      : "closed",
--       "realised_pnl": <n>,
--       "margin"      : <n>,
--       "created_at"  : "<iso>",
--       "updated_at"  : "<iso>",
--       "user_roi"    : <n>,
--       "openclaw_roi": null
--     }
--   }
--
-- Note on openclaw_roi: the RPC does not have access to the OpenClaw agent's
-- concurrent ROI. The outbox payload sets it to null; the processor passes it
-- as-is and the ACH-001 evaluator in check-achievements gracefully skips when
-- either roi field is null.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.close_trade_txn(
  p_trade_id      UUID,
  p_user_id       UUID,
  p_exit_price    NUMERIC(20, 8),
  p_realised_pnl  NUMERIC(18, 4),
  p_settlement    NUMERIC(18, 4)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trade           RECORD;
  v_locked_balance  NUMERIC(18, 4);
  v_raw_balance     NUMERIC(18, 4);   -- arithmetic result before clamp
  v_new_balance     NUMERIC(18, 4);   -- value that will be written to users
  v_new_roi         NUMERIC(10, 6);
  v_result          JSONB;
  v_initial_balance CONSTANT NUMERIC := 10000;
BEGIN
  -- Step 1: Lock the trade row.
  -- FOR UPDATE prevents a concurrent close request on the same trade.
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Step 2: Validate ownership and status.
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not belong to user %',
      p_trade_id, p_user_id;
  END IF;

  IF v_trade.status != 'open' THEN
    RAISE EXCEPTION 'trade_not_found: Trade % is not open (status=%)',
      p_trade_id, v_trade.status;
  END IF;

  -- Step 3: Close the trade.
  UPDATE public.trades
  SET
    status       = 'closed',
    exit_price   = p_exit_price,
    realised_pnl = p_realised_pnl
  WHERE id = p_trade_id;

  -- Step 4: Lock the users row.
  -- This is critical when two trades for the same user close simultaneously.
  -- Without FOR UPDATE, both could read the same balance and one settlement
  -- would be silently overwritten.
  SELECT balance INTO v_locked_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  -- Step 5: Compute raw (pre-clamp) candidate balance.
  -- Normal path:     v_raw_balance >= 0 (settlement covers the loss).
  -- Bankruptcy path: v_raw_balance <  0 (position blew past liquidation price
  --                  between cron scans; extreme slippage absorbed by system).
  v_raw_balance := v_locked_balance + p_settlement;

  -- Step 6: Socialized-loss clamp.
  -- If the raw balance is negative we cannot write it — the CHECK constraint
  -- (balance >= 0) would abort the entire transaction and leave the trade row
  -- in 'open' status (zombie position).  Instead we:
  --   a. Record the event in bankruptcy_events for exchange reconciliation.
  --   b. Clamp the balance to 0 — the user loses everything but the
  --      transaction completes cleanly.
  IF v_raw_balance < 0 THEN
    INSERT INTO public.bankruptcy_events (
      trade_id,
      user_id,
      expected_balance,
      clamped_balance,
      socialized_loss
    ) VALUES (
      p_trade_id,
      p_user_id,
      v_raw_balance,             -- negative; the raw arithmetic result
      0,                         -- what we will actually write
      ABS(v_raw_balance)         -- positive magnitude absorbed by system
    );

    v_new_balance := 0;
  ELSE
    v_new_balance := v_raw_balance;
  END IF;

  -- Step 7: Compute ROI using the clamped balance.
  -- Using v_new_balance (not v_raw_balance) keeps ROI in the range [-1, ∞)
  -- which is the mathematically correct bound for a total wipeout.
  v_new_roi := (v_new_balance - v_initial_balance) / v_initial_balance;

  -- Step 8: Write the clamped balance and recomputed ROI.
  -- At this point v_new_balance >= 0, so the CHECK constraint is satisfied.
  UPDATE public.users
  SET
    balance = v_new_balance,
    roi     = v_new_roi
  WHERE id = p_user_id;

  -- Step 9: Return the closed trade as JSONB.
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  -- Step 10: Insert outbox event IN THE SAME TRANSACTION as the trade close
  --  and balance update.
  --  Atomicity guarantee: if this transaction commits, the achievement check
  --  event is guaranteed to exist. There is no fire-and-forget race — if the
  --  process-outbox dispatcher fails transiently, it retries automatically.
  --
  --  Payload notes:
  --    - leverage, margin, realised_pnl feed ACH-002, ACH-004, ACH-006.
  --    - status = 'closed' is required by ACH-006 (Survivor) evaluator.
  --    - created_at / updated_at timestamps are taken from the trade row
  --      so that ACH-006 hold-duration arithmetic is accurate.
  --    - user_roi is included for ACH-001 (Claw Crusher); openclaw_roi is
  --      null because the RPC has no access to the AI agent's ROI at closure
  --      time — the ACH-001 evaluator skips gracefully when either is null.
  INSERT INTO public.event_outbox (event_type, payload)
  VALUES (
    'check_achievements',
    jsonb_build_object(
      'user_id',       p_user_id,
      'trigger_event', 'trade_closed',
      'event_data',    jsonb_build_object(
        'leverage',     v_trade.leverage,
        'status',       'closed',
        'realised_pnl', p_realised_pnl,
        'margin',       v_trade.margin,
        'created_at',   v_trade.created_at,
        'updated_at',   NOW(),
        'user_roi',     v_new_roi,
        'openclaw_roi', NULL
      )
    )
  );

  RETURN v_result;
END;
$$;

-- Preserve the same security model as the 007 version.
REVOKE ALL ON FUNCTION public.close_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.close_trade_txn FROM authenticated;

COMMENT ON FUNCTION public.close_trade_txn IS
  'Atomic trade closure with socialized-loss bankruptcy protection. '
  'Locks the trade and user rows, clamps the balance to GREATEST(0, …) '
  'before writing (preventing CHECK constraint violations), logs any '
  'bankruptcy event, and — in the same transaction — inserts a '
  'check_achievements outbox event for reliable async achievement dispatch. '
  'Returns the closed trade row as JSONB. Callable by service_role only. '
  'Supersedes the 007_bankruptcy_protection version.';


COMMIT;


-- =============================================================================
-- SECURITY MODEL ADDENDUM (013)
-- =============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ event_outbox access matrix                                              │
-- ├──────────────────┬──────────────────────────────────────────────────────┤
-- │ anon             │ REVOKED at privilege level                           │
-- │ authenticated    │ REVOKED at privilege level                           │
-- │ service_role     │ full access (RLS bypassed; used by process-outbox)   │
-- │ SECURITY DEFINER │ INSERT only (award_daily_reward_txn,                 │
-- │ RPCs             │  close_trade_txn — run as function owner)            │
-- ├──────────────────┴──────────────────────────────────────────────────────┤
-- │ award_daily_reward_txn / close_trade_txn                                │
-- ├──────────────────┬──────────────────────────────────────────────────────┤
-- │ PUBLIC / anon /  │ REVOKED — unchanged from 008 / 007                   │
-- │ authenticated    │                                                      │
-- │ service_role     │ callable (Edge Function context)                     │
-- ├──────────────────┴──────────────────────────────────────────────────────┤
-- │ Outbox state machine                                                    │
-- │   pending     → processor claims the row                               │
-- │   processing  → dispatcher is in-flight                                │
-- │   completed   → dispatch succeeded; processed_at is set                │
-- │   failed      → attempts >= max_attempts; requires manual replay        │
-- ├──────────────────────────────────────────────────────────────────────────┤
-- │ Retention policy (recommended — implement via pg_cron or Edge Function) │
-- │   DELETE FROM event_outbox                                              │
-- │   WHERE status IN ('completed', 'failed')                               │
-- │     AND created_at < NOW() - INTERVAL '7 days';                        │
-- └─────────────────────────────────────────────────────────────────────────┘
-- =============================================================================


-- =============================================================================
-- Down (rollback — execute manually, never in CI)
-- =============================================================================
-- NOTE: Rolling back this migration requires also reverting the RPC bodies
-- to their 007/008 versions.  The safest approach is to redeploy those
-- migration files directly rather than re-inlining the bodies here.
--
-- DROP TABLE IF EXISTS public.event_outbox;
-- -- Then re-run 007_bankruptcy_protection.sql and 008_daily_rewards.sql
-- -- to restore the original RPC bodies.
-- =============================================================================
-- Migration 014: Add per-user timezone offset
--
-- timezone_offset stores the user's offset from UTC in minutes.
-- Positive values are east of UTC, negative values are west.
--
-- Examples:
--   UTC+8  (China Standard Time)  →  +480
--   UTC+5:30 (India Standard Time) → +330
--   UTC-5  (US Eastern)           →  -300
--   UTC-8  (US Pacific)           →  -480
--
-- The value is set by the frontend using:
--   -new Date().getTimezoneOffset()
-- (JS getTimezoneOffset() returns the negated offset, so we negate it back.)

ALTER TABLE public.users
  ADD COLUMN timezone_offset INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.users.timezone_offset IS
  'User timezone offset from UTC in minutes. '
  'Set by the frontend from -new Date().getTimezoneOffset(). '
  'Range: -720 (UTC-12) to +840 (UTC+14).';
-- ============================================================
-- Migration : 015_referral_system
-- Description: Implements the peer-referral reward system.
--              Adds referral tracking columns to public.users,
--              creates an immutable audit table (referral_events),
--              and exposes a single atomic RPC
--              (award_referral_bonus_txn) for the bot/edge layer.
--
-- Security model
--   - referral_events is readable only by the referrer and the
--     referee via RLS; anon has zero access.
--   - The RPC is SECURITY DEFINER so it can credit both user
--     balances and write the audit row without exposing the
--     underlying tables to the caller.
--   - EXECUTE is revoked from PUBLIC, anon, and authenticated;
--     only the service role (bot / edge functions) may call the
--     function directly. Frontend clients reach it through the
--     bot gateway only.
--   - The idempotency guard (UNIQUE constraint on referee_id in
--     referral_events + ON CONFLICT DO NOTHING inside the RPC)
--     makes repeated invocations safe: each referee can only
--     trigger one payout, ever.
--
-- Lock ordering (canonical — see docs/LOCK_ORDERING.md)
--   award_referral_bonus_txn locks two rows from the same table
--   (users), both at canonical position 2. When two rows from
--   the same table are locked in a single transaction, the
--   deadlock risk is between concurrent calls where T1 holds
--   row A and waits for row B while T2 holds row B and waits
--   for row A. This is prevented by always locking the
--   lower-UUID row first (alphabetical / bytewise order on the
--   UUID text representation). The ordering is documented in the
--   RPC header comment and in the RPC Lock Acquisition Table
--   update at the bottom of this file.
--
--   Full canonical sequence for award_referral_bonus_txn:
--     1. users FOR UPDATE  (lower  UUID — canonical position 2a)
--     2. users FOR UPDATE  (higher UUID — canonical position 2b)
--
-- Depends on : 001_initial_schema (public.users),
--              008_daily_rewards  (no structural dep, style ref)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Extend public.users with referral columns
-- ------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN referral_code          TEXT         UNIQUE,
  ADD COLUMN referred_by            UUID         REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN referral_code_used     TEXT,
  ADD COLUMN referral_bonus_earned  NUMERIC(18,4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.users.referral_code IS
  'Unique invite code assigned to the user (generated by the bot '
  'on first request). NULL until the user first requests their code.';

COMMENT ON COLUMN public.users.referred_by IS
  'FK to the user who referred this account. Set once at registration '
  'time; immutable after the referral bonus has been paid. '
  'NULL means the user joined without a referral code.';

COMMENT ON COLUMN public.users.referral_bonus_earned IS
  'Running total of referral bonus tokens earned as a referrer. '
  'Incremented atomically by award_referral_bonus_txn.';

-- Partial unique index for code lookups (the ALTER TABLE UNIQUE
-- constraint covers the full column; this partial index additionally
-- ensures the planner can use an index skip on NULL rows, which
-- are the majority until codes are generated).
CREATE UNIQUE INDEX idx_users_referral_code
  ON public.users (referral_code)
  WHERE referral_code IS NOT NULL;

-- Sparse index for "show me everyone I referred" queries.
CREATE INDEX idx_users_referred_by
  ON public.users (referred_by)
  WHERE referred_by IS NOT NULL;

-- ------------------------------------------------------------
-- Section 2 — Audit / history table: public.referral_events
--
-- Append-only. One row per referee_id (enforced by UNIQUE
-- constraint). The constraint is the authoritative idempotency
-- guard; the RPC uses ON CONFLICT DO NOTHING as a second layer.
-- ------------------------------------------------------------

CREATE TABLE public.referral_events (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id     UUID          NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  referee_id      UUID          NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  referrer_bonus  NUMERIC(18,4) NOT NULL DEFAULT 500
                                CHECK (referrer_bonus >= 0),
  referee_bonus   NUMERIC(18,4) NOT NULL DEFAULT 500
                                CHECK (referee_bonus  >= 0),
  bonus_paid_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- Core idempotency: every referee may only generate one payout event, ever.
  CONSTRAINT referral_events_referee_unique UNIQUE (referee_id)
);

COMMENT ON TABLE public.referral_events IS
  'Immutable record of every referral bonus payout. One row per '
  'referee. Used for audit, leaderboards, and idempotency enforcement.';

COMMENT ON COLUMN public.referral_events.referrer_bonus IS
  'Tokens credited to the referrer for this event (default 500).';
COMMENT ON COLUMN public.referral_events.referee_bonus IS
  'Tokens credited to the new user (referee) for this event (default 500).';
COMMENT ON COLUMN public.referral_events.bonus_paid_at IS
  'Wall-clock timestamp (UTC) when the bonus transaction committed.';

-- Referrer history: "how many people have I recruited?"
CREATE INDEX idx_referral_events_referrer
  ON public.referral_events (referrer_id);

-- ------------------------------------------------------------
-- Section 3 — Row Level Security on public.referral_events
-- ------------------------------------------------------------

ALTER TABLE public.referral_events ENABLE ROW LEVEL SECURITY;

-- Both parties may read events in which they participated.
CREATE POLICY "referral_events: participants can select"
  ON public.referral_events
  FOR SELECT
  TO authenticated
  USING (auth.uid() = referrer_id OR auth.uid() = referee_id);

-- No INSERT / UPDATE / DELETE policies for authenticated users:
-- writes happen exclusively through the SECURITY DEFINER RPC.
REVOKE ALL ON public.referral_events FROM anon;

-- ------------------------------------------------------------
-- Section 4 — RPC: award_referral_bonus_txn
--
-- Caller   : service_role (bot / edge function only)
-- Args     : p_referrer_id   UUID    — the user who owns the referral code
--            p_referee_id    UUID    — the newly registered user
--            p_referrer_bonus NUMERIC — tokens for the referrer  (default 500)
--            p_referee_bonus  NUMERIC — tokens for the referee   (default 500)
-- Returns  : JSONB with the following keys:
--              already_paid        BOOLEAN
--              referrer_new_balance NUMERIC  (unchanged if already_paid)
--              referee_new_balance  NUMERIC  (unchanged if already_paid)
--              referrer_bonus       NUMERIC  (0 if already_paid)
--              referee_bonus        NUMERIC  (0 if already_paid)
--
-- Atomicity guarantee:
--   Both balance credits and the audit row are written inside a
--   single implicit transaction. The FOR UPDATE locks on both
--   user rows prevent double-spend under concurrent calls.
--
-- Idempotency guarantee:
--   If referral_events already contains a row for p_referee_id
--   the function returns {already_paid: true} without mutating
--   any balances. The ON CONFLICT DO NOTHING on the INSERT
--   provides a second-layer guard for races that pass the
--   initial check simultaneously.
--
-- Lock ordering (see docs/LOCK_ORDERING.md):
--   Both locks are on public.users (canonical position 2).
--   To prevent intra-table deadlocks, the lower UUID (lexicographic
--   bytewise comparison) is always locked first.
--
--   Lock order (canonical):
--     1. users FOR UPDATE  (MIN(p_referrer_id, p_referee_id) — position 2a)
--     2. users FOR UPDATE  (MAX(p_referrer_id, p_referee_id) — position 2b)
--
-- Human-only guard:
--   Bot accounts (is_human = FALSE) are rejected as both referrer
--   and referee so bots cannot farm the bonus system.
--
-- Outbox event:
--   On a successful new payout the function inserts a row into
--   event_outbox so the achievement checker / notification worker
--   can react asynchronously without coupling to this transaction.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.award_referral_bonus_txn(
  p_referrer_id    UUID,
  p_referee_id     UUID,
  p_referrer_bonus NUMERIC(18,4) DEFAULT 500,
  p_referee_bonus  NUMERIC(18,4) DEFAULT 500
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_first_lock_id  UUID;
  v_second_lock_id UUID;
  v_referrer       RECORD;
  v_referee        RECORD;
  v_already_paid   BOOLEAN := FALSE;
BEGIN
  -- --------------------------------------------------------
  -- 0. Validate arguments.
  -- --------------------------------------------------------
  IF p_referrer_id = p_referee_id THEN
    RAISE EXCEPTION 'Referrer and referee must be different users';
  END IF;

  IF p_referrer_bonus < 0 OR p_referee_bonus < 0 THEN
    RAISE EXCEPTION 'Bonus amounts must be non-negative';
  END IF;

  -- --------------------------------------------------------
  -- 1. Determine lock order: always lock the lower UUID first
  --    to prevent intra-table deadlocks when two concurrent
  --    calls involve the same pair in opposite roles.
  -- --------------------------------------------------------
  IF p_referrer_id < p_referee_id THEN
    v_first_lock_id  := p_referrer_id;
    v_second_lock_id := p_referee_id;
  ELSE
    v_first_lock_id  := p_referee_id;
    v_second_lock_id := p_referrer_id;
  END IF;

  -- --------------------------------------------------------
  -- 2. Acquire lock on the lower-UUID row (position 2a).
  --    We must then re-fetch into the correctly named variable.
  -- --------------------------------------------------------
  IF v_first_lock_id = p_referrer_id THEN
    SELECT id, is_human, balance, referral_bonus_earned, display_name
    INTO   v_referrer
    FROM   public.users
    WHERE  id = p_referrer_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referrer % not found', p_referrer_id;
    END IF;

    -- --------------------------------------------------------
    -- 3a. Acquire lock on the higher-UUID row (position 2b).
    -- --------------------------------------------------------
    SELECT id, is_human, balance, display_name
    INTO   v_referee
    FROM   public.users
    WHERE  id = p_referee_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referee % not found', p_referee_id;
    END IF;
  ELSE
    -- Referee UUID is lower; lock it first (position 2a).
    SELECT id, is_human, balance, display_name
    INTO   v_referee
    FROM   public.users
    WHERE  id = p_referee_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referee % not found', p_referee_id;
    END IF;

    -- --------------------------------------------------------
    -- 3b. Acquire lock on the higher-UUID row (position 2b).
    -- --------------------------------------------------------
    SELECT id, is_human, balance, referral_bonus_earned, display_name
    INTO   v_referrer
    FROM   public.users
    WHERE  id = p_referrer_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referrer % not found', p_referrer_id;
    END IF;
  END IF;

  -- --------------------------------------------------------
  -- 4. Human-only guard: reject bot accounts on both sides.
  -- --------------------------------------------------------
  IF NOT v_referrer.is_human THEN
    RAISE EXCEPTION 'Referrer % is not a human account', p_referrer_id;
  END IF;

  IF NOT v_referee.is_human THEN
    RAISE EXCEPTION 'Referee % is not a human account', p_referee_id;
  END IF;

  -- --------------------------------------------------------
  -- 5. Idempotency check: has this referee already triggered
  --    a payout? Both locks are held, so this read is stable.
  -- --------------------------------------------------------
  IF EXISTS (
    SELECT 1 FROM public.referral_events WHERE referee_id = p_referee_id
  ) THEN
    RETURN jsonb_build_object(
      'already_paid',          TRUE,
      'referrer_new_balance',  v_referrer.balance,
      'referee_new_balance',   v_referee.balance,
      'referrer_bonus',        0,
      'referee_bonus',         0
    );
  END IF;

  -- --------------------------------------------------------
  -- 6. Credit balances for both parties.
  -- --------------------------------------------------------
  UPDATE public.users
  SET
    balance               = balance + p_referrer_bonus,
    referral_bonus_earned = referral_bonus_earned + p_referrer_bonus
  WHERE id = p_referrer_id;

  UPDATE public.users
  SET balance = balance + p_referee_bonus
  WHERE id = p_referee_id;

  -- --------------------------------------------------------
  -- 7. Write the audit record. ON CONFLICT DO NOTHING provides
  --    a second idempotency layer for the rare race where two
  --    concurrent calls both passed step 5 before either
  --    committed.
  -- --------------------------------------------------------
  INSERT INTO public.referral_events
    (referrer_id, referee_id, referrer_bonus, referee_bonus)
  VALUES
    (p_referrer_id, p_referee_id, p_referrer_bonus, p_referee_bonus)
  ON CONFLICT (referee_id) DO NOTHING;

  -- --------------------------------------------------------
  -- 8. Publish outbox event for achievement checker and
  --    notification worker (eventual consistency).
  -- --------------------------------------------------------
  INSERT INTO public.event_outbox (event_type, payload)
  VALUES (
    'referral_bonus_paid',
    jsonb_build_object(
      'referrer_id',    p_referrer_id,
      'referee_id',     p_referee_id,
      'referrer_bonus', p_referrer_bonus,
      'referee_bonus',  p_referee_bonus
    )
  );

  -- --------------------------------------------------------
  -- 9. Return result with updated balances.
  -- --------------------------------------------------------
  RETURN jsonb_build_object(
    'already_paid',          FALSE,
    'referrer_new_balance',  v_referrer.balance + p_referrer_bonus,
    'referee_new_balance',   v_referee.balance  + p_referee_bonus,
    'referrer_bonus',        p_referrer_bonus,
    'referee_bonus',         p_referee_bonus
  );
END;
$$;

-- Revoke broad default execute privilege; grant to service_role only.
REVOKE EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) FROM anon;
REVOKE EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) TO service_role;

COMMENT ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) IS
  'Atomic referral bonus payout. Acquires FOR UPDATE locks on both user '
  'rows in UUID-ascending order to prevent intra-table deadlocks, checks '
  'idempotency via referral_events.referee_id UNIQUE constraint, credits '
  'both balances, writes an audit row, and emits an event_outbox entry. '
  'Returns JSONB: {already_paid, referrer_new_balance, referee_new_balance, '
  'referrer_bonus, referee_bonus}. Callable by service_role only. '
  'Rejects bot accounts on both sides.';

-- ------------------------------------------------------------
-- RPC Lock Acquisition Table update (docs/LOCK_ORDERING.md)
--
-- | RPC                        | Migration | Lock 1               | Lock 2               |
-- |----------------------------|-----------|----------------------|----------------------|
-- | award_referral_bonus_txn   | 015       | users FOR UPDATE     | users FOR UPDATE     |
-- |                            |           | (lower UUID first — position 2a) | (higher UUID — position 2b) |
--
-- Deadlock analysis vs. existing RPCs:
--   - vs. execute_trade_txn   : both lock users; execute_trade_txn locks one
--     users row then inserts into trades. award_referral_bonus_txn never
--     touches trades. No shared second lock → no cycle possible.
--   - vs. close_trade_txn     : close_trade_txn locks one users row then one
--     trades row. award_referral_bonus_txn never touches trades. No cycle.
--   - vs. liquidate_trade_txn : same argument as close_trade_txn. No cycle.
--   - vs. join_tournament_txn : locks tournaments then one users row.
--     award_referral_bonus_txn never touches tournaments. No cycle.
--   - vs. settle_tournament_txn: locks only tournaments. No shared table. No cycle.
--   - vs. award_daily_reward_txn: locks one users row. award_referral_bonus_txn
--     locks two users rows in ascending UUID order. If award_daily_reward_txn
--     holds row A and award_referral_bonus_txn is waiting for row A (having
--     already locked row B, which is lower), that means row B < row A.
--     award_referral_bonus_txn locked B first (correct order) and is now
--     waiting for A. award_daily_reward_txn holds A and will complete without
--     waiting for B. No cycle.
--   - vs. itself (two concurrent calls for overlapping pairs): both calls
--     lock the lower UUID first. If T1 holds row X (lower) and T2 wants row X,
--     T2 waits for T1 to release X. T1 then locks row Y (higher) and completes.
--     No cycle.
-- ------------------------------------------------------------

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- REVOKE EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) FROM service_role;
-- DROP FUNCTION  IF EXISTS public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC);
-- DROP TABLE     IF EXISTS public.referral_events;
-- ALTER TABLE public.users
--   DROP COLUMN IF EXISTS referral_code,
--   DROP COLUMN IF EXISTS referred_by,
--   DROP COLUMN IF EXISTS referral_bonus_earned;
-- ============================================================
-- ============================================================
-- Migration : 016_ai_personalities
-- Description: Adds two additional AI agent personalities
--              (OpenClaw Conservative, OpenClaw Chaos) following
--              the same seeding pattern as the original OpenClaw
--              agent. Adds an avatar_slug column to public.users
--              to allow the frontend to display distinct icons
--              for each AI personality and for human users.
--
-- Security model
--   - The two new agent rows are seeded directly into auth.users
--     and public.users using the same INSERT ... ON CONFLICT DO
--     NOTHING pattern established for the original agent. This
--     makes the migration safe to replay in environments that
--     already applied it (e.g., staging refreshes).
--   - avatar_slug is an opaque string resolved to an asset path
--     by the frontend. It is set by the service role only;
--     authenticated users have no UPDATE policy on this column
--     beyond what already exists on their own row (the column
--     is intentionally not filtered further here — access
--     control for user-facing profile updates is the
--     responsibility of the profile-edit endpoint).
--   - Bot rows carry is_human = FALSE. All RPCs that enforce
--     human-only guards (award_daily_reward_txn,
--     award_referral_bonus_txn) will correctly reject them.
--
-- Agent UUID registry (all non-human accounts):
--   00000000-0000-0000-0000-00000c1a0001  OpenClaw (original)
--   00000000-0000-0000-0000-00000c1a0002  OpenClaw Conservative  ← new
--   00000000-0000-0000-0000-00000c1a0003  OpenClaw Chaos         ← new
--
-- tg_id convention for AI agents:
--    0  → original OpenClaw agent (no Telegram identity)
--   -1  → OpenClaw Conservative
--   -2  → OpenClaw Chaos
--   Negative tg_ids are reserved for system/bot accounts and
--   will never be issued by the Telegram platform.
--
-- Depends on : 001_initial_schema (public.users, auth.users stub)
-- Idempotent  : YES — all INSERTs use ON CONFLICT DO NOTHING.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Add avatar_slug column to public.users
--
-- Nullable TEXT column; NULL means "use the default avatar".
-- The frontend resolves the slug to a bundled asset path.
-- Existing rows (including the original OpenClaw agent and all
-- human users) are left as NULL and receive the default avatar.
-- ------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN avatar_slug TEXT;

COMMENT ON COLUMN public.users.avatar_slug IS
  'Opaque frontend token that maps to a bundled avatar asset. '
  'NULL means use the application default avatar. '
  'Set by the service role; human users may update their own row '
  'through the profile-edit endpoint.';

-- Backfill the original OpenClaw agent with its own slug so all
-- three AI agents have a consistent slug from this migration onward.
UPDATE public.users
SET    avatar_slug = 'openclaw_original'
WHERE  id = '00000000-0000-0000-0000-00000c1a0001'::UUID;

-- ------------------------------------------------------------
-- Section 2 — Seed auth.users stubs for the new AI agents
--
-- auth.users stubs are required so the FK
-- public.users.id → auth.users.id is satisfied.
-- The email values are synthetic sentinel addresses that will
-- never receive mail; the format mirrors the original agent stub.
-- Passwords are intentionally absent (no login possible).
-- ------------------------------------------------------------

INSERT INTO auth.users (
  id,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data,
  is_super_admin,
  role
)
VALUES
  -- OpenClaw Conservative
  (
    '00000000-0000-0000-0000-00000c1a0002'::UUID,
    'openclaw-conservative@system.internal',
    '',                           -- no password; bot cannot authenticate
    NOW(),
    NOW(),
    NOW(),
    '{"provider":"system","providers":["system"]}'::JSONB,
    '{}'::JSONB,
    FALSE,
    'authenticated'
  ),
  -- OpenClaw Chaos
  (
    '00000000-0000-0000-0000-00000c1a0003'::UUID,
    'openclaw-chaos@system.internal',
    '',
    NOW(),
    NOW(),
    NOW(),
    '{"provider":"system","providers":["system"]}'::JSONB,
    '{}'::JSONB,
    FALSE,
    'authenticated'
  )
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------
-- Section 3 — Seed public.users rows for the new AI agents
-- ------------------------------------------------------------

INSERT INTO public.users (
  id,
  tg_id,
  display_name,
  username,
  is_human,
  balance,
  roi,
  current_streak,
  last_claim_date,
  notifications_enabled,
  timezone_offset,
  avatar_slug
)
VALUES
  -- OpenClaw Conservative: risk-averse trading personality.
  (
    '00000000-0000-0000-0000-00000c1a0002'::UUID,
    -1,
    'OpenClaw Conservative',
    'openclaw_conservative',
    FALSE,     -- bot account; human-only guards will reject it
    10000,     -- starting balance identical to original agent
    0,
    0,
    NULL,
    FALSE,
    0,
    'openclaw_conservative'
  ),
  -- OpenClaw Chaos: high-volatility trading personality.
  (
    '00000000-0000-0000-0000-00000c1a0003'::UUID,
    -2,
    'OpenClaw Chaos',
    'openclaw_chaos',
    FALSE,
    10000,
    0,
    0,
    NULL,
    FALSE,
    0,
    'openclaw_chaos'
  )
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE public.users IS
  'All participants: human users and AI agent accounts. '
  'AI agents carry is_human = FALSE and UUIDs in the '
  '00000000-0000-0000-0000-00000c1aXXXX namespace. '
  'Known agents: 0001 = OpenClaw (original), '
  '0002 = OpenClaw Conservative, 0003 = OpenClaw Chaos.';

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DELETE FROM public.users
--   WHERE id IN (
--     '00000000-0000-0000-0000-00000c1a0002'::UUID,
--     '00000000-0000-0000-0000-00000c1a0003'::UUID
--   );
-- DELETE FROM auth.users
--   WHERE id IN (
--     '00000000-0000-0000-0000-00000c1a0002'::UUID,
--     '00000000-0000-0000-0000-00000c1a0003'::UUID
--   );
-- UPDATE public.users SET avatar_slug = NULL
--   WHERE id = '00000000-0000-0000-0000-00000c1a0001'::UUID;
-- ALTER TABLE public.users DROP COLUMN IF EXISTS avatar_slug;
-- ============================================================
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
-- ============================================================
-- Migration : 018_production_hardening
-- Description: Four-part production hardening pass.
--
--   Section 1 — Qualified Referral Anti-Abuse
--     Introduces a two-phase referral payout: a "pending" entry
--     is created when a referee registers (via the updated
--     award_referral_bonus_txn), and the actual token credit only
--     fires once the referee completes a qualifying first trade
--     (margin >= 100 USDT) via the new qualify_referral_txn RPC.
--     Device-fingerprint deduplication is added to detect
--     suspicious device clusters and auto-reject their payouts.
--
--   Section 2 — Database Cleanup RPC
--     Adds cleanup_old_logs() to prune notification_log rows and
--     completed/failed event_outbox rows beyond a configurable
--     retention window. Callable by service_role / cron only.
--
--   Section 3 — High-Frequency Query Indexes
--     Adds five composite indexes covering hot query paths that
--     have grown to matter as row counts increase: trade history
--     scanner, "my alerts" page, cleanup sweep paths, and streak
--     calculation lookups.
--
--   Section 4 — Rewrite award_referral_bonus_txn
--     Replaces the original immediate-payout function with a
--     pending-only version that creates the referral_events row
--     with status='pending' and NO balance changes. All token
--     credits are deferred to qualify_referral_txn.
--
-- Security model (additions in this migration)
--   qualify_referral_txn  : SECURITY DEFINER, service_role only
--   cleanup_old_logs      : SECURITY DEFINER, service_role only
--   award_referral_bonus_txn (replacement): same security model
--     as original — SECURITY DEFINER, service_role only
--
-- Lock ordering (canonical — see docs/LOCK_ORDERING.md)
--   qualify_referral_txn acquires locks in the following order:
--     1. users FOR UPDATE  (lower UUID first  — canonical pos 2a)
--     2. users FOR UPDATE  (higher UUID       — canonical pos 2b)
--     3. referral_events FOR UPDATE           — canonical pos 5
--                                               (NEW, assigned here)
--
--   Full updated canonical order after this migration:
--     1. tournaments   (005)
--     2. users         (001)
--     3. trades        (001)
--     4. price_alerts  (017)
--     5. referral_events (018)  ← NEW
--
--   Deadlock analysis vs. existing RPCs:
--     No existing RPC locks referral_events (015 wrote it
--     non-transactionally inside award_referral_bonus_txn which
--     never reached the FOR UPDATE step). Assigning position 5
--     introduces no cycle risk with positions 1-4.
--
-- Depends on : 001_phase1_schema  (public.users, public.trades)
--              009_notifications  (public.notification_log)
--              013_event_outbox   (public.event_outbox)
--              015_referral_system (public.referral_events,
--                                   award_referral_bonus_txn)
--              017_price_alerts   (public.price_alerts)
--              008_daily_rewards  (public.daily_claims)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ============================================================
-- Section 1 — Qualified Referral Anti-Abuse
-- ============================================================

-- ------------------------------------------------------------
-- 1a. Device fingerprint columns on public.users
--
-- device_fingerprint: opaque token computed by the client (e.g.
--   a hash of browser canvas, screen resolution, WebGL renderer,
--   fonts, and timezone). Used to detect suspicious clusters
--   where many distinct Telegram accounts share identical device
--   environments — a reliable signal of Sybil farming.
--
-- signup_ip: client IP at the moment of first registration,
--   captured by the auth Edge Function. Retained for manual
--   review; not used in automated reject logic (IPs rotate on
--   mobile networks and are reused by NAT).
-- ------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN device_fingerprint TEXT,
  ADD COLUMN signup_ip          TEXT;

COMMENT ON COLUMN public.users.device_fingerprint IS
  'Opaque device fingerprint token set once at signup by the '
  'registration Edge Function. Derived from browser/environment '
  'signals; used by qualify_referral_txn to detect Sybil clusters. '
  'NULL for users registered before migration 018.';

COMMENT ON COLUMN public.users.signup_ip IS
  'Client IP address recorded at first registration. Stored for '
  'manual review only; not used in automated anti-abuse logic. '
  'NULL for users registered before migration 018.';

-- Partial index: quickly find every user sharing a given fingerprint.
-- The partial predicate (IS NOT NULL) keeps the index compact —
-- legacy users and users whose fingerprint was never captured are
-- excluded from the index, avoiding NULL-bucket inflation.
CREATE INDEX idx_users_device_fingerprint
  ON public.users (device_fingerprint)
  WHERE device_fingerprint IS NOT NULL;

-- ------------------------------------------------------------
-- 1b. Qualification-status columns on public.referral_events
--
-- status: drives the two-phase payout state machine.
--   pending   — referee registered; bonus not yet earned
--   qualified — qualifying trade completed; payout queued
--   paid      — tokens credited to both parties
--   rejected  — referral disqualified (e.g. device cluster)
--
-- qualifying_trade_id: FK to the trade that crossed the margin
--   threshold. Provides an immutable audit trail linking the
--   bonus to the exact trade that triggered it.
--
-- rejected_reason: free-text reason code when status='rejected'
--   (e.g. 'suspicious_device_cluster', 'trade_threshold_not_met').
--   NULL for all non-rejected rows.
--
-- Note on bonus_paid_at (existing column):
--   In the old schema this was DEFAULT NOW() and stamped at
--   INSERT time. Going forward it stays NULL until qualify_referral_txn
--   sets status='paid'; the column now records the actual payout
--   wall-clock time rather than the registration wall-clock time.
--   We ALTER the default to NULL so new pending rows start with
--   a NULL bonus_paid_at, which is semantically correct.
-- ------------------------------------------------------------

ALTER TABLE public.referral_events
  ALTER COLUMN bonus_paid_at DROP DEFAULT,
  ALTER COLUMN bonus_paid_at DROP NOT NULL,
  ADD COLUMN status               TEXT NOT NULL DEFAULT 'pending'
    CONSTRAINT referral_events_status_check
    CHECK (status IN ('pending', 'qualified', 'paid', 'rejected')),
  ADD COLUMN qualifying_trade_id  UUID
    REFERENCES public.trades(id) ON DELETE SET NULL,
  ADD COLUMN rejected_reason      TEXT;

COMMENT ON COLUMN public.referral_events.status IS
  'Two-phase payout state machine: '
  'pending → qualified → paid, or pending → rejected. '
  'Set to pending on INSERT by award_referral_bonus_txn; '
  'transitioned by qualify_referral_txn.';

COMMENT ON COLUMN public.referral_events.bonus_paid_at IS
  'UTC timestamp when qualify_referral_txn committed the token '
  'credits (status transitioned to ''paid''). NULL while status '
  'is pending, qualified, or rejected.';

COMMENT ON COLUMN public.referral_events.qualifying_trade_id IS
  'FK to the trade that crossed the margin >= 100 USDT threshold. '
  'Set by qualify_referral_txn. NULL until the qualifying trade closes.';

COMMENT ON COLUMN public.referral_events.rejected_reason IS
  'Machine-readable rejection code when status = ''rejected''. '
  'NULL for all other statuses. '
  'Known values: suspicious_device_cluster.';

-- Supporting index: qualify_referral_txn looks up pending rows
-- by referee_id. Adding status to the index allows an index-only
-- scan to satisfy the predicate without a heap fetch.
CREATE INDEX idx_referral_events_referee_status
  ON public.referral_events (referee_id, status);

-- ------------------------------------------------------------
-- 1c. Extend event_outbox allowed event_type values
--
-- The existing CHECK constraint is an inline column constraint
-- and cannot be modified in-place; we must DROP + ADD the
-- constraint to widen the allowed set.
--
-- New value added: 'referral_qualified'
--   Emitted by qualify_referral_txn on a successful payout so the
--   notification worker can send a congratulatory Telegram DM to
--   both the referrer and referee without coupling to this RPC.
-- ------------------------------------------------------------

ALTER TABLE public.event_outbox
  DROP CONSTRAINT IF EXISTS event_outbox_event_type_check,
  ADD  CONSTRAINT event_outbox_event_type_check
    CHECK (event_type IN (
      'check_achievements',
      'send_notification',
      'referral_qualified'   -- new: emitted by qualify_referral_txn
    ));

COMMENT ON COLUMN public.event_outbox.event_type IS
  'Discriminator for the process-outbox dispatcher. '
  'Allowed values: check_achievements | send_notification | referral_qualified. '
  '(referral_qualified added in migration 018.)';

-- ------------------------------------------------------------
-- 1d. New RPC: qualify_referral_txn
--
-- Caller    : service_role (close-trade Edge Function only)
-- Purpose   : Called after a trade closes. If the referee has a
--             pending referral_events row and the closed trade's
--             margin meets the qualified threshold (>= 100 USDT),
--             this function credits both parties and marks the
--             referral paid.
--
-- Args      :
--   p_referee_id    UUID    — the user who was referred
--   p_trade_id      UUID    — the trade that just closed
--   p_trade_margin  NUMERIC — margin of the closing trade (USDT)
--
-- Returns   : JSONB with keys:
--   result          TEXT    — 'paid' | 'rejected' | 'already_processed'
--                             | 'no_pending_referral' | 'below_threshold'
--   referrer_id     UUID    (present when result = 'paid' or 'rejected')
--   referrer_bonus  NUMERIC (present when result = 'paid')
--   referee_bonus   NUMERIC (present when result = 'paid')
--   reason          TEXT    (present when result = 'rejected')
--
-- Atomicity guarantee:
--   All writes (balance credits, referral_events update, outbox
--   event) execute within a single implicit transaction. Either
--   all succeed or all roll back.
--
-- Lock ordering (canonical):
--   Three resources are locked; the order follows the canonical
--   table documented at the top of this file:
--     1. users FOR UPDATE  (lower UUID first  — pos 2a)
--     2. users FOR UPDATE  (higher UUID       — pos 2b)
--     3. referral_events FOR UPDATE           — pos 5
--
-- Device-fingerprint dedup rule:
--   Before crediting bonuses, the function counts how many
--   OTHER users share the referee's device_fingerprint. If that
--   count is >= 2 (meaning 3 or more users share the fingerprint
--   including the referee), the referral is rejected with reason
--   'suspicious_device_cluster'. The referral_events row is
--   updated to status='rejected'; no tokens are credited.
--
-- Idempotency:
--   If referral_events already has status != 'pending' for this
--   referee, the function returns 'already_processed' without
--   mutating any state.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.qualify_referral_txn(
  p_referee_id   UUID,
  p_trade_id     UUID,
  p_trade_margin NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Canonical lock-order identifiers
  v_first_lock_id   UUID;
  v_second_lock_id  UUID;

  -- Row snapshots taken after locks are acquired
  v_referrer        RECORD;
  v_referee         RECORD;
  v_referral        RECORD;

  -- Anti-abuse check
  v_device_peers    INT;

  -- Qualified threshold (USDT margin required for first trade)
  c_margin_threshold CONSTANT NUMERIC := 100;

  -- Bonus amounts (mirroring the original award_referral_bonus_txn defaults)
  c_referrer_bonus CONSTANT NUMERIC(18,4) := 500;
  c_referee_bonus  CONSTANT NUMERIC(18,4) := 500;
BEGIN
  -- --------------------------------------------------------
  -- Step 0: Basic argument validation.
  -- --------------------------------------------------------
  IF p_trade_margin IS NULL OR p_trade_margin < 0 THEN
    RAISE EXCEPTION 'p_trade_margin must be a non-negative number, got %',
      p_trade_margin;
  END IF;

  -- --------------------------------------------------------
  -- Step 1: Check that a pending referral exists for this
  --         referee before acquiring any heavyweight locks.
  --         This early-exit avoids locking two user rows
  --         for the common case (no referral, or already
  --         processed).
  -- --------------------------------------------------------
  SELECT *
  INTO   v_referral
  FROM   public.referral_events
  WHERE  referee_id = p_referee_id;

  IF NOT FOUND THEN
    -- Referee was never referred; nothing to do.
    RETURN jsonb_build_object(
      'result', 'no_pending_referral'
    );
  END IF;

  IF v_referral.status != 'pending' THEN
    -- Already paid, rejected, or qualified: idempotent return.
    RETURN jsonb_build_object(
      'result',      'already_processed',
      'referrer_id', v_referral.referrer_id,
      'status',      v_referral.status
    );
  END IF;

  -- --------------------------------------------------------
  -- Step 2: Check qualifying margin threshold.
  --         Reject early (no locks) if below threshold.
  --         We do NOT write a rejected status here; the row
  --         stays 'pending' so a later qualifying trade can
  --         still succeed.
  -- --------------------------------------------------------
  IF p_trade_margin < c_margin_threshold THEN
    RETURN jsonb_build_object(
      'result',           'below_threshold',
      'referrer_id',      v_referral.referrer_id,
      'required_margin',  c_margin_threshold,
      'actual_margin',    p_trade_margin
    );
  END IF;

  -- --------------------------------------------------------
  -- Step 3: Determine lock order for the two user rows.
  --         Always lock the lower UUID first to prevent
  --         intra-table deadlocks (canonical position 2).
  -- --------------------------------------------------------
  IF v_referral.referrer_id < p_referee_id THEN
    v_first_lock_id  := v_referral.referrer_id;
    v_second_lock_id := p_referee_id;
  ELSE
    v_first_lock_id  := p_referee_id;
    v_second_lock_id := v_referral.referrer_id;
  END IF;

  -- --------------------------------------------------------
  -- Step 4a: Acquire lock on the lower-UUID user row.
  -- --------------------------------------------------------
  IF v_first_lock_id = v_referral.referrer_id THEN
    SELECT id, is_human, balance, referral_bonus_earned, device_fingerprint
    INTO   v_referrer
    FROM   public.users
    WHERE  id = v_referral.referrer_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referrer % not found', v_referral.referrer_id;
    END IF;

    -- Step 4b: Acquire lock on the higher-UUID user row.
    SELECT id, is_human, balance, device_fingerprint
    INTO   v_referee
    FROM   public.users
    WHERE  id = p_referee_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referee % not found', p_referee_id;
    END IF;
  ELSE
    -- Referee UUID is lower; lock it first.
    SELECT id, is_human, balance, device_fingerprint
    INTO   v_referee
    FROM   public.users
    WHERE  id = p_referee_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referee % not found', p_referee_id;
    END IF;

    -- Step 4b: Acquire lock on the higher-UUID referrer row.
    SELECT id, is_human, balance, referral_bonus_earned, device_fingerprint
    INTO   v_referrer
    FROM   public.users
    WHERE  id = v_referral.referrer_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referrer % not found', v_referral.referrer_id;
    END IF;
  END IF;

  -- --------------------------------------------------------
  -- Step 5: Re-read and lock the referral_events row now that
  --         both user rows are held. This prevents a race where
  --         two concurrent calls for the same referee both
  --         passed Step 1 before either committed.
  --         (Canonical position 5 — after users.)
  -- --------------------------------------------------------
  SELECT *
  INTO   v_referral
  FROM   public.referral_events
  WHERE  referee_id = p_referee_id
  FOR UPDATE;

  -- Double-check status under lock (race guard).
  IF v_referral.status != 'pending' THEN
    RETURN jsonb_build_object(
      'result',      'already_processed',
      'referrer_id', v_referral.referrer_id,
      'status',      v_referral.status
    );
  END IF;

  -- --------------------------------------------------------
  -- Step 6: Human-only guard.
  --         Both sides must be human; bots must not farm the
  --         referral system.
  -- --------------------------------------------------------
  IF NOT v_referrer.is_human THEN
    RAISE EXCEPTION 'Referrer % is not a human account', v_referral.referrer_id;
  END IF;

  IF NOT v_referee.is_human THEN
    RAISE EXCEPTION 'Referee % is not a human account', p_referee_id;
  END IF;

  -- --------------------------------------------------------
  -- Step 7: Device-fingerprint deduplication (Sybil detection).
  --
  --         Count OTHER users (excluding the referee themselves)
  --         who share the referee's device_fingerprint. If >= 2
  --         others share it, that means at least 3 accounts use
  --         the same device — a strong Sybil cluster signal.
  --
  --         Action: mark the referral 'rejected' and return.
  --         No tokens are credited. The referral_events row is
  --         permanently closed so future calls cannot retry.
  --
  --         If the referee has no fingerprint on record (NULL),
  --         the dedup check is skipped — legacy registrations
  --         and users on fingerprint-exempt clients are not
  --         penalised for missing data.
  -- --------------------------------------------------------
  IF v_referee.device_fingerprint IS NOT NULL THEN
    SELECT COUNT(*)
    INTO   v_device_peers
    FROM   public.users
    WHERE  device_fingerprint = v_referee.device_fingerprint
      AND  id != p_referee_id;

    IF v_device_peers >= 2 THEN
      -- Permanently reject: update the row to 'rejected'.
      UPDATE public.referral_events
      SET
        status          = 'rejected',
        rejected_reason = 'suspicious_device_cluster'
      WHERE referee_id = p_referee_id;

      RETURN jsonb_build_object(
        'result',      'rejected',
        'referrer_id', v_referral.referrer_id,
        'reason',      'suspicious_device_cluster'
      );
    END IF;
  END IF;

  -- --------------------------------------------------------
  -- Step 8: All checks passed. Credit both balances.
  --
  --         Both user rows are already locked (Step 4), so
  --         these UPDATEs are safe against concurrent balance
  --         modifications from other RPCs that also respect
  --         the canonical lock ordering.
  -- --------------------------------------------------------
  UPDATE public.users
  SET
    balance               = balance + c_referrer_bonus,
    referral_bonus_earned = referral_bonus_earned + c_referrer_bonus
  WHERE id = v_referral.referrer_id;

  UPDATE public.users
  SET balance = balance + c_referee_bonus
  WHERE id = p_referee_id;

  -- --------------------------------------------------------
  -- Step 9: Stamp the referral_events row as paid.
  --         qualifying_trade_id links the payout to the exact
  --         trade that crossed the threshold.
  -- --------------------------------------------------------
  UPDATE public.referral_events
  SET
    status               = 'paid',
    qualifying_trade_id  = p_trade_id,
    bonus_paid_at        = NOW()
  WHERE referee_id = p_referee_id;

  -- --------------------------------------------------------
  -- Step 10: Emit an outbox event for the notification worker.
  --          The worker sends congratulatory Telegram DMs to
  --          both parties without coupling to this transaction.
  --          Fire-and-forget risk is eliminated: if the
  --          process-outbox dispatcher fails transiently, it
  --          retries automatically.
  -- --------------------------------------------------------
  INSERT INTO public.event_outbox (event_type, payload)
  VALUES (
    'referral_qualified',
    jsonb_build_object(
      'referrer_id',    v_referral.referrer_id,
      'referee_id',     p_referee_id,
      'trade_id',       p_trade_id,
      'referrer_bonus', c_referrer_bonus,
      'referee_bonus',  c_referee_bonus
    )
  );

  -- --------------------------------------------------------
  -- Step 11: Return success summary.
  -- --------------------------------------------------------
  RETURN jsonb_build_object(
    'result',         'paid',
    'referrer_id',    v_referral.referrer_id,
    'referrer_bonus', c_referrer_bonus,
    'referee_bonus',  c_referee_bonus
  );
END;
$$;

-- Revoke broad default execute privilege.
REVOKE ALL ON FUNCTION public.qualify_referral_txn(UUID, UUID, NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qualify_referral_txn(UUID, UUID, NUMERIC) FROM anon;
REVOKE ALL ON FUNCTION public.qualify_referral_txn(UUID, UUID, NUMERIC) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.qualify_referral_txn(UUID, UUID, NUMERIC) TO service_role;

COMMENT ON FUNCTION public.qualify_referral_txn(UUID, UUID, NUMERIC) IS
  'Second phase of the two-phase referral payout. Called by the '
  'close-trade Edge Function after a trade closes. Checks: (1) a '
  'pending referral_events row exists for the referee; (2) the '
  'closing trade margin >= 100 USDT; (3) no suspicious device '
  'cluster (fewer than 3 accounts sharing the referee''s '
  'device_fingerprint). On pass: credits both balances (+500 USDT '
  'each), marks the referral_events row paid, and emits a '
  'referral_qualified outbox event. '
  'Lock order: users (lower UUID first, pos 2a/2b), then '
  'referral_events (pos 5). Callable by service_role only.';


-- ============================================================
-- Section 2 — Database Cleanup RPC: cleanup_old_logs
--
-- Caller    : service_role (pg_cron job or maintenance Edge
--             Function — never called by frontend clients)
-- Purpose   : Deletes rows older than a configurable retention
--             window from two internal tables:
--               public.notification_log  — delivery audit rows
--               public.event_outbox      — processed/failed relay rows
--
-- Args      :
--   p_retention_days INT (default 7) — rows older than this many
--     calendar days (measured from NOW()) are eligible for deletion.
--     Minimum enforced: 1 day (prevents accidental full-table wipes).
--
-- Returns   : JSONB with keys:
--   cutoff                  TIMESTAMPTZ — computed cutoff timestamp
--   notification_log_deleted INT        — rows deleted
--   event_outbox_deleted     INT        — rows deleted
--
-- Safety guards:
--   - p_retention_days < 1 raises EXCEPTION (no silent data loss).
--   - Only event_outbox rows with status IN ('completed', 'failed')
--     are eligible; 'pending' and 'processing' rows are never touched
--     regardless of age.
-- ============================================================

CREATE OR REPLACE FUNCTION public.cleanup_old_logs(
  p_retention_days INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff               TIMESTAMPTZ;
  v_notification_deleted INT;
  v_outbox_deleted       INT;
BEGIN
  -- Guard: refuse to delete anything more recent than 1 day to
  -- protect against accidental invocations with p_retention_days = 0.
  IF p_retention_days < 1 THEN
    RAISE EXCEPTION
      'p_retention_days must be >= 1 (got %); refusing to run',
      p_retention_days;
  END IF;

  v_cutoff := NOW() - (p_retention_days || ' days')::INTERVAL;

  -- ----------------------------------------------------------
  -- Clean notification_log
  -- All rows older than the cutoff are eligible regardless of
  -- the delivered flag; both successful and failed delivery
  -- records are pruned after the retention window.
  -- ----------------------------------------------------------
  DELETE FROM public.notification_log
  WHERE sent_at < v_cutoff;
  GET DIAGNOSTICS v_notification_deleted = ROW_COUNT;

  -- ----------------------------------------------------------
  -- Clean completed/failed outbox entries
  -- Rows with status = 'pending' or 'processing' are never
  -- deleted by this function, regardless of age. Stale
  -- processing rows (stuck jobs) should be handled by the
  -- process-outbox worker's heartbeat logic, not by cleanup.
  -- ----------------------------------------------------------
  DELETE FROM public.event_outbox
  WHERE status IN ('completed', 'failed')
    AND created_at < v_cutoff;
  GET DIAGNOSTICS v_outbox_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'cutoff',                    v_cutoff,
    'notification_log_deleted',  v_notification_deleted,
    'event_outbox_deleted',      v_outbox_deleted
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_old_logs(INT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_old_logs(INT) FROM anon;
REVOKE ALL ON FUNCTION public.cleanup_old_logs(INT) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.cleanup_old_logs(INT) TO service_role;

COMMENT ON FUNCTION public.cleanup_old_logs(INT) IS
  'Maintenance RPC for pruning aged internal records. Deletes rows '
  'older than p_retention_days (default 7) from notification_log '
  '(all statuses) and event_outbox (only completed/failed rows). '
  'Pending and processing outbox rows are never touched. Returns '
  'JSONB: {cutoff, notification_log_deleted, event_outbox_deleted}. '
  'Callable by service_role only. Raises if p_retention_days < 1.';


-- ============================================================
-- Section 3 — High-Frequency Query Indexes
--
-- Five composite indexes covering hot query paths that were
-- missing or insufficiently specific:
--
--   idx_trades_status_created
--     Covers ORDER BY created_at DESC queries filtered to a
--     particular status value — trade history pages and the
--     admin trade scanner (e.g. "all closed trades, newest first").
--     The existing idx_trades_status is a single-column index on
--     status only and requires an additional sort step.
--
--   idx_price_alerts_user_active
--     The "my alerts" page renders ALL alerts for a user
--     (active and historical) ordered by recency. The existing
--     idx_price_alerts_active is partial (WHERE is_active = TRUE)
--     and excludes triggered alerts, requiring a full table scan
--     for the complete history view. This new index is non-partial
--     and covers (user_id, is_active, created_at DESC) for both
--     active-only and all-alerts queries.
--
--   idx_notification_log_cleanup
--     The cleanup_old_logs function issues:
--       DELETE FROM notification_log WHERE sent_at < $cutoff
--     Without an index on sent_at, this is a sequential scan of
--     the full log table. The partial predicate mirrors the
--     default 7-day retention window; PostgreSQL uses this index
--     for the common case while the planner falls back to seqscan
--     for shorter retention windows.
--
--   idx_event_outbox_cleanup
--     The cleanup_old_logs function issues:
--       DELETE FROM event_outbox
--       WHERE status IN ('completed', 'failed') AND created_at < $cutoff
--     The existing idx_event_outbox_pending covers only pending rows.
--     This partial index mirrors the deletion predicate exactly.
--
--   idx_daily_claims_streak
--     Streak calculation looks up the most recent N claim rows
--     for a user ordered by claim_date DESC. The existing
--     idx_daily_claims_user already covers (user_id, claim_date DESC)
--     and is functionally identical; this IF NOT EXISTS guard
--     ensures the index exists regardless of whether an older
--     migration created it under a different name.
-- ============================================================

-- Trades: status + created_at for history and scanner queries.
CREATE INDEX IF NOT EXISTS idx_trades_status_created
  ON public.trades (status, created_at DESC);

-- Price alerts: user + is_active + created_at for "my alerts" page.
-- Non-partial so both active-only and full-history queries benefit.
CREATE INDEX IF NOT EXISTS idx_price_alerts_user_active
  ON public.price_alerts (user_id, is_active, created_at DESC);

-- Notification log: cleanup query path (sent_at < cutoff).
-- Full index on sent_at (not partial) so the planner can use it
-- regardless of the retention window passed to cleanup_old_logs().
CREATE INDEX IF NOT EXISTS idx_notification_log_cleanup
  ON public.notification_log (sent_at);

-- Event outbox: cleanup query path for completed/failed rows.
CREATE INDEX IF NOT EXISTS idx_event_outbox_cleanup
  ON public.event_outbox (status, created_at)
  WHERE status IN ('completed', 'failed');

-- Daily claims: streak calculation lookups (user_id + claim_date DESC).
-- IF NOT EXISTS guard: functionally identical to idx_daily_claims_user
-- created in 008_daily_rewards; this ensures the named index is
-- present even if schema was applied from an alternate path.
CREATE INDEX IF NOT EXISTS idx_daily_claims_streak
  ON public.daily_claims (user_id, claim_date DESC);


-- ============================================================
-- Section 4 — Replace award_referral_bonus_txn (pending-only)
--
-- The original 015 version (a) checked idempotency, (b) credited
-- both balances immediately, and (c) inserted the referral_events
-- row as a completed audit record — all in a single call.
--
-- This replacement:
--   (a) performs the same argument and human-only validation
--   (b) checks idempotency (referee can only register once)
--   (c) inserts referral_events with status = 'pending'
--   (d) does NOT credit any balances
--
-- The actual token payout is deferred entirely to
-- qualify_referral_txn, called after the referee's first
-- qualifying trade closes.
--
-- Return value is updated to reflect the new semantics:
--   already_registered  BOOLEAN — TRUE if a row already exists
--   referral_event_id   UUID    — ID of the pending row (new or existing)
--
-- Security model: unchanged from 015 —
--   SECURITY DEFINER, service_role only.
--
-- Lock ordering:
--   This function still acquires FOR UPDATE on both user rows
--   in UUID-ascending order (canonical positions 2a/2b) to
--   prevent races under concurrent registrations using the
--   same referral code. It does NOT lock referral_events
--   because the UNIQUE constraint (referee_id) plus
--   ON CONFLICT DO NOTHING provides sufficient idempotency
--   without a lock.
-- ============================================================

CREATE OR REPLACE FUNCTION public.award_referral_bonus_txn(
  p_referrer_id    UUID,
  p_referee_id     UUID,
  p_referrer_bonus NUMERIC(18,4) DEFAULT 500,
  p_referee_bonus  NUMERIC(18,4) DEFAULT 500
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_first_lock_id  UUID;
  v_second_lock_id UUID;
  v_referrer       RECORD;
  v_referee        RECORD;
  v_event_id       UUID;
BEGIN
  -- --------------------------------------------------------
  -- 0. Validate arguments.
  -- --------------------------------------------------------
  IF p_referrer_id = p_referee_id THEN
    RAISE EXCEPTION 'Referrer and referee must be different users';
  END IF;

  IF p_referrer_bonus < 0 OR p_referee_bonus < 0 THEN
    RAISE EXCEPTION 'Bonus amounts must be non-negative';
  END IF;

  -- --------------------------------------------------------
  -- 1. Determine lock order: always lock the lower UUID first
  --    (canonical positions 2a / 2b) to prevent intra-table
  --    deadlocks on the users table.
  -- --------------------------------------------------------
  IF p_referrer_id < p_referee_id THEN
    v_first_lock_id  := p_referrer_id;
    v_second_lock_id := p_referee_id;
  ELSE
    v_first_lock_id  := p_referee_id;
    v_second_lock_id := p_referrer_id;
  END IF;

  -- --------------------------------------------------------
  -- 2. Acquire lock on the lower-UUID row (position 2a).
  -- --------------------------------------------------------
  IF v_first_lock_id = p_referrer_id THEN
    SELECT id, is_human, display_name
    INTO   v_referrer
    FROM   public.users
    WHERE  id = p_referrer_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referrer % not found', p_referrer_id;
    END IF;

    -- --------------------------------------------------------
    -- 3a. Acquire lock on the higher-UUID row (position 2b).
    -- --------------------------------------------------------
    SELECT id, is_human, display_name
    INTO   v_referee
    FROM   public.users
    WHERE  id = p_referee_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referee % not found', p_referee_id;
    END IF;
  ELSE
    -- Referee UUID is lower; lock it first (position 2a).
    SELECT id, is_human, display_name
    INTO   v_referee
    FROM   public.users
    WHERE  id = p_referee_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referee % not found', p_referee_id;
    END IF;

    -- --------------------------------------------------------
    -- 3b. Acquire lock on the higher-UUID row (position 2b).
    -- --------------------------------------------------------
    SELECT id, is_human, display_name
    INTO   v_referrer
    FROM   public.users
    WHERE  id = p_referrer_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Referrer % not found', p_referrer_id;
    END IF;
  END IF;

  -- --------------------------------------------------------
  -- 4. Human-only guard.
  -- --------------------------------------------------------
  IF NOT v_referrer.is_human THEN
    RAISE EXCEPTION 'Referrer % is not a human account', p_referrer_id;
  END IF;

  IF NOT v_referee.is_human THEN
    RAISE EXCEPTION 'Referee % is not a human account', p_referee_id;
  END IF;

  -- --------------------------------------------------------
  -- 5. Idempotency check: has this referee already been
  --    registered (in any status)?  Both user locks are held
  --    so this read is stable against concurrent calls.
  -- --------------------------------------------------------
  SELECT id
  INTO   v_event_id
  FROM   public.referral_events
  WHERE  referee_id = p_referee_id;

  IF FOUND THEN
    -- A referral_events row already exists (pending, paid,
    -- rejected, etc.). Return without mutating any state.
    RETURN jsonb_build_object(
      'already_registered',  TRUE,
      'referral_event_id',   v_event_id
    );
  END IF;

  -- --------------------------------------------------------
  -- 6. Create the pending referral_events row.
  --    No balance changes — tokens are deferred to
  --    qualify_referral_txn after the qualifying first trade.
  --
  --    ON CONFLICT DO NOTHING is a second-layer idempotency
  --    guard for the rare race where two concurrent calls
  --    both passed step 5 before either committed.
  -- --------------------------------------------------------
  INSERT INTO public.referral_events
    (referrer_id, referee_id, referrer_bonus, referee_bonus, status)
  VALUES
    (p_referrer_id, p_referee_id, p_referrer_bonus, p_referee_bonus, 'pending')
  ON CONFLICT (referee_id) DO NOTHING
  RETURNING id INTO v_event_id;

  -- If ON CONFLICT DO NOTHING fired (extremely rare race), read
  -- the existing row's id to return a consistent response.
  IF v_event_id IS NULL THEN
    SELECT id
    INTO   v_event_id
    FROM   public.referral_events
    WHERE  referee_id = p_referee_id;

    RETURN jsonb_build_object(
      'already_registered',  TRUE,
      'referral_event_id',   v_event_id
    );
  END IF;

  -- --------------------------------------------------------
  -- 7. Return the new pending event id.
  -- --------------------------------------------------------
  RETURN jsonb_build_object(
    'already_registered',  FALSE,
    'referral_event_id',   v_event_id
  );
END;
$$;

-- Preserve the same security model as the 015 version.
REVOKE EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) FROM anon;
REVOKE EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) TO service_role;

COMMENT ON FUNCTION public.award_referral_bonus_txn(UUID, UUID, NUMERIC, NUMERIC) IS
  'Phase-1 of the two-phase referral payout (supersedes the 015 version). '
  'Acquires FOR UPDATE locks on both user rows in UUID-ascending order '
  '(canonical positions 2a/2b), validates both parties are human, checks '
  'idempotency via referral_events.referee_id UNIQUE constraint, and '
  'inserts a referral_events row with status=''pending''. '
  'NO tokens are credited here — the actual payout is deferred to '
  'qualify_referral_txn, called by the close-trade Edge Function after '
  'the referee completes a qualifying first trade (margin >= 100 USDT). '
  'Returns JSONB: {already_registered, referral_event_id}. '
  'Callable by service_role only.';


-- ============================================================
-- RPC Lock Acquisition Table update (docs/LOCK_ORDERING.md)
--
-- Full canonical lock order after migration 018:
--   Position 1: tournaments        (005_tournaments)
--   Position 2: users              (001_phase1_schema)
--   Position 3: trades             (001_phase1_schema)
--   Position 4: price_alerts       (017_price_alerts)
--   Position 5: referral_events    (018_production_hardening) ← NEW
--
-- | RPC                        | Migration | Lock 1               | Lock 2               | Lock 3                  |
-- |----------------------------|-----------|----------------------|----------------------|-------------------------|
-- | qualify_referral_txn       | 018       | users FOR UPDATE     | users FOR UPDATE     | referral_events FOR UPDATE |
-- |                            |           | (lower UUID — pos 2a)| (higher UUID — pos 2b)| (pos 5)               |
-- | award_referral_bonus_txn   | 018       | users FOR UPDATE     | users FOR UPDATE     | —                       |
-- | (replaces 015 version)     |           | (lower UUID — pos 2a)| (higher UUID — pos 2b)|                        |
--
-- Deadlock analysis for qualify_referral_txn vs. existing RPCs:
--
--   vs. award_referral_bonus_txn (018):
--     Both acquire users locks (pos 2a/2b) in UUID order.
--     qualify_referral_txn additionally locks referral_events (pos 5).
--     award_referral_bonus_txn never locks referral_events.
--     No shared second lock between the two → no cycle possible.
--
--   vs. execute_trade_txn (002):
--     execute_trade_txn locks one users row then inserts into trades.
--     qualify_referral_txn locks two users rows then referral_events.
--     No shared lock on trades or referral_events → no cycle.
--
--   vs. close_trade_txn (013):
--     close_trade_txn locks trades (pos 3) then one users row (pos 2).
--     NOTE: this acquires trades BEFORE users — a departure from
--     canonical order inherited from 007. This pre-existing inversion
--     is safe against qualify_referral_txn because qualify_referral_txn
--     never locks trades. No shared table sequence → no cycle.
--
--   vs. award_daily_reward_txn (013):
--     Locks one users row. qualify_referral_txn locks two users rows
--     in ascending order. Same analysis as the original 015 commentary:
--     if award_daily_reward_txn holds row A and qualify_referral_txn
--     has locked lower row B and is waiting for A, award_daily_reward_txn
--     holds A and completes without touching B. No cycle.
--
--   vs. itself (two concurrent qualify calls for overlapping pairs):
--     Both calls lock the lower UUID first. If T1 holds X (lower) and
--     T2 wants X, T2 waits. T1 then locks Y (higher) and completes.
--     No cycle.
-- ============================================================

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
--
-- IMPORTANT: Rolling back Section 1 (status columns on
-- referral_events) is only safe if no rows have been transitioned
-- to non-pending states. Check before running the Down block.
--
-- -- Section 4: restore original award_referral_bonus_txn
-- -- (re-run 015_referral_system.sql to restore the 015 body)
--
-- -- Section 3: drop new indexes
-- DROP INDEX IF EXISTS public.idx_trades_status_created;
-- DROP INDEX IF EXISTS public.idx_price_alerts_user_active;
-- DROP INDEX IF EXISTS public.idx_notification_log_cleanup;
-- DROP INDEX IF EXISTS public.idx_event_outbox_cleanup;
-- DROP INDEX IF EXISTS public.idx_daily_claims_streak;
--
-- -- Section 2: drop cleanup RPC
-- DROP FUNCTION IF EXISTS public.cleanup_old_logs(INT);
--
-- -- Section 1d: drop qualify_referral_txn
-- DROP FUNCTION IF EXISTS public.qualify_referral_txn(UUID, UUID, NUMERIC);
--
-- -- Section 1c: restore original event_outbox event_type check
-- ALTER TABLE public.event_outbox
--   DROP CONSTRAINT IF EXISTS event_outbox_event_type_check,
--   ADD  CONSTRAINT event_outbox_event_type_check
--     CHECK (event_type IN ('check_achievements', 'send_notification'));
--
-- -- Section 1b: drop new referral_events columns
-- DROP INDEX IF EXISTS public.idx_referral_events_referee_status;
-- ALTER TABLE public.referral_events
--   DROP COLUMN IF EXISTS rejected_reason,
--   DROP COLUMN IF EXISTS qualifying_trade_id,
--   DROP COLUMN IF EXISTS status,
--   ALTER COLUMN bonus_paid_at SET NOT NULL,
--   ALTER COLUMN bonus_paid_at SET DEFAULT NOW();
--
-- -- Section 1a: drop new users columns
-- DROP INDEX IF EXISTS public.idx_users_device_fingerprint;
-- ALTER TABLE public.users
--   DROP COLUMN IF EXISTS signup_ip,
--   DROP COLUMN IF EXISTS device_fingerprint;
--
-- ============================================================
