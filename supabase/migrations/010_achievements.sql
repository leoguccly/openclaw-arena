-- ============================================================
-- Migration : 010_achievements
-- Description: Introduces the achievement / badge system for
--              Phase 3 gamification.
--
--              Three tables:
--                achievements            — static catalogue (seeded)
--                user_achievements       — earned badges (immutable)
--                user_achievement_progress — progress toward badges
--                                           with is_progress_tracked=TRUE
--
-- Achievement catalogue (seeded at end of migration)
--   ACH-001  Claw Crusher     — Beat OpenClaw ROI 3 times
--   ACH-002  Daredevil        — Close a 100x position w/out liquidation
--   ACH-003  Arena Elite      — Finish Top 10 in any tournament
--   ACH-004  Golden Claw      — >50% ROI on a single trade
--   ACH-005  Streak Keeper    — 7-day consecutive login streak
--   ACH-006  Survivor         — Hold position 24+ h w/out liquidation
--
-- Security model
--   achievements (catalogue)
--     - Readable by everyone (anon + authenticated): badge names
--       and descriptions must be visible on the public leaderboard
--       and before the user authenticates.
--     - Writes are service_role-only (no INSERT/UPDATE policy for
--       authenticated); catalogue updates come via future migrations.
--
--   user_achievements (earned rows)
--     - Readable by authenticated owner (profile page) AND by anon
--       (leaderboard badge display). Rows are intentionally public
--       because showing earned badges on the public arena is a core
--       product feature that drives competition.
--     - No UPDATE/DELETE ever: earned badges are permanent. The
--       service_role writes them exclusively through the bot or an
--       edge function that validates the unlock condition.
--
--   user_achievement_progress
--     - Readable by authenticated owner only.
--     - Writable by service_role only.
--     - anon has no access.
--
-- Unlock flow (handled by bot / edge function, not this migration)
--   1. Relevant event fires (trade closed, streak updated, etc.)
--   2. Edge function evaluates all progress-tracked achievements.
--   3. For non-progress achievements: INSERT directly if condition met.
--   4. For progress achievements: UPSERT user_achievement_progress;
--      if current_count >= required_count, INSERT user_achievements.
--
-- Depends on : 001_initial_schema (public.users)
-- Idempotent  : NO — run exactly once.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Achievement catalogue (static reference data)
-- ------------------------------------------------------------

CREATE TABLE public.achievements (
  id                   TEXT    PRIMARY KEY,
  name                 TEXT    NOT NULL,
  description          TEXT    NOT NULL,
  icon_key             TEXT    NOT NULL,
  required_count       INT     NOT NULL DEFAULT 1 CHECK (required_count >= 1),
  is_progress_tracked  BOOLEAN NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE public.achievements IS
  'Static catalogue of all achievement definitions. Seeded by this '
  'migration; future badges added via subsequent migrations. '
  'Never modified at runtime.';

COMMENT ON COLUMN public.achievements.id IS
  'Human-readable slug, e.g. ACH-001. Stable identifier '
  'referenced by user_achievements and user_achievement_progress.';

COMMENT ON COLUMN public.achievements.icon_key IS
  'Key used by the Flutter app to resolve the badge icon asset.';

COMMENT ON COLUMN public.achievements.required_count IS
  'For progress-tracked achievements: how many qualifying events '
  'must occur before the badge is awarded. Always 1 for one-shot '
  'achievements (is_progress_tracked = FALSE).';

COMMENT ON COLUMN public.achievements.is_progress_tracked IS
  'TRUE when the achievement requires incremental progress '
  '(e.g. beat bot 3 times). FALSE for one-shot events.';

ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;

-- Public read: badge names visible on leaderboard and before login.
CREATE POLICY "achievements: anyone can read"
  ON public.achievements
  FOR SELECT
  TO anon, authenticated
  USING (TRUE);

-- No INSERT/UPDATE/DELETE for non-service_role callers;
-- catalogue is updated exclusively via migrations.

-- ------------------------------------------------------------
-- Section 2 — Earned achievements (immutable ledger)
-- ------------------------------------------------------------

CREATE TABLE public.user_achievements (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  achievement_id  TEXT        NOT NULL REFERENCES public.achievements(id),
  earned_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT user_achievements_unique UNIQUE (user_id, achievement_id)
);

COMMENT ON TABLE public.user_achievements IS
  'Immutable record of every achievement earned by a user. '
  'Rows are append-only; deletion or update is prohibited for '
  'non-service_role callers. A UNIQUE constraint ensures each '
  'badge can only be awarded once per user.';

COMMENT ON COLUMN public.user_achievements.earned_at IS
  'UTC timestamp at which the unlock condition was satisfied and '
  'the row was inserted by the service layer.';

CREATE INDEX idx_user_achievements_user
  ON public.user_achievements (user_id);

ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;

-- Owner can read their own earned badges (profile page).
CREATE POLICY "user_achievements: owner can select"
  ON public.user_achievements
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Public read: badges are shown on the leaderboard and arena
-- pages for all users, including unauthenticated visitors.
CREATE POLICY "user_achievements: public read for badges"
  ON public.user_achievements
  FOR SELECT
  TO anon
  USING (TRUE);

-- No INSERT/UPDATE/DELETE policies for authenticated or anon;
-- only service_role may write (via edge function).

-- ------------------------------------------------------------
-- Section 3 — Progress tracking table
-- ------------------------------------------------------------

CREATE TABLE public.user_achievement_progress (
  user_id         UUID    NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  achievement_id  TEXT    NOT NULL REFERENCES public.achievements(id),
  current_count   INT     NOT NULL DEFAULT 0 CHECK (current_count >= 0),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (user_id, achievement_id)
);

COMMENT ON TABLE public.user_achievement_progress IS
  'Tracks incremental progress toward achievements that require '
  'multiple qualifying events (is_progress_tracked = TRUE). '
  'The service layer UPSERTs this table on each relevant event '
  'and checks whether current_count >= required_count to trigger '
  'the final unlock INSERT into user_achievements.';

COMMENT ON COLUMN public.user_achievement_progress.current_count IS
  'Number of qualifying events accumulated so far for this '
  '(user, achievement) pair. Never decremented.';

COMMENT ON COLUMN public.user_achievement_progress.updated_at IS
  'Timestamp of the last increment, used for debugging and '
  'display in the app''s progress panel.';

-- No additional index needed: PK (user_id, achievement_id) covers
-- the service layer UPSERT and the owner SELECT below.

ALTER TABLE public.user_achievement_progress ENABLE ROW LEVEL SECURITY;

-- Owner can read their own progress (in-app progress bars).
CREATE POLICY "user_achievement_progress: owner can select"
  ON public.user_achievement_progress
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Harden: anon has no access to progress data.
REVOKE ALL ON public.user_achievement_progress FROM anon;

-- ------------------------------------------------------------
-- Section 4 — Seed the achievement catalogue
-- ------------------------------------------------------------

INSERT INTO public.achievements
  (id,        name,             description,                                        icon_key,   required_count, is_progress_tracked)
VALUES
  ('ACH-001', 'Claw Crusher',   'Beat OpenClaw''s ROI 3 times',                    'trophy',   3,              TRUE ),
  ('ACH-002', 'Daredevil',      'Close a 100x position without liquidation',        'lightning',1,              FALSE),
  ('ACH-003', 'Arena Elite',    'Finish Top 10 in any tournament',                  'medal',    1,              FALSE),
  ('ACH-004', 'Golden Claw',    'Achieve >50% ROI on a single trade',               'star',     1,              FALSE),
  ('ACH-005', 'Streak Keeper',  'Maintain a 7-day consecutive daily login streak',  'fire',     7,              TRUE ),
  ('ACH-006', 'Survivor',       'Hold a position 24+ hours without liquidation',    'shield',   1,              FALSE);

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DROP TABLE IF EXISTS public.user_achievement_progress;
-- DROP TABLE IF EXISTS public.user_achievements;
-- DROP TABLE IF EXISTS public.achievements;
-- ============================================================
