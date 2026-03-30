-- =============================================================================
-- Migration: 004_openclaw_agent
-- Description: Seeds the OpenClaw AI agent (the lobster) as a permanent
--              arena participant. This is a one-time seed operation; the
--              agent row is stable across all environments.
-- Created: 2026-03-29
--
-- Design decisions:
--
--   UUID: '00000000-0000-0000-0000-00000c1a0001'
--     - Deterministic so Edge Functions can hardcode OPENCLAW_AGENT_ID
--       as an env-var or constant rather than doing a lookup on every call.
--     - The '0c1a' segment is a visual mnemonic for "ocla" (OpenCLAw).
--     - This UUID is safe to commit to source; it is not a secret.
--
--   auth.users insertion:
--     - We insert directly into auth.users so the FK on public.users(id)
--       is satisfied without disabling the constraint.
--     - encrypted_password = '' and no confirmed email means this account
--       cannot authenticate via any Supabase Auth flow (password, magic link,
--       OAuth, etc.). It is a structural/service account only.
--     - ON CONFLICT (id) DO NOTHING makes this migration idempotent.
--
--   public.users insertion:
--     - tg_id = 0: reserved sentinel value; real Telegram IDs start at 1.
--       The UNIQUE constraint on tg_id means only one row can hold tg_id=0.
--     - is_human = FALSE: correctly flags this row as the AI agent on the
--       leaderboard_view so the frontend can render the lobster badge.
--     - balance = 10000: same starting capital as every human participant.
--
--   on_auth_user_created trigger:
--     - The trigger fires AFTER INSERT ON auth.users. However, we insert
--       into public.users explicitly with ON CONFLICT DO NOTHING, so the
--       trigger's own INSERT will be a safe no-op.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_openclaw_id CONSTANT UUID := '00000000-0000-0000-0000-00000c1a0001';
BEGIN
  -- -------------------------------------------------------------------------
  -- Step 1: Create the auth.users stub.
  -- -------------------------------------------------------------------------
  -- This satisfies the FK reference on public.users(id) → auth.users(id).
  -- The account has no password and no confirmed email, so it cannot be used
  -- to log in via any Supabase Auth provider.
  -- -------------------------------------------------------------------------
  INSERT INTO auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at,
    confirmation_token,
    raw_app_meta_data,
    raw_user_meta_data
  ) VALUES (
    v_openclaw_id,
    '00000000-0000-0000-0000-000000000000',   -- default Supabase instance_id
    'authenticated',
    'authenticated',
    'openclaw@arena.internal',                -- non-routable internal address
    '',                                       -- no password — cannot login
    NOW(),                                    -- treat email as pre-confirmed
    NOW(),
    NOW(),
    '',
    '{"provider":"service","providers":["service"]}'::jsonb,
    '{"tg_id":0,"first_name":"OpenClaw","username":"openclaw_lobster"}'::jsonb
  )
  ON CONFLICT (id) DO NOTHING;

  -- -------------------------------------------------------------------------
  -- Step 2: Create the public.users arena participant row.
  -- -------------------------------------------------------------------------
  -- The on_auth_user_created trigger will also fire an INSERT for this UUID,
  -- but ON CONFLICT (id) DO NOTHING on both sides makes both paths safe.
  -- -------------------------------------------------------------------------
  INSERT INTO public.users (
    id,
    tg_id,
    display_name,
    username,
    is_human,
    balance,
    roi
  ) VALUES (
    v_openclaw_id,
    0,                    -- sentinel tg_id; reserved for the AI agent
    'OpenClaw',           -- display name shown on leaderboard (no emoji in DB)
    'openclaw_lobster',   -- @handle shown in UI
    FALSE,                -- is_human = false; renders lobster badge on frontend
    10000,                -- same starting balance as every human participant
    0                     -- ROI starts at 0.000000
  )
  ON CONFLICT (id) DO NOTHING;
END;
$$;


COMMIT;


-- =============================================================================
-- NOTES FOR EDGE FUNCTIONS
-- =============================================================================
--
--   The OpenClaw agent UUID is stable and can be used as a constant:
--
--     const OPENCLAW_AGENT_ID = '00000000-0000-0000-0000-00000c1a0001';
--
--   This eliminates a SELECT lookup on every agent trade cycle.
--   Store it in Supabase Secrets or as a top-level constant in the Edge
--   Function — never hardcode raw API keys or user secrets alongside it.
--
--   Because is_human = FALSE, the leaderboard_view already returns this row
--   with the correct flag; the frontend needs no special handling beyond
--   checking the is_human column.
-- =============================================================================
