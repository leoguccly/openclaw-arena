-- =============================================================================
-- Migration: 020_referral_rewards
-- Description: Referral reward system — free tournament entries based on
--              qualified referral count.
--
--   5 qualified referrals  → 1 free tournament entry
--   10 qualified referrals → 2 free tournament entries
--   15+ qualified referrals → 3 free tournament entries (cap)
--
-- New columns on users:
--   free_entries_earned  INT  — total free entries earned from referrals
--   free_entries_used    INT  — entries already consumed
-- =============================================================================

BEGIN;

ALTER TABLE public.users
  ADD COLUMN free_entries_earned INT NOT NULL DEFAULT 0,
  ADD COLUMN free_entries_used INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.users.free_entries_earned IS
  'Total free tournament entries earned via referral program. '
  'Computed as: MIN(3, FLOOR(qualified_referral_count / 5)).';

COMMENT ON COLUMN public.users.free_entries_used IS
  'Free tournament entries already consumed by joining tournaments.';

COMMIT;
