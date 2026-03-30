# OpenClaw Arena — Phase 4 Specification

> **Sprint Duration**: 1 week (2026-03-30 to 2026-04-05)
> **Status**: Draft — awaiting team sign-off
> **Author**: Business Analyst
> **Tech Stack**: Next.js (App Router) + Supabase (PostgreSQL + Edge Functions, Deno/TypeScript)

---

## Executive Summary

Phase 4 ships three features selected for maximum competitive differentiation and development velocity. All three leverage infrastructure that already exists in Phases 1–3.5, minimising net-new surface area and risk. The excluded features (Advanced Analytics, Seasonal Leaderboard Reset) are deferred — not dropped — and their schema implications are noted where they affect Phase 4 decisions.

---

## Feature Priority Rationale

| # | Feature | Selected | Rationale |
|---|---------|----------|-----------|
| 1 | Referral System | YES | Viral growth loop. Builds directly on existing `users` table and TG deep-link infrastructure. Low DB complexity, high retention impact. |
| 2 | Multiple AI Personalities | YES | Deepens the core "Human vs Lobster" narrative with near-zero new schema. Reuses `openclaw-trade` function architecture. High engagement, low effort. |
| 3 | Price Alerts | YES | Directly extends `scan-liquidations` (already runs every 60s). Notification infrastructure (TG Bot, quotas, quiet hours) is fully built. Adds a new user-initiated interaction loop. |
| 4 | Advanced Analytics | NO | Requires balance snapshot strategy decision (new table vs. computed from `trades`). Schema choice has long-term implications. Defer to Phase 5. |
| 5 | Seasonal Leaderboard Reset | NO | Requires tournament archival design and "Hall of Fame" read model. Scope is larger than it appears. Defer to Phase 5 after user volume justifies the complexity. |

---

## Feature 1: Referral System

### Overview

Every user receives a unique referral code embedded in a Telegram deep link. When a referee signs up through that link and completes their first trade, both parties receive a one-time 500 USDT bonus. The system is single-use and self-referral proof.

### User Stories

---

#### US-101: Generate and Share a Referral Link

**As a** registered user
**I want** a unique referral link I can share on Telegram
**So that** I can invite friends and earn a bonus when they trade

**Acceptance Criteria:**
- [ ] Given a user is logged in, When they open the Referral section, Then they see their unique link in the format `t.me/OpenClawBot?start=ref_<code>`
- [ ] Given the link is visible, When they tap "Share", Then the TG native share sheet opens with the pre-filled link text
- [ ] Given a user has already been assigned a code, When they reload the page, Then the same code is shown (codes are stable and never regenerate)
- [ ] Given a user views their referral page, When no referee has signed up yet, Then the pending referral count shows 0 and the bonus status shows "Waiting"

**Edge Cases:**
- EC-1: User opens referral screen before their row is fully inserted by the `handle_new_user` trigger — respond with 503 and retry from the client after 1 second
- EC-2: `nanoid` collision on code generation (extremely unlikely at 8 chars alphanumeric from a 36-char alphabet, ~2.8 trillion combinations) — retry once with a new code; if collision persists after 3 attempts, log and surface a generic error
- EC-3: TG Web App `shareUrl` API is unavailable on desktop — fall back to a copy-to-clipboard button

**Priority:** P0
**Effort:** M

---

#### US-102: Sign Up via a Referral Link

**As a** new user arriving via a TG deep link
**I want** my account to be linked to my referrer automatically
**So that** I receive my welcome bonus and my referrer gets credit

**Acceptance Criteria:**
- [ ] Given a user opens `t.me/OpenClawBot?start=ref_<code>`, When the TG Web App initialises, Then `initDataUnsafe.start_param` contains the code and the frontend passes it to the signup edge function
- [ ] Given a valid referral code is passed on signup, When the new user row is created, Then `users.referred_by` is set to the referrer's `user_id` and `users.referral_code_used` is set to the code
- [ ] Given an invalid or expired code is passed, When signup proceeds, Then the account is created normally with no referral linkage and no error shown to the user
- [ ] Given a user signs up without any referral link, When their account is created, Then `referred_by` remains NULL

**Edge Cases:**
- EC-1: Referral code belongs to a deleted/banned user — treat as invalid, create account without referral, log the orphaned code
- EC-2: User manually crafts a `start_param` with their own referral code — detect self-referral by comparing inbound code's `owner_id` to the new `tg_id`; reject silently, create account without referral
- EC-3: User has previously created an account (returning user) but arrives via a referral link — detect by `tg_id` already existing in `users`; ignore the referral param entirely, proceed to normal login
- EC-4: Two simultaneous signup requests with the same code race — the `UNIQUE` constraint on `users.referred_by` per referrer is not needed (multiple referees per referrer is valid); the atomicity concern is only on the individual referee row, handled by `handle_new_user` trigger

**Priority:** P0
**Effort:** M

---

#### US-103: Claim Referral Bonuses After First Trade

**As a** referrer
**I want** to automatically receive 500 USDT when my referee completes their first trade
**So that** I am rewarded for growing the community

**Acceptance Criteria:**
- [ ] Given a referee's first trade closes (status changes from `open` to `closed` or `liquidated`), When the `close-trade` or `scan-liquidations` edge function commits, Then the `award_referral_bonus` RPC is called atomically within the same transaction
- [ ] Given the RPC fires, When it executes, Then: the referee receives +500 USDT added to their balance, the referrer receives +500 USDT added to their balance, and a row is inserted into `referral_events` with `bonus_paid_at` timestamped
- [ ] Given the bonus has already been paid for this referee, When the RPC is called again (idempotent replay), Then no additional bonus is issued (enforced by `UNIQUE` on `referral_events.referee_id`)
- [ ] Given the bonus is paid, When both users view their balance, Then their balance reflects the +500 USDT addition
- [ ] Given the bonus is paid, When the referrer opens their Referral section, Then the referee appears under "Confirmed Referrals" with the bonus timestamp

**Edge Cases:**
- EC-1: Referee's first trade is a liquidation (not a voluntary close) — bonus still triggers; any completed first trade qualifies
- EC-2: Referrer's account is bankrupt at time of bonus — add the 500 USDT regardless; the referral bonus is not subject to bankruptcy checks
- EC-3: Referral event insert fails after balance updates commit — wrap the entire bonus disbursement in a single PL/pgSQL RPC (`award_referral_bonus_txn`) so all three writes (referee balance, referrer balance, referral_events row) are atomic
- EC-4: Referee account is deleted before first trade — `referral_events` insert will fail FK constraint; catch and log, no bonus issued

**Priority:** P0
**Effort:** S (leverages existing `execute_trade_txn` / `close_trade_txn` RPC pattern)

---

### DB Schema — Feature 1

```sql
-- Migration: 009_referral_system.sql

-- 1. Add columns to users table
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS referral_code    TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS referred_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS referral_bonus_earned NUMERIC(15,4) NOT NULL DEFAULT 0;

-- Index for code lookups during signup
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_referral_code
  ON users (referral_code)
  WHERE referral_code IS NOT NULL;

-- Index for "list my referees" query
CREATE INDEX IF NOT EXISTS idx_users_referred_by
  ON users (referred_by)
  WHERE referred_by IS NOT NULL;

-- 2. Referral events log (one row per completed referral)
CREATE TABLE IF NOT EXISTS referral_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  referee_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  bonus_paid_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  referrer_bonus  NUMERIC(15,4) NOT NULL DEFAULT 500,
  referee_bonus   NUMERIC(15,4) NOT NULL DEFAULT 500,
  UNIQUE (referee_id)   -- one referral payout per referee, ever
);

CREATE INDEX IF NOT EXISTS idx_referral_events_referrer
  ON referral_events (referrer_id);

-- 3. RLS
ALTER TABLE referral_events ENABLE ROW LEVEL SECURITY;

-- Users can read their own referral events (as referrer or referee)
CREATE POLICY "Users can read own referral events"
  ON referral_events FOR SELECT
  TO authenticated
  USING (auth.uid() = referrer_id OR auth.uid() = referee_id);

-- Only service_role may insert (all writes go through the RPC)
-- No INSERT/UPDATE/DELETE policies for authenticated role.

-- 4. Atomic bonus RPC
CREATE OR REPLACE FUNCTION award_referral_bonus_txn(
  p_referrer_id  UUID,
  p_referee_id   UUID,
  p_referrer_amt NUMERIC DEFAULT 500,
  p_referee_amt  NUMERIC DEFAULT 500
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Guard: skip if already paid (idempotent)
  IF EXISTS (SELECT 1 FROM referral_events WHERE referee_id = p_referee_id) THEN
    RETURN;
  END IF;

  -- Credit balances
  UPDATE users SET balance = balance + p_referee_amt  WHERE id = p_referee_id;
  UPDATE users SET balance = balance + p_referrer_amt WHERE id = p_referrer_id;
  UPDATE users SET referral_bonus_earned = referral_bonus_earned + p_referrer_amt
    WHERE id = p_referrer_id;

  -- Record event
  INSERT INTO referral_events (referrer_id, referee_id, referrer_bonus, referee_bonus)
  VALUES (p_referrer_id, p_referee_id, p_referrer_amt, p_referee_amt);
END;
$$;

-- 5. Code generation helper (called by handle_new_user trigger or signup edge function)
-- Codes are generated application-side (nanoid, 8 chars) and passed to INSERT.
-- The UNIQUE index on referral_code handles collision detection.
```

### API Spec — Feature 1

#### GET `/api/referral/me`
Returns the current user's referral code, link, and referral history.

**Auth:** Bearer JWT (standard)
**Response 200:**
```typescript
{
  referral_code: string;           // "ref_a7Bx92Kp"
  referral_link: string;           // "t.me/OpenClawBot?start=ref_a7Bx92Kp"
  referees: Array<{
    username: string;
    joined_at: string;             // ISO 8601
    bonus_paid_at: string | null;  // null = first trade not yet completed
  }>;
  total_bonus_earned: number;      // USDT
}
```
**Response 404:** User row not yet created (race on first open).

---

#### POST `/api/referral/register`
Called during signup to bind a referral code to the new user.

**Auth:** Bearer JWT
**Body:**
```typescript
{ referral_code: string }
```
**Response 200:** `{ success: true }`
**Response 200 (silent no-op):** `{ success: true, skipped: true }` — invalid code, self-referral, or returning user
**Response 400:** malformed body

**Implementation note:** This is called from `handle_new_user` edge function or the Next.js auth callback, not by the user directly. The response is always 200 to avoid leaking whether a code exists.

---

### Anti-Abuse Rules

| Rule | Enforcement Layer |
|------|-------------------|
| Self-referral blocked | Edge function: compare referral code owner to signing-up `tg_id` before DB write |
| One referral bonus per referee, ever | `UNIQUE (referee_id)` constraint on `referral_events` |
| One TG account = one user | Existing `users.tg_id UNIQUE` constraint (Phases 1–3) |
| Bonus only on first completed trade | `award_referral_bonus_txn` checks `referral_events` existence before paying |
| Referral code cannot be changed | No UPDATE path exposed; `referral_code` is write-once |

---

## Feature 2: Multiple AI Personalities

### Overview

Two additional OpenClaw AI personas join the leaderboard alongside the existing "Aggressive" (momentum) agent. Each persona is a separate `users` row with `is_human = false`, a distinct UUID, name, and icon slug. Each runs its own independent trading strategy via a new or extended edge function, on its own cron schedule.

The three personalities are:

| Personality | UUID Suffix | Strategy | Leverage | Cron |
|-------------|------------|----------|----------|------|
| OpenClaw Aggressive (existing) | `...0c1a0001` | Momentum (SMA-12 crossover) | 10x | Every 10 min |
| OpenClaw Conservative | `...0c1a0002` | Mean reversion (RSI-14 oversold/overbought) | 3x | Every 30 min |
| OpenClaw Chaos | `...0c1a0003` | Random direction, random leverage 1–20x | random | Every 15 min |

### User Stories

---

#### US-201: Compete Against Multiple AI Rivals

**As a** human player
**I want** to see three distinct AI personalities on the leaderboard
**So that** I have multiple benchmarks to beat and the competition feels alive

**Acceptance Criteria:**
- [ ] Given the leaderboard loads, When any user views it, Then all three OpenClaw personas appear with their unique names and icons (lobster emoji variants or icon slugs stored in `users.avatar_slug`)
- [ ] Given a human player's ROI surpasses a specific AI persona, When the leaderboard refreshes, Then the human's rank visually reflects the overtake
- [ ] Given a human player beats any AI persona's ROI, When the achievement evaluator runs, Then ACH-001 (Claw Crusher) progress increments (existing achievement; counts beating any AI persona, not just Aggressive)
- [ ] Given the leaderboard renders, When AI rows are displayed, Then each shows the personality name ("OpenClaw Conservative"), a distinct icon, and the `is_human = false` lobster marker

**Edge Cases:**
- EC-1: One AI persona goes bankrupt — it appears on the leaderboard at its last non-zero ROI until manually reset; no automatic reseeding in Phase 4
- EC-2: Two AI personas hold positions in opposite directions simultaneously — expected and valid; they are independent users with no coordination
- EC-3: All three AI personas are in the same leaderboard rank band — deterministic tie-breaking by `created_at ASC` (existing leaderboard behaviour)

**Priority:** P0
**Effort:** M

---

#### US-202: OpenClaw Conservative Trades Mean Reversion

**As a** system operator
**I want** the Conservative persona to trade against overbought/oversold conditions
**So that** it behaves predictably differently from the Aggressive persona

**Acceptance Criteria:**
- [ ] Given the Conservative cron fires, When RSI-14 (5-min candles) is above 70, Then the agent opens or holds a SHORT at 3x leverage
- [ ] Given RSI-14 is below 30, When the Conservative cron fires, Then the agent opens or holds a LONG at 3x leverage
- [ ] Given RSI-14 is between 30 and 70, When the cron fires, Then the agent closes any open position and holds cash
- [ ] Given a stop-loss threshold of 10% margin loss (vs. 5% for Aggressive), When the threshold is breached, Then the position is closed via `close_trade_txn` RPC

**Edge Cases:**
- EC-1: RSI cannot be computed (fewer than 14 candles returned) — skip cycle, log warning, do not trade
- EC-2: Price feed times out — same pattern as Aggressive: skip cycle, do not trade with stale data

**Priority:** P1
**Effort:** M

---

#### US-203: OpenClaw Chaos Trades Randomly

**As a** human player
**I want** the Chaos persona to be genuinely unpredictable
**So that** beating it feels like a meaningful random-variable benchmark

**Acceptance Criteria:**
- [ ] Given the Chaos cron fires, When the agent runs, Then direction (long/short) is chosen with 50/50 probability using `crypto.getRandomValues()`
- [ ] Given the direction is chosen, When the agent opens a position, Then leverage is drawn uniformly from integers [1, 20] using `crypto.getRandomValues()`
- [ ] Given Chaos already holds an open position, When the cron fires, Then there is a 30% chance it closes and re-randomises, and a 70% chance it holds
- [ ] Given the Chaos persona's balance drops below 500 USDT, When the cron fires, Then no new position is opened until balance recovers above 500 USDT (it will recover only via PnL on existing positions)

**Edge Cases:**
- EC-1: Chaos opens a 20x position and is immediately eligible for liquidation at the next `scan-liquidations` cycle — this is by design; bankruptcy is possible and acceptable for a Chaos persona
- EC-2: Chaos persona goes bankrupt — log it, stop trading (MIN_BALANCE guard), display on leaderboard at final ROI

**Priority:** P1
**Effort:** S (Chaos logic is simpler than Conservative; no technical indicator computation)

---

### DB Schema — Feature 2

```sql
-- Migration: 010_ai_personalities.sql

-- 1. Add avatar_slug to users for UI differentiation
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS avatar_slug TEXT;

-- 2. Seed Conservative persona
INSERT INTO users (
  id, tg_id, username, is_human, balance, roi, avatar_slug, created_at
) VALUES (
  '00000000-0000-0000-0000-00000c1a0002',
  -2,  -- reserved negative tg_id for AI agents
  'OpenClaw Conservative',
  false,
  10000,
  0,
  'claw-conservative',
  NOW()
) ON CONFLICT (id) DO NOTHING;

-- 3. Seed Chaos persona
INSERT INTO users (
  id, tg_id, username, is_human, balance, roi, avatar_slug, created_at
) VALUES (
  '00000000-0000-0000-0000-00000c1a0003',
  -3,
  'OpenClaw Chaos',
  false,
  10000,
  0,
  'claw-chaos',
  NOW()
) ON CONFLICT (id) DO NOTHING;

-- 4. Update existing Aggressive persona with avatar slug
UPDATE users
  SET avatar_slug = 'claw-aggressive'
WHERE id = '00000000-0000-0000-0000-00000c1a0001';

-- Note: No new tables required. All AI personas trade through existing
-- execute_trade_txn / close_trade_txn / liquidate_trade_txn RPCs.
-- RLS policies already permit service_role writes for any user_id.
```

### API Spec — Feature 2

No new public API endpoints. Two new internal Edge Functions are deployed:

#### `openclaw-conservative` (POST, cron-triggered every 30 min)
Internal function. No user-facing API. Mirrors the structure of `openclaw-trade/index.ts` with:
- `OPENCLAW_USER_ID = "00000000-0000-0000-0000-00000c1a0002"`
- `LEVERAGE = 3`
- `MARGIN_FRACTION = 0.03` (3% of balance per trade)
- `TRAILING_STOP_LOSS_FRACTION = 0.10` (10% — wider stop for slower strategy)
- Signal: RSI-14 on 5-min candles (> 70 = short, < 30 = long, 30–70 = hold/close)

#### `openclaw-chaos` (POST, cron-triggered every 15 min)
Internal function. No user-facing API. Key constants:
- `OPENCLAW_USER_ID = "00000000-0000-0000-0000-00000c1a0003"`
- Direction: `crypto.getRandomValues()` mod 2 (0 = long, 1 = short)
- Leverage: `crypto.getRandomValues()` mod 20 + 1 (uniform [1, 20])
- `HOLD_PROBABILITY = 0.70` — probability of not rebalancing on a given tick
- `MIN_BALANCE = 500`

**ACH-001 (Claw Crusher) amendment:** The `check-achievements` evaluator for ACH-001 currently receives `openclaw_roi` via `event_data`. In Phase 4, the calling code in `close-trade` must pass the ROI of whichever AI persona is the current leaderboard leader among `is_human = false` users, not a hardcoded value. This requires a single additional query in `close-trade` at settlement time.

---

## Feature 3: Price Alerts

### Overview

Users set threshold alerts for BTC/USDT or ETH/USDT prices. The existing `scan-liquidations` cron (60s) checks open alerts and fires a Telegram notification when the condition is met. Alerts are one-shot: they auto-disable after triggering. Each user may have at most 5 active alerts.

### User Stories

---

#### US-301: Create a Price Alert

**As a** human player
**I want** to set a price alert for BTC or ETH
**So that** I receive a TG notification at my target price without watching the screen

**Acceptance Criteria:**
- [ ] Given the user opens the Alerts section, When they tap "New Alert", Then they see a form with: symbol selector (BTC/USDT, ETH/USDT), condition selector (above / below), and a numeric price input
- [ ] Given the form is valid and submitted, When the alert is saved, Then a row appears in `price_alerts` with `is_active = true` and the user sees it in their alert list
- [ ] Given a user already has 5 active alerts, When they attempt to create a sixth, Then the form shows "Maximum 5 active alerts reached" and the create button is disabled
- [ ] Given a user creates an alert for "BTC/USDT above $100,000", When BTC has already passed $100,000 at the time of creation, Then the alert is saved but immediately flagged for evaluation on the next cron tick; it will trigger within 60 seconds if the condition is still met

**Edge Cases:**
- EC-1: User submits a price of 0 or negative — rejected with 400: "Price must be greater than 0"
- EC-2: User submits a price with more than 2 decimal places — round to 2 decimal places server-side before storing
- EC-3: User submits a price above the theoretical maximum for the symbol (e.g., BTC > $10,000,000) — accepted; the alert will simply never trigger
- EC-4: User deletes their TG account before the alert fires — the `telegram_chat_id` lookup returns null; the notification is skipped silently, the alert is still marked triggered

**Priority:** P0
**Effort:** S

---

#### US-302: Receive a Price Alert Notification

**As a** human player
**I want** to receive a TG message when my price target is hit
**So that** I can act on market movements without staying glued to the app

**Acceptance Criteria:**
- [ ] Given an active alert exists for "BTC/USDT above $100,000", When `scan-liquidations` fetches BTC at $100,001, Then the alert is triggered: a TG notification is sent, `price_alerts.is_active` is set to false, and `triggered_at` is stamped
- [ ] Given the notification is sent, When it arrives in TG, Then the message reads: "Price Alert: BTC/USDT has crossed above $100,000.00. Current price: $100,001.23"
- [ ] Given the alert has triggered, When the user opens the Alerts section, Then the alert appears in a "Triggered" tab with the timestamp and final price
- [ ] Given an alert triggers, When the `sendTelegramNotification` rate-limit check runs, Then price alerts are treated as a **Tier 1 Critical** notification type (bypasses global daily cap, respects hourly cap and quiet hours)

**Edge Cases:**
- EC-1: Price jumps from $99,500 to $100,500 in a single 60-second cron interval, crossing the threshold — alert triggers correctly; the condition check is "current price satisfies condition", not "price crossed in this interval"
- EC-2: Two alerts for the same user trigger in the same cron run — both are processed; the second notification will be suppressed by the existing 10-minute minimum-gap rate limiter in `telegram-notify.ts`; the second alert is still marked triggered and the second notification is queued via the outbox for the next available send window
- EC-3: Price feed fails during the cron scan — existing `scan-liquidations` behaviour: skip the symbol, do not trigger any alerts for that symbol, try again next tick
- EC-4: User's `telegram_chat_id` is null (user never sent a message to the bot) — skip the TG send, still mark the alert as triggered so it does not loop
- EC-5: Alert for "BTC/USDT below $100,000" when BTC is already at $98,000 at alert creation — triggers on the very next cron tick; document this as expected behaviour in the UI with a warning: "This alert will trigger immediately based on the current price"

**Priority:** P0
**Effort:** S

---

#### US-303: Manage Active Alerts

**As a** human player
**I want** to view and delete my alerts
**So that** I can keep my alert list relevant without clutter

**Acceptance Criteria:**
- [ ] Given the user opens the Alerts section, When the page loads, Then they see two tabs: "Active" (up to 5 rows) and "History" (last 20 triggered alerts, descending by `triggered_at`)
- [ ] Given an active alert is visible, When the user taps the delete icon and confirms, Then the alert row's `is_active` is set to false and `deleted_by_user = true`; it does not appear in the Active tab, and it does not appear in History (user-deleted alerts are hidden from History)
- [ ] Given a user has 0 active alerts, When the Active tab is empty, Then a prompt is shown: "No active alerts. Set one to get notified when your target price is hit."

**Edge Cases:**
- EC-1: User deletes an alert at the exact same moment the cron triggers it — `is_active = false` is the atomic guard; whichever write wins in the DB is the authoritative outcome; the cron uses `WHERE is_active = true` so a committed user-delete prevents the trigger
- EC-2: User requests their alert history beyond 20 rows — Phase 4 caps the History tab at 20 rows; pagination is deferred to Phase 5

**Priority:** P1
**Effort:** S

---

### DB Schema — Feature 3

```sql
-- Migration: 011_price_alerts.sql

CREATE TABLE IF NOT EXISTS price_alerts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  symbol          TEXT NOT NULL CHECK (symbol IN ('BTC/USDT', 'ETH/USDT')),
  condition       TEXT NOT NULL CHECK (condition IN ('above', 'below')),
  target_price    NUMERIC(18,2) NOT NULL CHECK (target_price > 0),
  is_active       BOOLEAN NOT NULL DEFAULT true,
  deleted_by_user BOOLEAN NOT NULL DEFAULT false,
  triggered_at    TIMESTAMPTZ,
  triggered_price NUMERIC(18,2),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fast lookup for the cron scanner: all active alerts by symbol
CREATE INDEX IF NOT EXISTS idx_price_alerts_active_symbol
  ON price_alerts (symbol, is_active)
  WHERE is_active = true;

-- Per-user alert management queries
CREATE INDEX IF NOT EXISTS idx_price_alerts_user
  ON price_alerts (user_id, created_at DESC);

-- RLS
ALTER TABLE price_alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own alerts"
  ON price_alerts FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own alerts"
  ON price_alerts FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own alerts"
  ON price_alerts FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- No DELETE policy: rows are soft-deleted via deleted_by_user = true.
-- This preserves audit trail and avoids phantom-read races with the cron.
```

### API Spec — Feature 3

#### GET `/api/alerts`
Returns the current user's active and historical alerts.

**Auth:** Bearer JWT
**Query params:** `tab=active|history` (default: `active`)
**Response 200:**
```typescript
{
  alerts: Array<{
    id: string;
    symbol: "BTC/USDT" | "ETH/USDT";
    condition: "above" | "below";
    target_price: number;
    is_active: boolean;
    triggered_at: string | null;   // ISO 8601
    triggered_price: number | null;
    created_at: string;
  }>;
  active_count: number;            // 0–5
  max_allowed: number;             // 5
}
```

---

#### POST `/api/alerts`
Creates a new price alert.

**Auth:** Bearer JWT
**Body:**
```typescript
{
  symbol: "BTC/USDT" | "ETH/USDT";
  condition: "above" | "below";
  target_price: number;
}
```
**Response 201:** `{ success: true, alert: AlertRow }`
**Response 400:** validation error (invalid symbol, condition, price <= 0)
**Response 409:** `{ error: "Maximum 5 active alerts reached" }` — user has 5 active alerts

**Implementation note:** The active count check and insert must be a single call to an RPC (`create_price_alert_txn`) that checks the count and inserts atomically to prevent TOCTOU races.

---

#### DELETE `/api/alerts/:id`
Soft-deletes an alert. Sets `is_active = false, deleted_by_user = true`.

**Auth:** Bearer JWT
**Response 200:** `{ success: true }`
**Response 404:** alert not found or does not belong to caller
**Response 409:** alert already triggered or already deleted

---

### Integration with `scan-liquidations`

The existing `scan-liquidations` edge function is extended with a new step inserted after Step 3 (per-symbol price fetch and liquidation processing) and before Step 4 (summary):

**New Step 3d: Price Alert Evaluation**

```typescript
// Pseudocode — to be implemented in scan-liquidations/index.ts

// For each symbol where a fresh price was obtained:
const { data: activeAlerts } = await supabase
  .from("price_alerts")
  .select("id, user_id, condition, target_price")
  .eq("symbol", symbol)
  .eq("is_active", true);

for (const alert of activeAlerts ?? []) {
  const triggered =
    (alert.condition === "above" && marketPrice >= alert.target_price) ||
    (alert.condition === "below" && marketPrice <= alert.target_price);

  if (!triggered) continue;

  // Atomic update: only one cron tick wins
  const { error } = await supabase
    .from("price_alerts")
    .update({
      is_active: false,
      triggered_at: new Date().toISOString(),
      triggered_price: marketPrice,
    })
    .eq("id", alert.id)
    .eq("is_active", true);  // optimistic lock: prevents double-trigger

  if (error) continue;  // another process already triggered it

  // Fire TG notification via existing infrastructure
  // Fetch user's telegram_chat_id and timezone_offset
  // Call sendTelegramNotification() with type "price_alert" (Tier 1)
}
```

**Notification type registration in `telegram-notify.ts`:**
Add `"price_alert"` to `NOTIFICATION_TIERS`:
```typescript
price_alert: { max_per_hour: 5, max_per_day: 20, tier: 1 },
```
Tier 1 ensures price alerts bypass the global daily cap. The `max_per_day: 20` cap prevents a user with 5 alerts all triggering in rapid succession from flooding themselves.

---

## Cross-Feature Considerations

### Lock Ordering (Existing Convention)

Phase 3 established a canonical lock ordering to prevent deadlocks: `users` before `trades` before event tables. Phase 4 additions must follow the same convention:

- `award_referral_bonus_txn`: lock order `users (referee)` → `users (referrer)` → `referral_events`. Use consistent UUID ordering (`ORDER BY id`) when locking both user rows to avoid deadlock.
- `create_price_alert_txn`: only touches `price_alerts`; no multi-table lock concern.
- Price alert trigger in `scan-liquidations`: alert update is a single-row update; no lock conflict with the liquidation path.

### Outbox Integration

EC-2 in US-302 notes that when two alerts trigger in the same cron run, the second TG notification is suppressed by the rate limiter but the alert is still marked triggered. To ensure delivery, the suppressed notification should be inserted into `event_outbox` for the `process-outbox` function to retry in the next available send window. The outbox schema and `process-outbox` function already exist.

### Achievement System

The ACH-001 (Claw Crusher) amendment described in Feature 2 is a required change. It does not alter the achievements schema. It requires a one-line query change in `close-trade/index.ts` to fetch the current best AI ROI instead of using a hardcoded comparison. Scope: S effort, should be bundled with Feature 2 deployment.

---

## Success Metrics

| Feature | Metric | Target (end of week 1) | Target (30 days post-launch) |
|---------|--------|------------------------|-------------------------------|
| Referral | New signups via referral link | 20% of new signups | 35% of new signups |
| Referral | Referral bonus pairs paid | >= 50 pairs in first week | >= 300 pairs |
| Referral | Self-referral attempt rate | < 1% of signup attempts | < 0.5% |
| AI Personalities | DAU who view leaderboard | Baseline (no change target) | +15% vs Phase 3 |
| AI Personalities | "Beat OpenClaw Conservative" share | N/A (new metric) | Tracked from day 1 |
| AI Personalities | ACH-001 unlock rate | +20% vs Phase 3 (more targets = more chances) | +35% |
| Price Alerts | Alerts created per DAU | >= 1.0 alerts/DAU | >= 1.5 alerts/DAU |
| Price Alerts | Alert trigger-to-notification delivery rate | >= 95% | >= 98% |
| Price Alerts | Users with >= 1 active alert (retention proxy) | 30% of DAU | 50% of DAU |

---

## Out of Scope for Phase 4

The following are explicitly deferred. Schema decisions in Phase 4 (particularly the `users` table additions) must not foreclose them.

| Feature | Deferral Reason | Phase 5 Pre-condition |
|---------|----------------|----------------------|
| Advanced Analytics (equity curve, win/loss histogram) | Requires balance snapshot strategy: computed from `trades` history vs. dedicated `balance_snapshots` table. Decision needs load testing data from current user volume. | Decision log on snapshot strategy |
| Seasonal Leaderboard Reset | Requires season archival table, "Hall of Fame" read model, and reset RPC that zeros balances without destroying history. More complex than it appears. | Minimum 500 MAU to justify reset mechanics |
| Referral Tiers (earn % of referee's profits) | Anti-abuse complexity compounds significantly. Phase 4 flat bonus is sufficient for launch. | Review referral abuse data after 30 days |
| Alert Recurring Mode (re-arm after trigger) | User research needed to validate whether one-shot or recurring is preferred. One-shot is safer default. | User feedback from Phase 4 |

---

## Deployment Checklist

### Database (run in order)
- [ ] `009_referral_system.sql` — referral columns, `referral_events` table, `award_referral_bonus_txn` RPC
- [ ] `010_ai_personalities.sql` — `avatar_slug` column, Conservative and Chaos persona seed rows
- [ ] `011_price_alerts.sql` — `price_alerts` table, RLS policies, indexes

### Edge Functions (deploy in order, test each before proceeding)
- [ ] `openclaw-conservative` — new function, 30-min cron
- [ ] `openclaw-chaos` — new function, 15-min cron
- [ ] `scan-liquidations` — updated with price alert evaluation step
- [ ] `close-trade` — updated to call `award_referral_bonus_txn` and pass best AI ROI to ACH-001 evaluator
- [ ] `telegram-notify` shared module — add `price_alert` to `NOTIFICATION_TIERS`

### Supabase Secrets (add before deploying functions)
No new secrets required for Phase 4. All three features use existing `SUPABASE_SERVICE_ROLE_KEY` and `TELEGRAM_BOT_TOKEN` secrets.

### Cron Jobs (register in Supabase Dashboard > Database > Cron)
- [ ] `openclaw-conservative`: `*/30 * * * *` → POST `openclaw-conservative`
- [ ] `openclaw-chaos`: `*/15 * * * *` → POST `openclaw-chaos`
- [ ] `scan-liquidations`: already registered at `* * * * *` — no change

### Frontend (Next.js)
- [ ] Referral page: `/app/referral/page.tsx` — display code, share button, referee list
- [ ] Alerts page: `/app/alerts/page.tsx` — create form, active/history tabs, delete action
- [ ] Leaderboard update: render `avatar_slug` and personality name for AI rows
- [ ] Notification for triggered alert: `telegram-notify.ts` type registration
