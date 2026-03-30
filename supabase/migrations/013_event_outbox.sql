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
