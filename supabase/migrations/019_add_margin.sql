-- =============================================================================
-- Migration: 019_add_margin
-- Description: Add Margin feature — allows users to add collateral to open
--              positions, lowering their liquidation price.
-- Created: 2026-03-30
--
-- New objects:
--   TABLE  public.margin_additions  — audit trail of every margin addition
--   RPC    public.add_margin_txn    — atomic margin addition
--
-- Lock ordering (canonical — see docs/LOCK_ORDERING.md):
--   add_margin_txn acquires locks in order:
--     1. users  FOR UPDATE  (canonical position 2)
--     2. trades FOR UPDATE  (canonical position 3)
--
-- Security model:
--   margin_additions:
--     - anon          : REVOKED
--     - authenticated : SELECT own rows only
--     - service_role  : full access (RLS bypassed)
--   add_margin_txn:
--     - PUBLIC / anon / authenticated : REVOKED
--     - service_role  : GRANTED
-- =============================================================================

BEGIN;

-- =============================================================================
-- TABLE: public.margin_additions
-- =============================================================================

CREATE TABLE public.margin_additions (
  id               UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id         UUID           NOT NULL REFERENCES public.trades(id),
  user_id          UUID           NOT NULL REFERENCES public.users(id),
  amount           NUMERIC(18, 4) NOT NULL CHECK (amount > 0),
  margin_before    NUMERIC(18, 4) NOT NULL,
  margin_after     NUMERIC(18, 4) NOT NULL,
  liq_price_before NUMERIC(20, 8) NOT NULL,
  liq_price_after  NUMERIC(20, 8) NOT NULL,
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_margin_additions_trade ON public.margin_additions (trade_id);
CREATE INDEX idx_margin_additions_user ON public.margin_additions (user_id, created_at DESC);

ALTER TABLE public.margin_additions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "margin_additions: owner can select"
  ON public.margin_additions FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

REVOKE ALL ON public.margin_additions FROM anon;


-- =============================================================================
-- RPC: add_margin_txn
-- =============================================================================
-- Atomically adds margin to an open position:
--   1. Lock users row (canonical position 2)
--   2. Validate balance >= additional_margin
--   3. Lock trades row (canonical position 3)
--   4. Validate ownership and status = 'open'
--   5. Compute new margin and new liquidation price
--   6. Update trades row
--   7. Deduct from user balance
--   8. Insert audit row into margin_additions
--   9. Return updated trade as JSONB
--
-- Liquidation price formula:
--   The liquidation price is the price at which the position's entire
--   margin is consumed by unrealized loss.
--
--   For a long position:
--     unrealized_loss = quantity * (entry_price - current_price)
--     at liquidation: margin = quantity * (entry_price - liq_price)
--     therefore: liq_price = entry_price - (margin / quantity)
--
--   For a short position:
--     unrealized_loss = quantity * (current_price - entry_price)
--     at liquidation: margin = quantity * (liq_price - entry_price)
--     therefore: liq_price = entry_price + (margin / quantity)
--
--   Adding margin increases the denominator, pushing the liq price
--   further from entry (safer for the user).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.add_margin_txn(
  p_trade_id          UUID,
  p_user_id           UUID,
  p_additional_margin NUMERIC(18, 4)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_balance    NUMERIC(18, 4);
  v_trade           RECORD;
  v_new_margin      NUMERIC(18, 4);
  v_new_liq_price   NUMERIC(20, 8);
  v_old_margin      NUMERIC(18, 4);
  v_old_liq_price   NUMERIC(20, 8);
  v_result          JSONB;
BEGIN
  -- Validate input
  IF p_additional_margin IS NULL OR p_additional_margin <= 0 THEN
    RAISE EXCEPTION 'additional_margin must be a positive number';
  END IF;

  IF p_additional_margin < 10 THEN
    RAISE EXCEPTION 'minimum_margin: Minimum additional margin is 10 USDT';
  END IF;

  -- Step 1: Lock user row (canonical position 2)
  SELECT balance INTO v_user_balance
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_not_found: User % does not exist', p_user_id;
  END IF;

  -- Step 2: Validate sufficient balance
  IF v_user_balance < p_additional_margin THEN
    RAISE EXCEPTION 'insufficient_balance: Balance % is less than required %',
      v_user_balance, p_additional_margin;
  END IF;

  -- Step 3: Lock trade row (canonical position 3)
  SELECT * INTO v_trade
  FROM public.trades
  WHERE id = p_trade_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not exist', p_trade_id;
  END IF;

  -- Step 4: Validate ownership and status
  IF v_trade.user_id != p_user_id THEN
    RAISE EXCEPTION 'trade_not_found: Trade % does not belong to user %',
      p_trade_id, p_user_id;
  END IF;

  IF v_trade.status != 'open' THEN
    RAISE EXCEPTION 'trade_not_open: Cannot add margin to a % position',
      v_trade.status;
  END IF;

  -- Step 5: Compute new margin and liquidation price
  v_old_margin    := v_trade.margin;
  v_old_liq_price := v_trade.liquidation_price;
  v_new_margin    := v_old_margin + p_additional_margin;

  IF v_trade.direction = 'long' THEN
    -- Long: liq_price = entry_price - (margin / quantity)
    v_new_liq_price := v_trade.entry_price - (v_new_margin / v_trade.quantity);
    -- Clamp to 0 (can't have negative price)
    IF v_new_liq_price < 0 THEN
      v_new_liq_price := 0;
    END IF;
  ELSE
    -- Short: liq_price = entry_price + (margin / quantity)
    v_new_liq_price := v_trade.entry_price + (v_new_margin / v_trade.quantity);
  END IF;

  -- Step 6: Update trade
  UPDATE public.trades
  SET
    margin            = v_new_margin,
    liquidation_price = v_new_liq_price
  WHERE id = p_trade_id;

  -- Step 7: Deduct from user balance
  UPDATE public.users
  SET balance = balance - p_additional_margin
  WHERE id = p_user_id;

  -- Step 8: Audit trail
  INSERT INTO public.margin_additions (
    trade_id, user_id, amount,
    margin_before, margin_after,
    liq_price_before, liq_price_after
  ) VALUES (
    p_trade_id, p_user_id, p_additional_margin,
    v_old_margin, v_new_margin,
    v_old_liq_price, v_new_liq_price
  );

  -- Step 9: Return updated trade
  SELECT to_jsonb(t.*) INTO v_result
  FROM public.trades t
  WHERE t.id = p_trade_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.add_margin_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_margin_txn FROM anon;
REVOKE ALL ON FUNCTION public.add_margin_txn FROM authenticated;
GRANT EXECUTE ON FUNCTION public.add_margin_txn TO service_role;

COMMIT;
