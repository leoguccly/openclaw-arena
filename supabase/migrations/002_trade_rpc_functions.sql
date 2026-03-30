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
