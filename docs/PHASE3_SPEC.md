# Phase 3: OpenClaw Arena — Feature Specification

> **Created**: 2026-03-29
> **Status**: Draft — Pending Development Sign-off
> **Sprint**: 2 weeks (2026-04-14 ~ 2026-04-27)
> **Author**: Business Analyst

---

## Priority Ordering

| # | Feature | Priority | Effort | Rationale |
|---|---------|----------|--------|-----------|
| 1 | Position History / Trade Journal | P0 | S | Zero new infra; data already exists. Closes the feedback loop every trader needs. High perceived value, low risk. Build first to deliver immediate user value while Phase 3 infra lands. |
| 2 | Daily Reward / Streak System | P1 | M | Addresses the single biggest retention risk: idle accounts bleeding into churn. Directly drives DAU. Must land before achievement system since streaks feed into achievements. |
| 3 | Notification System | P2 | M | Amplifies all other features. Liquidation alerts make Feature 1 visceral; streak reminders power Feature 2; rivalry pings are organic growth. Deferred to P2 because it requires Telegram Bot API setup (operational overhead) and the game must be worth notifying about first. |
| 4 | Achievement System | P3 | L | High engagement ceiling but highest build complexity (progress tracking, badge rendering, edge-case combinations). Depends on streak data from Feature 2 and trade history from Feature 1. Build last when the engagement substrate is in place. |

---

## Feature 1: Position History / Trade Journal (P0)

### Context

The DB already contains closed/liquidated trades with `entry_price`, `exit_price`, `realised_pnl`, `leverage`, `margin`, `status`. This is a pure read-layer feature. No new tables required.

### User Stories

**US-1A**: As a trader, I want to see every trade I have ever opened (open, closed, liquidated) in reverse chronological order so I can understand my trading history without reconstructing it from memory.

**Acceptance Criteria:**
- Given I open the Trade Journal, When the page loads, Then I see a paginated list of all my trades sorted by `created_at DESC`
- Given a trade list, When I look at each row, Then I see: symbol, direction (LONG/SHORT), leverage, entry price, exit price (or "Open"), realised PnL (colored green/red), status badge (OPEN / CLOSED / LIQUIDATED)
- Given a closed or liquidated trade, When I tap it, Then I see the full per-trade breakdown: margin used, settlement amount, duration held, ROI% on that trade
- Given the list, When I apply a filter by symbol (BTC/ETH) or by status (closed/liquidated), Then only matching trades are shown
- Given more than 20 trades, When the page loads, Then only the first 20 are fetched; scrolling to the bottom triggers the next page (cursor-based pagination)

**Edge Cases:**
- EC-1A: User has zero trades — show empty state ("No trades yet. Open your first position.")
- EC-1B: Trade is currently open — `exit_price` and `realised_pnl` are null; display live unrealised PnL computed client-side from current price
- EC-1C: Liquidated trade — `exit_price` equals `liquidation_price`, `realised_pnl` equals `-margin`; display "LIQUIDATED" badge in error color
- EC-1D: Tournament trade — trade has `tournament_id` set; display a tournament name badge on the row

**Priority:** P0
**Effort:** S

---

**US-1B**: As a trader, I want to see aggregate statistics (win rate, total PnL, best trade, worst trade) so I can measure my skill improvement over time.

**Acceptance Criteria:**
- Given the Trade Journal, When I view the stats header, Then I see: total trades closed, win rate (% of closed trades with positive PnL), cumulative realised PnL, single best trade PnL, single worst trade PnL
- Given the stats, When all trades are filtered to a specific symbol, Then stats recalculate for that subset only
- Given I have no closed trades (only open), Then all stat fields show "--" (not zero) to avoid misleading data

**Edge Cases:**
- EC-1E: All trades were liquidations — win rate = 0%, show it accurately without division errors
- EC-1F: Stats query runs over 1000+ trade rows — aggregate computed server-side in the Edge Function, not client-side

**Priority:** P0
**Effort:** S

---

### API Endpoint Specs

| Endpoint | Method | Auth | Request | Response |
|----------|--------|------|---------|----------|
| `get-trade-history` | GET | JWT | `?symbol=BTC%2FUSDT&status=closed&limit=20&cursor=<uuid>` | `{ trades: Trade[], next_cursor: string \| null, stats: AggregateStats }` |

```typescript
// Response types
interface TradeHistoryItem {
  id: string;
  symbol: string;
  direction: 'long' | 'short';
  leverage: number;
  margin: number;
  entry_price: number;
  exit_price: number | null;
  realised_pnl: number | null;
  status: 'open' | 'closed' | 'liquidated';
  tournament_id: string | null;
  tournament_name: string | null;
  created_at: string;
  closed_at: string | null;
}

interface AggregateStats {
  total_closed: number;
  win_rate: number | null;       // null if no closed trades
  cumulative_pnl: number | null;
  best_trade_pnl: number | null;
  worst_trade_pnl: number | null;
}
```

**Implementation notes:**
- Cursor pagination using `id < cursor` on `trades` (UUID v4 is not time-ordered — use `created_at < cursor_created_at` with composite index)
- Stats computed in a single SQL aggregate query, not in application code
- RLS: users can only read their own trades (existing policy covers this)
- Join `tournaments(name)` via `trades.tournament_id` for the badge

### New DB Objects

No new tables. One new index and one view are sufficient:

```sql
-- Index for history page query (user + time sort + status filter)
CREATE INDEX idx_trades_history
ON public.trades (user_id, created_at DESC, status);

-- View for the join (avoids duplicating join logic across Edge Functions)
CREATE OR REPLACE VIEW public.trade_history_view AS
SELECT
  t.id,
  t.user_id,
  t.symbol,
  t.direction,
  t.leverage,
  t.margin,
  t.entry_price,
  t.exit_price,
  t.realised_pnl,
  t.status,
  t.tournament_id,
  t.created_at,
  t.updated_at AS closed_at,
  tn.name AS tournament_name
FROM public.trades t
LEFT JOIN public.tournaments tn ON tn.id = t.tournament_id;
```

---

## Feature 2: Daily Reward / Streak System (P1)

### Context

Every day a user opens the Telegram Web App (triggering the silent-login flow), we detect if this is their first visit today. If so, award a bonus and update their streak counter. A missed day resets the streak to zero. Consecutive days multiply the bonus.

### User Stories

**US-2A**: As a trader, I want to receive a daily login bonus when I open the app so that I have a concrete reason to return every day even when I have no open positions.

**Acceptance Criteria:**
- Given it is a new calendar day (UTC) since my last claim, When I open the app, Then I receive a popup showing "Day N streak! +X USDT credited" and my balance increases immediately
- Given I already claimed today, When I open the app again in the same day, Then no bonus is awarded and no popup appears
- Given my last claim was yesterday, When I open the app today, Then my streak increments by 1
- Given my last claim was 2+ days ago, When I open the app, Then my streak resets to 1 and I receive the Day 1 bonus amount
- Given a streak of 7+ days, When I claim, Then the multiplier is capped at the Day 7 tier (no unbounded scaling)

**Bonus schedule (MVP):**

| Streak Day | Bonus (USDT) |
|------------|-------------|
| 1 | 100 |
| 2 | 150 |
| 3 | 200 |
| 4 | 250 |
| 5 | 350 |
| 6 | 500 |
| 7+ | 750 |

**Edge Cases:**
- EC-2A: User opens app at 23:59 UTC and again at 00:01 UTC the next day — both are valid daily claims; streak increments to 2. Date boundary is UTC midnight, not rolling 24-hour window
- EC-2B: User with 0 balance (fully bankrupt after liquidations) — still eligible for daily bonus; this is the recovery mechanic
- EC-2C: Concurrent requests on app open (user double-taps, TG sends init twice) — `claim-daily-reward` must be idempotent; use `INSERT ... ON CONFLICT DO NOTHING` on `daily_claims` with a `(user_id, claim_date)` unique constraint
- EC-2D: User spoofs the client clock — `claim_date` is computed server-side using `NOW() AT TIME ZONE 'UTC'`; client timestamp is ignored entirely
- EC-2E: OpenClaw AI user — daily reward only applies to `is_human = true` users; filter in the RPC

**Priority:** P1
**Effort:** M

---

**US-2B**: As a trader, I want to see my current streak and the next day's bonus amount on my profile so I know what I will earn by returning tomorrow.

**Acceptance Criteria:**
- Given I am logged in, When I view the main page header or profile section, Then I see "Streak: N days" and "Tomorrow: +X USDT"
- Given streak = 0 (never claimed or reset), When I view the streak widget, Then it shows "Streak: 0 — Come back tomorrow for 100 USDT!"
- Given streak = 7+, When I view the widget, Then it shows the max tier (750 USDT) for "Tomorrow" to signal the plateau

**Edge Cases:**
- EC-2F: User views the streak widget before claiming today — widget shows yesterday's streak count and highlights the "Claim Now" call-to-action
- EC-2G: Streak widget data is fetched as part of the session bootstrap call (same round-trip as balance fetch) to avoid a separate loading state

**Priority:** P1
**Effort:** S

---

### API Endpoint Specs

| Endpoint | Method | Auth | Request | Response |
|----------|--------|------|---------|----------|
| `claim-daily-reward` | POST | JWT | `{}` (empty body) | `{ already_claimed: bool, streak: int, bonus_amount: number, new_balance: number }` |
| `get-streak-status` | GET | JWT | — | `{ streak: int, last_claim_date: string, claimed_today: bool, next_bonus: number }` |

**Implementation notes:**
- `claim-daily-reward` is called automatically on every app open by the frontend; the `already_claimed: true` response is silent (no popup)
- Balance update must go through `award_daily_reward_txn` RPC (SECURITY DEFINER) to keep the atomic `UPDATE users SET balance = balance + bonus` server-side and covered by the existing `balance >= 0` invariant
- `get-streak-status` can be combined with the session bootstrap query to avoid a dedicated round-trip

### New DB Objects

```sql
-- New table: daily_claims
CREATE TABLE public.daily_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id),
  claim_date DATE NOT NULL,                    -- UTC date, server-computed
  streak_day INT NOT NULL CHECK (streak_day >= 1),
  bonus_amount NUMERIC(18, 4) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT daily_claims_user_date_unique UNIQUE (user_id, claim_date)
);

CREATE INDEX idx_daily_claims_user_id ON public.daily_claims (user_id, claim_date DESC);

ALTER TABLE public.daily_claims ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own daily claims"
ON public.daily_claims FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- New columns on users table
ALTER TABLE public.users
  ADD COLUMN current_streak INT NOT NULL DEFAULT 0,
  ADD COLUMN last_claim_date DATE;

-- RPC: award_daily_reward_txn
-- SECURITY DEFINER, called only by claim-daily-reward Edge Function
-- 1. SELECT ... FOR UPDATE on users row
-- 2. Compute claim_date = NOW() AT TIME ZONE 'UTC' :: DATE
-- 3. Check daily_claims for (user_id, claim_date) — if exists, return already_claimed
-- 4. Compute streak: if last_claim_date = claim_date - 1 then streak = current_streak + 1 else 1
-- 5. Look up bonus from schedule (CASE WHEN streak >= 7 THEN 750 ...)
-- 6. UPDATE users SET balance = balance + bonus, current_streak = streak, last_claim_date = claim_date
-- 7. INSERT INTO daily_claims (...) ON CONFLICT DO NOTHING
-- 8. Return (streak, bonus_amount, new_balance, already_claimed)
```

**Migration:** `008_daily_rewards.sql`

---

## Feature 3: Notification System (P2)

### Context

Notifications are sent server-side via Telegram Bot API `sendMessage`. There is no persistent connection from the server to the client — the Telegram Bot acts as the delivery channel. The bot token is stored as a Supabase Secret. Notifications are fire-and-forget (failures are logged, not retried in MVP).

### User Stories

**US-3A**: As a trader, I want to receive a Telegram message when my position is liquidated so that I am immediately aware of the loss without having the app open.

**Acceptance Criteria:**
- Given a liquidation event fires in `scan-liquidations`, When the trade is confirmed liquidated, Then a Telegram message is sent to the user: "Your [LONG/SHORT] [symbol] [leverage]x position was liquidated. Loss: -[margin] USDT. Balance: [new_balance] USDT"
- Given the message is sent, When I tap it in Telegram, Then it deep-links back into the TG Web App
- Given the Telegram Bot API call fails (network error, user blocked the bot), When the error is caught, Then the liquidation itself is NOT rolled back — the notification failure is logged and swallowed

**Edge Cases:**
- EC-3A: User has never started the bot (no `chat_id` on file) — notification silently skipped; liquidation proceeds normally
- EC-3B: User blocked the bot — Telegram returns 403; caught and logged, no retry
- EC-3C: Multiple positions liquidated in one scanner cycle — one notification per liquidated trade, not batched (MVP); rate limit risk is acceptable at MVP scale
- EC-3D: OpenClaw AI user liquidated — do not send a notification (OpenClaw has no Telegram `chat_id`)

**Priority:** P2
**Effort:** M

---

**US-3B**: As a trader, I want to receive a Telegram reminder 1 hour before a tournament I am registered for starts so that I don't miss it.

**Acceptance Criteria:**
- Given I have joined a tournament with status = 'upcoming', When the tournament `start_at` is 60 minutes away (within the cron window), Then I receive: "Tournament '[name]' starts in 1 hour! Open the Arena to trade."
- Given the tournament status transitions to 'active', When the cron checks for reminders, Then no further pre-start reminders are sent for that tournament
- Given I joined a tournament that already started (late join path), Then no reminder is sent retroactively

**Edge Cases:**
- EC-3E: Cron fires at 59-minute mark due to jitter — still sends reminder; window is 55-65 minutes before `start_at` (not exactly 60)
- EC-3F: User is registered for two tournaments starting within the same cron window — two separate messages are sent

**Priority:** P2
**Effort:** S (piggybacks on existing tournament cron)

---

**US-3C**: As a trader, I want to receive a rivalry alert when OpenClaw overtakes me on the global leaderboard so that I feel motivated to reclaim my rank.

**Acceptance Criteria:**
- Given I am ranked N on the leaderboard, When OpenClaw's ROI crosses above mine (detected on the next leaderboard refresh), Then I receive: "OpenClaw just passed you on the leaderboard! Current rank: [N+1]. Fight back."
- Given OpenClaw overtakes multiple users in one ROI update, When messages are sent, Then each affected user gets one message (not one message per position gained)
- Given I am already ranked below OpenClaw, When OpenClaw's ROI increases further, Then no new notification is sent (only send on the crossing event)

**Edge Cases:**
- EC-3G: Detecting the "crossing event" requires comparing leaderboard state before and after each OpenClaw trade — store `openclaw_previous_rank` in memory within the `openclaw-trade` function, compare after trade settlement
- EC-3H: OpenClaw overtakes and then falls back below within the same cron window — send the overtake notification; do not send a "reclaimed" notification in MVP
- EC-3I: User has notifications disabled in Telegram — Bot API returns error; log and continue

**Priority:** P2
**Effort:** M

---

### API Endpoint Specs

No new public endpoints. Notification logic is embedded in existing Edge Functions.

**New shared utility:** `supabase/functions/_shared/telegram-notify.ts`

```typescript
interface NotificationPayload {
  chat_id: string;           // Telegram chat_id (= tg_id for DM)
  message: string;           // Plain text message
  deep_link?: string;        // Optional: t.me/BotName/AppName
}

// sendTelegramNotification: fire-and-forget, never throws
async function sendTelegramNotification(payload: NotificationPayload): Promise<void>;
```

**New internal cron endpoint:** `send-tournament-reminders`

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `send-tournament-reminders` | POST | service_role | Queries tournaments starting in 55-65 min, sends reminders to all participants with a `tg_id` |

**Changes to existing endpoints:**
- `scan-liquidations`: After each successful liquidation, call `sendTelegramNotification` for the affected user
- `openclaw-trade`: After trade settlement, compare pre/post leaderboard ranks; send rivalry alerts to overtaken users

### New DB Objects

```sql
-- New column on users table: store Telegram chat_id for Bot DMs
-- For TG Web App users, chat_id = tg_id (they are the same for private chats)
ALTER TABLE public.users
  ADD COLUMN tg_chat_id TEXT;              -- populated on first app open

-- New column on tournament_participants: track if reminder was sent
ALTER TABLE public.tournament_participants
  ADD COLUMN reminder_sent_at TIMESTAMPTZ; -- NULL = not yet sent

-- No new tables required for MVP. notification_log is deferred to Phase 4.
```

**Migration:** `009_notifications.sql`

**Supabase Secret required:** `TELEGRAM_BOT_TOKEN`

---

## Feature 4: Achievement System (P3)

### Context

Achievements are milestone badges earned by crossing quantifiable thresholds. They are computed lazily (evaluated when a relevant event fires) and stored permanently once unlocked. Progress toward incomplete achievements is tracked via a `progress` counter. Badge display appears on the leaderboard row and profile.

### User Stories

**US-4A**: As a trader, I want to earn badges for notable milestones so that I have long-term goals beyond the current tournament and a visible status symbol on the leaderboard.

**Acceptance Criteria:**
- Given I beat OpenClaw's ROI for the 3rd time (end of a session or tournament), When the achievement check runs, Then I receive a "Claw Crusher" badge and a Telegram congratulation message
- Given I survive a 100x leveraged position without liquidation (close it profitably or at a loss but not liquidated), When the trade closes, Then I receive the "Daredevil" badge
- Given I finish in the Top 10 of any completed tournament, When the settlement runs, Then I receive the "Arena Elite" badge
- Given I close a trade with ROI > 50% on a single position, When the trade closes, Then I receive the "Golden Claw" badge
- Given I have earned a badge, When I view the leaderboard, Then my row shows a badge icon next to my username
- Given an achievement I haven't earned, When I view my profile, Then I see the achievement name, description, and current progress (e.g., "2/3 OpenClaw victories")

**Edge Cases:**
- EC-4A: Same badge triggered twice (e.g., user beats OpenClaw a 4th time) — `INSERT INTO user_achievements ... ON CONFLICT DO NOTHING`; achievements are awarded exactly once
- EC-4B: Achievement check runs in the same transaction as the triggering event (close trade, settle tournament) — use a post-transaction background call to avoid extending lock duration on financial RPCs; achievement writes are non-blocking
- EC-4C: OpenClaw ROI comparison for "Claw Crusher" — compare user's session ROI (current balance / starting balance at session open) vs OpenClaw's ROI at the same timestamp; define "beating OpenClaw" as having higher ROI at the moment of trade close
- EC-4D: Tournament Top 10 when tournament has fewer than 10 participants — "Top 10" means rank 1 in a 5-person tournament; the threshold is the lesser of 10 and total participants
- EC-4E: User earns multiple achievements from the same event (e.g., closes a 100x trade with >50% ROI) — all applicable achievements are awarded in a single batch check

**Priority:** P3
**Effort:** L

---

**US-4B**: As a trader, I want to see my achievement progress in real-time so that I know how close I am to the next badge.

**Acceptance Criteria:**
- Given I have 2 out of 3 required OpenClaw victories for "Claw Crusher", When I view my achievements page, Then I see a progress bar at 66% and "2/3" text
- Given I have unlocked an achievement, When I view the achievements page, Then the badge is shown in full color with the unlock date
- Given I have not started progress on an achievement, When I view the list, Then the badge appears grayed out with 0/N progress

**Edge Cases:**
- EC-4F: Achievement progress is computed from `user_achievements_progress` table, not recalculated from raw trade history on every request — avoids expensive full-scan queries
- EC-4G: Progress counter can only increase, never decrease (no un-beating OpenClaw)

**Priority:** P3
**Effort:** M

---

### MVP Achievement Set

| ID | Name | Trigger | Threshold | Progress Tracked |
|----|------|---------|-----------|-----------------|
| ACH-001 | Claw Crusher | Beat OpenClaw's ROI at trade close | 3 times | Yes (0-3) |
| ACH-002 | Daredevil | Close a 100x position without liquidation | 1 time | No |
| ACH-003 | Arena Elite | Finish Top 10 in any tournament | 1 time | No |
| ACH-004 | Golden Claw | Single trade ROI > 50% | 1 time | No |
| ACH-005 | Streak Keeper | Maintain a 7-day login streak | 7 consecutive days | Yes (0-7) |
| ACH-006 | Survivor | Have a position open for 24+ hours without liquidation | 1 time | No |

### API Endpoint Specs

| Endpoint | Method | Auth | Request | Response |
|----------|--------|------|---------|----------|
| `get-achievements` | GET | JWT | — | `{ earned: Achievement[], in_progress: AchievementProgress[], locked: Achievement[] }` |
| `check-achievements` | POST | service_role (internal) | `{ user_id, trigger_event, event_data }` | `{ newly_earned: Achievement[] }` |

```typescript
interface Achievement {
  id: string;                  // e.g., 'ACH-001'
  name: string;
  description: string;
  icon_key: string;            // maps to a frontend icon component
  earned_at: string | null;
}

interface AchievementProgress {
  achievement_id: string;
  current: number;
  required: number;
}

type TriggerEvent =
  | 'trade_closed'
  | 'trade_liquidated'
  | 'tournament_settled'
  | 'streak_claimed';
```

**`check-achievements` is called internally (not by the frontend)** from:
- `close-trade` Edge Function (after successful close)
- `settle-tournament` Edge Function (after final rankings are written)
- `claim-daily-reward` Edge Function (after streak update)

### New DB Objects

```sql
-- Achievement definitions (static reference table, seeded in migration)
CREATE TABLE public.achievements (
  id TEXT PRIMARY KEY,             -- 'ACH-001', 'ACH-002', etc.
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  icon_key TEXT NOT NULL,
  required_count INT NOT NULL DEFAULT 1,  -- threshold for progress-tracked achievements
  is_progress_tracked BOOLEAN NOT NULL DEFAULT false
);

-- Earned achievements (immutable once inserted)
CREATE TABLE public.user_achievements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id),
  achievement_id TEXT NOT NULL REFERENCES public.achievements(id),
  earned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT user_achievements_unique UNIQUE (user_id, achievement_id)
);

CREATE INDEX idx_user_achievements_user_id ON public.user_achievements (user_id);

ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own achievements"
ON public.user_achievements FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Progress tracking for multi-step achievements
CREATE TABLE public.user_achievement_progress (
  user_id UUID NOT NULL REFERENCES public.users(id),
  achievement_id TEXT NOT NULL REFERENCES public.achievements(id),
  current_count INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, achievement_id)
);

ALTER TABLE public.user_achievement_progress ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own achievement progress"
ON public.user_achievement_progress FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Seed achievement definitions
INSERT INTO public.achievements (id, name, description, icon_key, required_count, is_progress_tracked) VALUES
  ('ACH-001', 'Claw Crusher', 'Beat OpenClaw''s ROI 3 times', 'trophy', 3, true),
  ('ACH-002', 'Daredevil', 'Close a 100x position without liquidation', 'lightning', 1, false),
  ('ACH-003', 'Arena Elite', 'Finish Top 10 in any tournament', 'medal', 1, false),
  ('ACH-004', 'Golden Claw', 'Achieve >50% ROI on a single trade', 'star', 1, false),
  ('ACH-005', 'Streak Keeper', 'Maintain a 7-day login streak', 'fire', 7, true),
  ('ACH-006', 'Survivor', 'Hold a position open for 24+ hours without liquidation', 'shield', 1, false);
```

**Migration:** `010_achievements.sql`

---

## Success Metrics

| Feature | Metric | Target (30 days post-launch) | Measurement |
|---------|--------|------------------------------|-------------|
| Trade Journal | Journal page views per DAU | > 60% of sessions include a journal view | Page view tracking |
| Trade Journal | Filter usage rate | > 25% of journal views use a filter | Filter interaction events |
| Daily Rewards | D1 retention (day-after return rate) | > 45% (baseline est. 25%) | `daily_claims` count vs new users |
| Daily Rewards | 7-day streak holders | > 10% of MAU maintain a 7-day streak | `current_streak >= 7` in `users` |
| Notifications | Liquidation notification open rate | > 30% of notifications result in app re-open within 1 hour | TG Web App launch events post-notification |
| Notifications | Tournament reminder effectiveness | > 20% lift in tournament participation rate | Participants who joined after reminder vs before |
| Achievements | Achievements earned per WAU | > 0.5 achievements per weekly active user | `user_achievements` insert rate |
| Achievements | "Claw Crusher" completion rate | > 5% of WAU earn it within 30 days | `user_achievements WHERE achievement_id = 'ACH-001'` |

---

## Migration Plan

| Migration | Contents |
|-----------|----------|
| `008_daily_rewards.sql` | `daily_claims` table, `users.current_streak`, `users.last_claim_date`, `award_daily_reward_txn` RPC |
| `009_notifications.sql` | `users.tg_chat_id`, `tournament_participants.reminder_sent_at` |
| `010_achievements.sql` | `achievements` seed table, `user_achievements`, `user_achievement_progress`, RLS policies |
| `011_trade_history_index.sql` | `idx_trades_history` composite index, `trade_history_view` |

---

## 2-Week Sprint Plan

### Week 1: Trade Journal + Daily Rewards

| Day | Task |
|-----|------|
| 1 | Migration 011: index + view. `get-trade-history` Edge Function with cursor pagination and aggregate stats |
| 2 | Trade Journal frontend: list page, per-trade detail drawer, filter controls |
| 3 | Migration 008: `daily_claims` table + `award_daily_reward_txn` RPC |
| 4 | `claim-daily-reward` + `get-streak-status` Edge Functions |
| 5 | Streak widget on main page; daily reward popup on app open; integration test: claim → balance update → idempotency |

### Week 2: Notifications + Achievements

| Day | Task |
|-----|------|
| 6 | `telegram-notify.ts` shared utility; wire into `scan-liquidations` for liquidation alerts; test with real Bot token |
| 7 | `send-tournament-reminders` cron function; `tournament_participants.reminder_sent_at` guard; rivalry alert in `openclaw-trade` |
| 8 | Migration 010: achievement tables + seed data. `check-achievements` internal Edge Function |
| 9 | Wire `check-achievements` into `close-trade`, `settle-tournament`, `claim-daily-reward` |
| 10 | `get-achievements` endpoint + Achievements page frontend (earned/in-progress/locked states) |
| 11-12 | Badge display on leaderboard rows; notification for newly earned achievements |
| 13-14 | Full QA on Telegram (iOS + Android): streak reset edge case, concurrent claim idempotency, bot DM delivery |

---

## Open Questions (Require Product Decision Before Build)

| # | Question | Impact | Default if Unresolved |
|---|----------|--------|----------------------|
| OQ-1 | Should OpenClaw participate in tournaments and be eligible for top-3 prizes? | Affects tournament settlement logic and rival notification triggers | No — OpenClaw is a benchmark, not a tournament participant |
| OQ-2 | Daily reward: does the bonus scale with account balance or is it a flat amount regardless of current balance? | A 100 USDT bonus is meaningful at 500 USDT balance but trivial at 100,000 USDT | Flat amount (MVP); review after launch data |
| OQ-3 | Notification opt-out: do users need an explicit opt-out flow, or is bot-block sufficient? | Regulatory consideration in some TG communities; also affects UX | Bot-block is sufficient for MVP; explicit opt-out in Phase 4 |
| OQ-4 | Leaderboard display: how many badge icons show per user row before it becomes cluttered? | Affects leaderboard UI design | Cap at 3 most recently earned badges per row |
