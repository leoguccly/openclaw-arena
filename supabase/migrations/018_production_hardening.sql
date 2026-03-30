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
