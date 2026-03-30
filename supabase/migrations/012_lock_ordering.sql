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
