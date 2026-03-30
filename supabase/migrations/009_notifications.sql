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
