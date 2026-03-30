-- ============================================================
-- Migration : 016_ai_personalities
-- Description: Adds two additional AI agent personalities
--              (OpenClaw Conservative, OpenClaw Chaos) following
--              the same seeding pattern as the original OpenClaw
--              agent. Adds an avatar_slug column to public.users
--              to allow the frontend to display distinct icons
--              for each AI personality and for human users.
--
-- Security model
--   - The two new agent rows are seeded directly into auth.users
--     and public.users using the same INSERT ... ON CONFLICT DO
--     NOTHING pattern established for the original agent. This
--     makes the migration safe to replay in environments that
--     already applied it (e.g., staging refreshes).
--   - avatar_slug is an opaque string resolved to an asset path
--     by the frontend. It is set by the service role only;
--     authenticated users have no UPDATE policy on this column
--     beyond what already exists on their own row (the column
--     is intentionally not filtered further here — access
--     control for user-facing profile updates is the
--     responsibility of the profile-edit endpoint).
--   - Bot rows carry is_human = FALSE. All RPCs that enforce
--     human-only guards (award_daily_reward_txn,
--     award_referral_bonus_txn) will correctly reject them.
--
-- Agent UUID registry (all non-human accounts):
--   00000000-0000-0000-0000-00000c1a0001  OpenClaw (original)
--   00000000-0000-0000-0000-00000c1a0002  OpenClaw Conservative  ← new
--   00000000-0000-0000-0000-00000c1a0003  OpenClaw Chaos         ← new
--
-- tg_id convention for AI agents:
--    0  → original OpenClaw agent (no Telegram identity)
--   -1  → OpenClaw Conservative
--   -2  → OpenClaw Chaos
--   Negative tg_ids are reserved for system/bot accounts and
--   will never be issued by the Telegram platform.
--
-- Depends on : 001_initial_schema (public.users, auth.users stub)
-- Idempotent  : YES — all INSERTs use ON CONFLICT DO NOTHING.
-- Rollback    : see Down section at the bottom of this file.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Section 1 — Add avatar_slug column to public.users
--
-- Nullable TEXT column; NULL means "use the default avatar".
-- The frontend resolves the slug to a bundled asset path.
-- Existing rows (including the original OpenClaw agent and all
-- human users) are left as NULL and receive the default avatar.
-- ------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN avatar_slug TEXT;

COMMENT ON COLUMN public.users.avatar_slug IS
  'Opaque frontend token that maps to a bundled avatar asset. '
  'NULL means use the application default avatar. '
  'Set by the service role; human users may update their own row '
  'through the profile-edit endpoint.';

-- Backfill the original OpenClaw agent with its own slug so all
-- three AI agents have a consistent slug from this migration onward.
UPDATE public.users
SET    avatar_slug = 'openclaw_original'
WHERE  id = '00000000-0000-0000-0000-00000c1a0001'::UUID;

-- ------------------------------------------------------------
-- Section 2 — Seed auth.users stubs for the new AI agents
--
-- auth.users stubs are required so the FK
-- public.users.id → auth.users.id is satisfied.
-- The email values are synthetic sentinel addresses that will
-- never receive mail; the format mirrors the original agent stub.
-- Passwords are intentionally absent (no login possible).
-- ------------------------------------------------------------

INSERT INTO auth.users (
  id,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data,
  is_super_admin,
  role
)
VALUES
  -- OpenClaw Conservative
  (
    '00000000-0000-0000-0000-00000c1a0002'::UUID,
    'openclaw-conservative@system.internal',
    '',                           -- no password; bot cannot authenticate
    NOW(),
    NOW(),
    NOW(),
    '{"provider":"system","providers":["system"]}'::JSONB,
    '{}'::JSONB,
    FALSE,
    'authenticated'
  ),
  -- OpenClaw Chaos
  (
    '00000000-0000-0000-0000-00000c1a0003'::UUID,
    'openclaw-chaos@system.internal',
    '',
    NOW(),
    NOW(),
    NOW(),
    '{"provider":"system","providers":["system"]}'::JSONB,
    '{}'::JSONB,
    FALSE,
    'authenticated'
  )
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------
-- Section 3 — Seed public.users rows for the new AI agents
-- ------------------------------------------------------------

INSERT INTO public.users (
  id,
  tg_id,
  display_name,
  username,
  is_human,
  balance,
  roi,
  current_streak,
  last_claim_date,
  notifications_enabled,
  timezone_offset,
  avatar_slug
)
VALUES
  -- OpenClaw Conservative: risk-averse trading personality.
  (
    '00000000-0000-0000-0000-00000c1a0002'::UUID,
    -1,
    'OpenClaw Conservative',
    'openclaw_conservative',
    FALSE,     -- bot account; human-only guards will reject it
    10000,     -- starting balance identical to original agent
    0,
    0,
    NULL,
    FALSE,
    0,
    'openclaw_conservative'
  ),
  -- OpenClaw Chaos: high-volatility trading personality.
  (
    '00000000-0000-0000-0000-00000c1a0003'::UUID,
    -2,
    'OpenClaw Chaos',
    'openclaw_chaos',
    FALSE,
    10000,
    0,
    0,
    NULL,
    FALSE,
    0,
    'openclaw_chaos'
  )
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE public.users IS
  'All participants: human users and AI agent accounts. '
  'AI agents carry is_human = FALSE and UUIDs in the '
  '00000000-0000-0000-0000-00000c1aXXXX namespace. '
  'Known agents: 0001 = OpenClaw (original), '
  '0002 = OpenClaw Conservative, 0003 = OpenClaw Chaos.';

COMMIT;

-- ============================================================
-- Down (rollback — execute manually, never in CI)
-- ============================================================
-- DELETE FROM public.users
--   WHERE id IN (
--     '00000000-0000-0000-0000-00000c1a0002'::UUID,
--     '00000000-0000-0000-0000-00000c1a0003'::UUID
--   );
-- DELETE FROM auth.users
--   WHERE id IN (
--     '00000000-0000-0000-0000-00000c1a0002'::UUID,
--     '00000000-0000-0000-0000-00000c1a0003'::UUID
--   );
-- UPDATE public.users SET avatar_slug = NULL
--   WHERE id = '00000000-0000-0000-0000-00000c1a0001'::UUID;
-- ALTER TABLE public.users DROP COLUMN IF EXISTS avatar_slug;
-- ============================================================
