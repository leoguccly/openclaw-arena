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
