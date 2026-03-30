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
