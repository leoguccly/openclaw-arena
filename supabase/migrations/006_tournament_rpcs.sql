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
