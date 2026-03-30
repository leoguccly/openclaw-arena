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
