-- Migration 014: Add per-user timezone offset
--
-- timezone_offset stores the user's offset from UTC in minutes.
-- Positive values are east of UTC, negative values are west.
--
-- Examples:
--   UTC+8  (China Standard Time)  →  +480
--   UTC+5:30 (India Standard Time) → +330
--   UTC-5  (US Eastern)           →  -300
--   UTC-8  (US Pacific)           →  -480
--
-- The value is set by the frontend using:
--   -new Date().getTimezoneOffset()
-- (JS getTimezoneOffset() returns the negated offset, so we negate it back.)

ALTER TABLE public.users
  ADD COLUMN timezone_offset INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.users.timezone_offset IS
  'User timezone offset from UTC in minutes. '
  'Set by the frontend from -new Date().getTimezoneOffset(). '
  'Range: -720 (UTC-12) to +840 (UTC+14).';
