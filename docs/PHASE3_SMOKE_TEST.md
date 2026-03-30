# OpenClaw Arena — Phase 3 Smoke Test Checklist

> **For**: Product Owner Manual Acceptance
> **Environment**: Telegram iOS/Android App + Supabase Dashboard + Edge Function curl invocations
> **Date**: 2026-03-29
> **Phase**: 3 (Trade History, Daily Rewards, Notifications, Achievements)

---

## Prerequisites

Before running any test case, verify the following are in place:

- [ ] All Phase 3 migrations applied in order:
  - `008_daily_rewards.sql` — `daily_claims` table, `users.current_streak`, `users.last_claim_date`, `award_daily_reward_txn` RPC
  - `009_notifications.sql` — `users.tg_chat_id`, `tournament_participants.reminder_sent_at`, `notification_log` table, `users.streak_reminder_sent_today`
  - `010_achievements.sql` — `achievements` seed, `user_achievements`, `user_achievement_progress`, RLS policies
  - `011_trade_history_index.sql` — `idx_trades_history` composite index, `trade_history_view`
- [ ] Phase 3 Edge Functions deployed: `get-trade-history`, `claim-daily-reward`, `send-notifications`, `check-achievements`, `get-achievements`
- [ ] Phase 1 + 2 Edge Functions still deployed: `market-oracle`, `execute-trade`, `close-trade`, `scan-liquidations`, `openclaw-trade`, `generate-api-key`, `join-tournament`, `settle-tournament`
- [ ] `TELEGRAM_BOT_TOKEN` Supabase Secret is set
- [ ] OpenClaw seeded user confirmed: `SELECT id, is_human, balance FROM public.users WHERE id = '00000000-0000-0000-0000-00000c1a0001'` returns `is_human = false`
- [ ] 6 achievement definitions seeded: `SELECT id, name FROM public.achievements ORDER BY id` returns ACH-001 through ACH-006
- [ ] Test user A has at least 25 closed/liquidated trades (for pagination tests); if not, insert synthetic rows via the Dashboard
- [ ] `trade_history_view` is accessible: `SELECT COUNT(*) FROM public.trade_history_view` returns a number without error
- [ ] Frontend deployed with `/history` page, `/achievements` page, and `StreakWidget` component

---

## Section A — Trade History

---

### TC-A1: Basic History Fetch — First Page Returns 20 Trades in Reverse Chronological Order

**Precondition:**
Test user A has at least 25 trades (any mix of open/closed/liquidated) in the `trades` table.

**Steps:**
1. Open the TG Web App as test user A.
2. Navigate to the `/history` page.
3. Observe the initial load.

**Expected:**
- Exactly 20 trade rows are displayed on first load (not 21, not fewer unless the user has fewer than 20 total).
- Rows appear in reverse chronological order (newest trade at top, oldest at bottom of the page).
- Each row shows: symbol, direction (LONG/SHORT), leverage, entry price, realised PnL (or "Open"), status badge.
- Aggregate stats header is visible above the list: total closed, win rate (percentage), cumulative PnL, best trade, worst trade.
- No JavaScript errors in the browser console.

**Status:** [ ] Pass / Fail

---

### TC-A2: Cursor Pagination — Scrolling Past 20 Trades Loads the Next Page

**Precondition:**
TC-A1 completed. Test user A has more than 20 trades.

**Steps:**
1. On the `/history` page, scroll to the bottom of the 20-item list.
2. Observe the network request triggered.
3. Inspect the Edge Function invocation via the Supabase Dashboard logs or browser DevTools (Network tab).

**Expected:**
- A second `GET get-trade-history` request fires with a `cursor=<ISO date string>` query parameter matching the `created_at` of the 20th row.
- The response contains the next batch of trades (up to 20 more), all with `created_at` strictly earlier than the cursor value.
- The combined list now shows 40 rows (or fewer if the user has between 21 and 40 trades total).
- No trade appears twice across both pages (no duplicate rows after scrolling).
- If the user has 25 trades, the second page contains exactly 5 rows and `next_cursor` in the response is `null`.

**Status:** [ ] Pass / Fail

---

### TC-A3: Status Filter — "Liquidated" Filter Returns Only Liquidated Trades

**Precondition:**
Test user A has at least one liquidated trade and at least one closed trade.

**Steps:**
1. On the `/history` page, apply the "Liquidated" status filter.
2. Observe the updated trade list.
3. Verify the aggregate stats header updates.

**Expected:**
- Every visible row has a "LIQUIDATED" badge; no "CLOSED" or "OPEN" rows are shown.
- The aggregate stats recalculate to reflect only the filtered subset (win rate = 0%, cumulative PnL equals sum of all `-margin` values for liquidated trades).
- The `get-trade-history` Edge Function was called with `?status=liquidated` in the URL.

**Status:** [ ] Pass / Fail

---

### TC-A4: Symbol Filter — "BTC/USDT" Filter Scopes Stats to That Symbol Only

**Precondition:**
Test user A has both BTC/USDT and ETH/USDT trades.

**Steps:**
1. Apply the "BTC/USDT" symbol filter on the `/history` page.
2. Check that the list and stats change.

**Expected:**
- Only BTC/USDT trades appear in the list.
- Stats header values (total closed, win rate, cumulative PnL, best, worst) reflect only BTC/USDT closed trades.
- Switching to "ETH/USDT" produces a different set of stats.

**Status:** [ ] Pass / Fail

---

### TC-A5: Empty State — User With Zero Trades Sees Placeholder, Not an Error

**Precondition:**
Create a fresh test user B who has never opened a trade. Log in as user B.

**Steps:**
1. Navigate to `/history` as test user B.
2. Observe the page content.

**Expected:**
- No trade rows are displayed.
- An empty-state message is shown (e.g., "No trades yet. Open your first position.").
- Stats header shows `--` for all values, not `0` or `NaN`.
- No HTTP 500 or unhandled error is thrown by the Edge Function.

**Status:** [ ] Pass / Fail

---

### TC-A6: Tournament Badge — Trades Linked to a Tournament Show the Tournament Name

**Precondition:**
Test user A has at least one trade where `tournament_id IS NOT NULL` in the `trades` table.

**Steps:**
1. Open the `/history` page.
2. Locate the trade with a `tournament_id`.

**Expected:**
- The trade row displays a tournament name badge (e.g., the tournament's `name` column value from the `tournaments` table).
- Trades without a `tournament_id` do not show a tournament badge.

**Status:** [ ] Pass / Fail

---

### TC-A7: Unauthenticated Request Returns 401

**Steps:**
1. Call the Edge Function directly without an auth header:
   ```
   curl -X GET "<SUPABASE_URL>/functions/v1/get-trade-history" \
     -H "Content-Type: application/json"
   ```

**Expected:**
- HTTP 401 response.
- Body: `{ "error": "Unauthorized" }`.

**Status:** [ ] Pass / Fail

---

### TC-A8: Invalid Query Param Returns 400

**Steps:**
1. Call the Edge Function with an invalid status value:
   ```
   curl -X GET "<SUPABASE_URL>/functions/v1/get-trade-history?status=INVALID" \
     -H "Authorization: Bearer <jwt>"
   ```

**Expected:**
- HTTP 400 response.
- Error message references the `status` parameter and lists valid values.

**Status:** [ ] Pass / Fail

---

## Section B — Daily Rewards

---

### TC-B1: First-Time Claim — New User Receives Day 1 Bonus

**Precondition:**
Test user C has never claimed a daily reward (`last_claim_date IS NULL` in `users` table, no rows in `daily_claims` for this user).

**Steps:**
1. Open the TG Web App as test user C.
2. Observe whether the daily reward popup appears on app open (or trigger it manually via the claim UI).
3. Note the balance before and after.
4. Check the `daily_claims` table in the Supabase Dashboard.
5. Check the `users` table for `current_streak` and `last_claim_date`.

**Expected:**
- A "Day 1 streak! +100 USDT credited" popup or notification appears.
- `users.balance` increases by exactly 100.
- `users.current_streak = 1`.
- `users.last_claim_date = today (UTC date)`.
- One row inserted in `daily_claims` with `streak_day = 1`, `bonus_amount = 100`, `claim_date = today UTC`.
- Edge Function response: `{ "success": true, "data": { "already_claimed": false, "streak": 1, "bonus_amount": 100, "new_balance": <expected_value> } }`.

**Status:** [ ] Pass / Fail

---

### TC-B2: Idempotency — Claiming Twice on the Same Day Is a Silent No-Op

**Precondition:**
Test user C has already claimed today (TC-B1 completed, `last_claim_date = today`).

**Steps:**
1. Call `claim-daily-reward` again for the same user within the same UTC calendar day:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/claim-daily-reward" \
     -H "Authorization: Bearer <jwt>" \
     -H "Content-Type: application/json" \
     -d '{}'
   ```
2. Check the `daily_claims` table row count for (user_id, today).
3. Check `users.balance`.

**Expected:**
- HTTP 200 response with `{ "data": { "already_claimed": true, ... } }`.
- Balance is unchanged (no second bonus credited).
- `daily_claims` still has exactly ONE row for (user_id, today) — no duplicate inserted.
- `users.current_streak` is unchanged.

**Status:** [ ] Pass / Fail

---

### TC-B3: Streak Continuation — Claiming on Consecutive Days Increments Streak

**Precondition:**
Manually set `users.last_claim_date = yesterday (UTC)` and `users.current_streak = 3` for test user C via the Supabase Dashboard table editor. Delete any `daily_claims` row for today if present.

**Steps:**
1. Invoke `claim-daily-reward` for test user C.
2. Check the DB state after the call.

**Expected:**
- Response: `{ "data": { "already_claimed": false, "streak": 4, "bonus_amount": 250, ... } }` (Day 4 = 250 USDT per schedule).
- `users.current_streak = 4`.
- `users.last_claim_date = today (UTC)`.
- New `daily_claims` row with `streak_day = 4`, `bonus_amount = 250`.

**Status:** [ ] Pass / Fail

---

### TC-B4: Streak Reset — Missing a Day Resets Streak to 1

**Precondition:**
Manually set `users.last_claim_date = 2 days ago (UTC)` and `users.current_streak = 5` for test user C. Delete any `daily_claims` row for today.

**Steps:**
1. Invoke `claim-daily-reward` for test user C.
2. Verify DB state.

**Expected:**
- Response: `{ "data": { "already_claimed": false, "streak": 1, "bonus_amount": 100, ... } }`.
- `users.current_streak = 1` (reset from 5).
- `users.last_claim_date = today (UTC)`.
- New `daily_claims` row with `streak_day = 1`, `bonus_amount = 100`.

**Status:** [ ] Pass / Fail

---

### TC-B5: Day 7+ Bonus Cap — Streak Above 7 Always Awards 750 USDT

**Precondition:**
Manually set `users.last_claim_date = yesterday` and `users.current_streak = 9` for test user C. Delete today's `daily_claims` row.

**Steps:**
1. Invoke `claim-daily-reward`.
2. Check response and DB.

**Expected:**
- `streak = 10` in the response (counter still increments correctly).
- `bonus_amount = 750` (capped at the Day 7+ tier regardless of streak being 10).
- `daily_claims` row has `bonus_amount = 750`.

**Status:** [ ] Pass / Fail

---

### TC-B6: AI User Exclusion — OpenClaw Cannot Claim Daily Reward

**Steps:**
1. Call `claim-daily-reward` using the OpenClaw service identity (user `id = '00000000-0000-0000-0000-00000c1a0001'`, `is_human = false`):
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/claim-daily-reward" \
     -H "x-user-id: 00000000-0000-0000-0000-00000c1a0001" \
     -H "Content-Type: application/json" \
     -d '{}'
   ```

**Expected:**
- HTTP 403 response.
- Body: `{ "error": "Daily rewards are available to human users only." }`.
- No row inserted in `daily_claims`.
- `users.balance` for OpenClaw is unchanged.

**Status:** [ ] Pass / Fail

---

### TC-B7: Concurrent Claim Race Condition — Simultaneous Requests Award Exactly One Bonus

**Precondition:**
Test user D has not claimed today. This test simulates a double-tap or TG init sending two simultaneous requests.

**Steps:**
1. Fire two `claim-daily-reward` POST requests for test user D as close to simultaneously as possible (use two terminal windows or a parallel curl command):
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/claim-daily-reward" \
     -H "Authorization: Bearer <jwt_user_D>" -d '{}' &
   curl -X POST "<SUPABASE_URL>/functions/v1/claim-daily-reward" \
     -H "Authorization: Bearer <jwt_user_D>" -d '{}' &
   wait
   ```
2. After both complete, check `daily_claims` row count for (user_D_id, today).
3. Check `users.balance` and compare to expected value (one bonus only).

**Expected:**
- Exactly ONE row exists in `daily_claims` for (user_D_id, today) — the `UNIQUE (user_id, claim_date)` constraint on `daily_claims` prevents a duplicate.
- Balance reflects exactly one bonus, not two.
- One of the two responses has `already_claimed: true`; the other has `already_claimed: false` (or both may return false if the rate-limit intercepts one before DB insertion — either outcome is acceptable as long as the balance is only incremented once).
- No 500 error or uncaught unique-violation error is returned to the client.

**Status:** [ ] Pass / Fail

---

### TC-B8: Server-Side Date — Client Timezone Cannot Influence Claim Date

**Precondition:**
This test confirms that the claim date is always the server-side UTC date, not anything derived from the client.

**Steps:**
1. In the Supabase Dashboard, inspect the most recent `daily_claims` row inserted during TC-B1 (or any recent claim).
2. Compare `claim_date` to the UTC wall-clock time at the moment of the test.

**Expected:**
- `claim_date` is the UTC calendar date at the time of the API call, regardless of the test machine's local timezone.
- The `award_daily_reward_txn` RPC uses `NOW() AT TIME ZONE 'UTC' :: DATE` — no client-supplied date field is accepted.

**Status:** [ ] Pass / Fail

---

### TC-B9: Streak Widget Displays Correct State Before and After Claiming

**Precondition:**
Test user C has `current_streak = 3` and has NOT claimed today.

**Steps:**
1. Open the TG Web App as test user C.
2. Observe the `StreakWidget` in the header or profile section before claiming.
3. Claim the daily reward.
4. Observe the widget state after claiming.

**Expected:**

Before claim:
- Widget shows "Streak: 3 days" (yesterday's count, not yet incremented).
- A "Claim Now" call-to-action is visible.
- "Tomorrow: +250 USDT" is shown (Day 4 bonus).

After claim:
- Widget updates to "Streak: 4 days".
- No "Claim Now" button is shown (already claimed today).
- "Tomorrow: +350 USDT" is shown (Day 5 bonus).

**Status:** [ ] Pass / Fail

---

### TC-B10: Zero Balance User Can Still Claim (Recovery Mechanic)

**Precondition:**
Set `users.balance = 0` for test user C via the Dashboard. Ensure `last_claim_date` is yesterday.

**Steps:**
1. Invoke `claim-daily-reward`.

**Expected:**
- HTTP 200. Bonus is credited.
- `users.balance = 100` (Day 1 bonus, or appropriate streak-day amount).
- No error about insufficient balance — the daily reward is not gated on current balance.

**Status:** [ ] Pass / Fail

---

## Section C — Notifications

---

### TC-C1: Liquidation Notification Delivered to Telegram DM

**Precondition:**
Test user A has a `tg_chat_id` set in the `users` table (the Telegram DM channel ID). A position exists with `liquidation_price` set to breach at current market price.

**Steps:**
1. Invoke `scan-liquidations` to trigger a real liquidation for test user A.
2. Wait up to 30 seconds.
3. Check the Telegram DM for the bot.

**Expected:**
- A Telegram message arrives in the bot DM: "Your [LONG/SHORT] [symbol] [leverage]x position was liquidated. Loss: -[margin] USDT. Balance: [new_balance] USDT".
- The liquidation itself is not rolled back (trade status = `liquidated`, balance correctly reduced).
- One row inserted in `notification_log` for test user A with `notification_type = 'liquidation'` (or equivalent type used by `scan-liquidations`).

**Status:** [ ] Pass / Fail

---

### TC-C2: No Telegram chat_id — Liquidation Proceeds, No Error

**Precondition:**
Test user B has `tg_chat_id = NULL` in the `users` table. Set up a breach condition for user B.

**Steps:**
1. Invoke `scan-liquidations`.
2. Check the trade status for user B.
3. Check for errors in the Edge Function logs.

**Expected:**
- Trade is liquidated normally (status = `liquidated`).
- No HTTP 500 error in the response.
- Edge Function logs show a "no chat_id, skipping notification" message for user B.
- No row inserted in `notification_log` for user B.

**Status:** [ ] Pass / Fail

---

### TC-C3: Notification Rate Limiting — Third Notification Within One Hour Is Blocked

**Precondition:**
Manually insert two `notification_log` rows for test user A with `sent_at` timestamps within the last 60 minutes (e.g., 50 minutes ago and 10 minutes ago).

**Steps:**
1. Attempt to trigger a third notification for test user A (e.g., trigger another liquidation or invoke `send-notifications` which sends a streak reminder).
2. Check `notification_log` row count for user A in the last hour.
3. Check Telegram DM — confirm no third message arrived.

**Expected:**
- The third notification is blocked by the `canSendNotification` rate-limit guard.
- Edge Function logs show "rate-limited: hourly cap (2) reached" for user A.
- `notification_log` still has exactly 2 rows within the last hour (no third row added).
- The blocking of the notification does not cause an error response from the parent function.

**Status:** [ ] Pass / Fail

---

### TC-C4: Daily Notification Cap — 6th Notification in 24 Hours Is Blocked

**Precondition:**
Manually insert 5 `notification_log` rows for test user A with `sent_at` spread across the last 23 hours (ensuring each pair is at least 15 minutes apart to pass the gap check individually, and only the count across the day matters here). The most recent should be more than 15 minutes ago.

**Steps:**
1. Attempt to trigger a 6th notification for user A.
2. Check the log and Telegram DM.

**Expected:**
- Notification is blocked.
- Logs show "rate-limited: daily cap (5) reached".
- No 6th row inserted in `notification_log`.

**Status:** [ ] Pass / Fail

---

### TC-C5: 15-Minute Gap Enforcement — Notification Blocked If Last Was Under 15 Minutes Ago

**Precondition:**
Manually insert one `notification_log` row for test user A with `sent_at = 10 minutes ago`. The user is otherwise within hourly and daily caps.

**Steps:**
1. Attempt to send a notification for user A.
2. Check logs and Telegram DM.

**Expected:**
- Notification blocked.
- Logs show "rate-limited: gap since last message < 15 min".
- No new row in `notification_log`.

**Status:** [ ] Pass / Fail

---

### TC-C6: Tournament Reminder — Sent Once Per Participant Within the 55–65 Minute Window

**Precondition:**
Create a test tournament with `start_at = NOW() + 60 minutes` and `status = 'upcoming'`. Register test user A as a participant (`tournament_participants` row with `reminder_sent_at = NULL`). Confirm test user A has a valid `tg_chat_id`.

**Steps:**
1. Invoke `send-notifications` manually:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/send-notifications" \
     -H "Authorization: Bearer <service_role_key>"
   ```
2. Check the Telegram DM for test user A.
3. Check `tournament_participants.reminder_sent_at` for this participant row.
4. Invoke `send-notifications` a second time immediately.

**Expected:**

After first invocation:
- Telegram message received: "Tournament '[name]' starts in ~1 hour." with start time.
- `tournament_participants.reminder_sent_at` is now set to a non-null timestamp.
- `notification_log` has one row of `notification_type = 'tournament_reminder'`.

After second invocation:
- No second Telegram message (the `reminder_sent_at IS NULL` guard prevents re-sending).
- Response `tournament_reminders` count = 0 on the second run.

**Status:** [ ] Pass / Fail

---

### TC-C7: Tournament Reminder Delivery Guard — reminder_sent_at Prevents Duplicate Messages

**Precondition:**
Continuing from TC-C6. `tournament_participants.reminder_sent_at` is already set.

**Steps:**
1. Advance the test tournament's `start_at` back into the 55–65 minute window again by updating it in the Dashboard (to simulate the cron firing again).
2. Invoke `send-notifications` again.

**Expected:**
- `reminder_sent_at IS NULL` filter excludes the already-reminded participant.
- No second Telegram message delivered.
- Edge Function logs confirm the participant was skipped.

**Status:** [ ] Pass / Fail

---

### TC-C8: OpenClaw AI Excluded From Notifications

**Precondition:**
Trigger a liquidation for the OpenClaw AI user (set `liquidation_price` to breach).

**Steps:**
1. Invoke `scan-liquidations`.
2. Check Telegram for any message sent on behalf of OpenClaw.
3. Check `notification_log`.

**Expected:**
- OpenClaw's trade is liquidated normally.
- No Telegram message is sent (OpenClaw has no `tg_chat_id`).
- No row in `notification_log` for `user_id = '00000000-0000-0000-0000-00000c1a0001'`.

**Status:** [ ] Pass / Fail

---

### TC-C9: Telegram Bot API Failure Does Not Roll Back the Underlying Operation

**Precondition:**
Temporarily set `TELEGRAM_BOT_TOKEN` to an invalid value in Supabase Secrets (or use a test account that has blocked the bot). Trigger a liquidation for a user with a valid `tg_chat_id`.

**Steps:**
1. Invoke `scan-liquidations`.
2. Observe the response.
3. Check the trade status.
4. Restore the valid `TELEGRAM_BOT_TOKEN` afterwards.

**Expected:**
- `scan-liquidations` returns HTTP 200 with the liquidation counted.
- Trade `status = 'liquidated'`, `realised_pnl` set correctly.
- Telegram message delivery fails silently (HTTP 401 or 403 from Bot API logged, not rethrown).
- No `notification_log` row is inserted (send failed before logging).
- No HTTP 500 returned to the caller of `scan-liquidations`.

**Status:** [ ] Pass / Fail

---

### TC-C10: Streak Reminder Sent Only in UTC 16:00–18:00 Window

**Precondition:**
Test user A has `notifications_enabled = true`, a valid `tg_chat_id`, `last_claim_date = yesterday`, and `streak_reminder_sent_today = false`.

**Steps:**
1. Note the current UTC hour.
2. If between 16:00 and 17:59 UTC: invoke `send-notifications` and expect a streak reminder.
3. If outside that window: invoke `send-notifications` and confirm no streak reminder is sent. Then manually verify the log message "Outside streak reminder window".

**Expected (inside window):**
- Telegram DM received: "Don't Break Your Streak! You haven't claimed your daily reward today yet."
- `users.streak_reminder_sent_today = true` after the call.
- One `notification_log` row with `notification_type = 'streak_reminder'`.

**Expected (outside window):**
- No Telegram DM.
- Edge Function logs: "Outside streak reminder window (16:00–18:00 UTC). Skipping."
- `streak_reminders` count in the response = 0.

**Status:** [ ] Pass / Fail

---

## Section D — Achievements

---

### TC-D1: get-achievements Returns All 6 Achievements Categorised Correctly for a New User

**Precondition:**
Use a freshly seeded test user E with no `user_achievements` or `user_achievement_progress` rows.

**Steps:**
1. Call `get-achievements` for test user E:
   ```
   curl -X GET "<SUPABASE_URL>/functions/v1/get-achievements" \
     -H "Authorization: Bearer <jwt_user_E>"
   ```
2. Inspect the response.

**Expected:**
- HTTP 200.
- `data.earned` array: empty (`[]`).
- `data.in_progress` array: empty (`[]`).
- `data.locked` array: contains exactly 6 items (ACH-001 through ACH-006).
- Each locked item has `id`, `name`, `description`, `icon_key`, `required_count`.

**Status:** [ ] Pass / Fail

---

### TC-D2: ACH-004 Golden Claw — Awarded on a >50% ROI Single Trade

**Precondition:**
Test user A does not yet have ACH-004. Prepare `event_data` with a trade that yields `realised_pnl = 600`, `margin = 1000` (ROI = 60%, exceeds the 50% threshold).

**Steps:**
1. Call `check-achievements` with the service role key:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/check-achievements" \
     -H "apikey: <SERVICE_ROLE_KEY>" \
     -H "Content-Type: application/json" \
     -d '{
       "user_id": "<user_A_id>",
       "trigger_event": "trade_closed",
       "event_data": {
         "realised_pnl": 600,
         "margin": 1000,
         "leverage": 10,
         "status": "closed",
         "user_roi": 0.05,
         "openclaw_roi": 0.03,
         "created_at": "2026-03-28T10:00:00Z",
         "updated_at": "2026-03-28T11:00:00Z"
       }
     }'
   ```
2. Check `user_achievements` in the Dashboard.
3. Call `get-achievements` for user A.

**Expected:**
- `check-achievements` response: `{ "data": { "newly_earned": [{ "code": "ACH-004", "name": "Golden Claw", ... }] } }`.
- One row in `user_achievements` for (user_A_id, ACH-004).
- `get-achievements` response shows ACH-004 in the `earned` array with a non-null `earned_at`.

**Status:** [ ] Pass / Fail

---

### TC-D3: ACH-004 Idempotency — Re-Triggering Golden Claw Does Not Create a Duplicate Row

**Precondition:**
TC-D2 completed. User A already has ACH-004.

**Steps:**
1. Call `check-achievements` again with the same `event_data` as TC-D2.
2. Check `user_achievements` row count for (user_A_id, ACH-004).

**Expected:**
- `newly_earned` array in the response is empty (`[]`) — the achievement was already earned.
- `user_achievements` still has exactly ONE row for (user_A_id, ACH-004).
- No HTTP error (ON CONFLICT DO NOTHING swallows the unique violation cleanly).

**Status:** [ ] Pass / Fail

---

### TC-D4: ACH-001 Claw Crusher — Progress Tracked and Achievement Awarded on 3rd Victory

**Precondition:**
Test user A has no existing Claw Crusher progress.

**Steps:**
1. Call `check-achievements` twice with `user_roi > openclaw_roi` (e.g., `user_roi: 0.10, openclaw_roi: 0.05`) for user A with `trigger_event = "trade_closed"`.
2. After each call, check `user_achievement_progress` for user A and ACH-001.
3. On the third call with the same conditions, observe the response and `user_achievements`.

**Expected:**

After 1st call:
- `newly_earned = []`.
- `user_achievement_progress` row: `current_count = 1`.

After 2nd call:
- `newly_earned = []`.
- `user_achievement_progress` row: `current_count = 2`.

After 3rd call:
- `newly_earned = [{ "code": "ACH-001", "name": "Claw Crusher", ... }]`.
- `user_achievement_progress` row: `current_count = 3`.
- New row in `user_achievements` for (user_A_id, ACH-001).

**Status:** [ ] Pass / Fail

---

### TC-D5: ACH-001 — No Progress Increment When User Does Not Beat OpenClaw

**Precondition:**
Test user A has 0 Claw Crusher progress.

**Steps:**
1. Call `check-achievements` with `user_roi: 0.03, openclaw_roi: 0.08` (user is below OpenClaw).

**Expected:**
- `newly_earned = []`.
- No `user_achievement_progress` row created for ACH-001 (or existing count unchanged).
- No `user_achievements` row created for ACH-001.

**Status:** [ ] Pass / Fail

---

### TC-D6: ACH-002 Daredevil — Awarded for a Closed 100x Trade, Not a Liquidated One

**Steps:**
1. Call `check-achievements` for user A with:
   ```json
   { "trigger_event": "trade_closed", "event_data": { "leverage": 100, "status": "closed" } }
   ```
2. Then call again with `"status": "liquidated"`.

**Expected:**

First call (status = "closed"):
- `newly_earned = [{ "code": "ACH-002", ... }]`.
- Row inserted in `user_achievements` for ACH-002.

Second call (status = "liquidated"):
- `newly_earned = []` (liquidated disqualifies Daredevil).
- No second `user_achievements` row (the first was already inserted and the constraint prevents duplicates anyway).

**Status:** [ ] Pass / Fail

---

### TC-D7: ACH-003 Arena Elite — Top 10 Threshold Scales With Tournament Size

**Steps:**
1. Call `check-achievements` for user A with:
   ```json
   { "trigger_event": "tournament_settled", "event_data": { "rank": 1, "total_participants": 5 } }
   ```
   — In a 5-person tournament, rank 1 qualifies (threshold = min(10, 5) = 5).
2. For a different user (user B), call with `"rank": 11, "total_participants": 100` — should not qualify.

**Expected:**

User A (rank 1, 5 participants):
- `newly_earned = [{ "code": "ACH-003", ... }]`.

User B (rank 11, 100 participants):
- `newly_earned = []`.

**Status:** [ ] Pass / Fail

---

### TC-D8: ACH-005 Streak Keeper — Awarded When Streak Reaches 7

**Precondition:**
Test user A has no ACH-005.

**Steps:**
1. Call `check-achievements` with `trigger_event = "streak_claimed"` and `event_data = { "streak": 6 }`.
2. Then call again with `event_data = { "streak": 7 }`.

**Expected:**

First call (streak = 6):
- `newly_earned = []`.

Second call (streak = 7):
- `newly_earned = [{ "code": "ACH-005", "name": "Streak Keeper", ... }]`.
- Row inserted in `user_achievements` for ACH-005.

**Status:** [ ] Pass / Fail

---

### TC-D9: ACH-006 Survivor — Awarded Only When Trade Held Open Over 24 Hours

**Steps:**
1. Call `check-achievements` for user A with:
   ```json
   {
     "trigger_event": "trade_closed",
     "event_data": {
       "status": "closed",
       "created_at": "2026-03-27T10:00:00Z",
       "updated_at": "2026-03-28T11:00:00Z"
     }
   }
   ```
   Duration = 25 hours — qualifies.
2. Repeat with `updated_at = "2026-03-27T20:00:00Z"` (10-hour hold — does not qualify).

**Expected:**

25-hour hold:
- `newly_earned = [{ "code": "ACH-006", ... }]`.

10-hour hold:
- `newly_earned = []`.

**Status:** [ ] Pass / Fail

---

### TC-D10: Multiple Achievements From a Single Event Are All Awarded in One Call

**Precondition:**
Test user A has no ACH-002 (Daredevil) or ACH-004 (Golden Claw).

**Steps:**
1. Call `check-achievements` with a single event that qualifies for both:
   ```json
   {
     "trigger_event": "trade_closed",
     "event_data": {
       "leverage": 100,
       "status": "closed",
       "realised_pnl": 700,
       "margin": 1000,
       "user_roi": 0.10,
       "openclaw_roi": 0.04,
       "created_at": "2026-03-27T10:00:00Z",
       "updated_at": "2026-03-28T12:00:00Z"
     }
   }
   ```

**Expected:**
- `newly_earned` contains both ACH-002 and ACH-004 (order may vary).
- Two rows inserted in `user_achievements` (one for each).
- `get-achievements` for user A shows both in the `earned` array.

**Status:** [ ] Pass / Fail

---

### TC-D11: check-achievements Requires Service Role Key — Regular JWT Returns 403

**Steps:**
1. Call `check-achievements` with a regular user JWT instead of the service role key:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/check-achievements" \
     -H "Authorization: Bearer <regular_user_jwt>" \
     -H "Content-Type: application/json" \
     -d '{ "user_id": "...", "trigger_event": "trade_closed", "event_data": {} }'
   ```

**Expected:**
- HTTP 403 response.
- Body: `{ "error": "Forbidden" }`.
- No achievement evaluation occurs.

**Status:** [ ] Pass / Fail

---

### TC-D12: Achievement Progress Visible on the /achievements Frontend Page

**Precondition:**
Test user A has: ACH-004 earned, ACH-001 with `current_count = 2` (in progress), all others locked.

**Steps:**
1. Open the `/achievements` page as test user A.
2. Inspect each section.

**Expected:**
- Earned section: ACH-004 "Golden Claw" shown in full color with unlock date.
- In-progress section: ACH-001 "Claw Crusher" shown with a progress bar at 66% (2/3) and "2/3" text label.
- Locked section: remaining 4 achievements shown grayed out with 0/N progress.
- No section shows stale or incorrect data.

**Status:** [ ] Pass / Fail

---

## Section E — Phase 1 + 2 Regression Tests

These tests confirm that Phase 3 changes did not break existing functionality. Run a representative subset — a full Phase 1/2 rerun is not required for Phase 3 acceptance.

---

### TC-E1: Trade Execution Still Works End-to-End

**Steps:**
1. Open the TG Web App as test user A.
2. Open a new BTC/USDT LONG position at 10x leverage with 100 USDT margin.

**Expected:**
- Position card appears immediately with correct entry price, liquidation price, and margin.
- `users.balance` decreases by 100.
- One new row in `trades` with `status = 'open'`.

**Status:** [ ] Pass / Fail

---

### TC-E2: Close Trade Still Works and Does Not Interfere With Achievement Check

**Steps:**
1. Close the open position created in TC-E1.
2. Check that `close-trade` returns success.
3. Confirm `check-achievements` is called (check Edge Function logs for `[check-achievements]` entries).

**Expected:**
- Trade `status = 'closed'`, `realised_pnl` set.
- `users.balance` updated correctly.
- `check-achievements` was invoked as a fire-and-forget side effect.
- If a relevant achievement is earned (e.g., Golden Claw), it appears in `user_achievements`.
- No 500 error on `close-trade` itself even if `check-achievements` encounters an issue.

**Status:** [ ] Pass / Fail

---

### TC-E3: Liquidation Scanner Still Runs Without Errors

**Steps:**
1. Invoke `scan-liquidations` with no breached positions in the DB.

**Expected:**
- HTTP 200.
- `total_trades_liquidated = 0`.
- No errors in the response body.

**Status:** [ ] Pass / Fail

---

### TC-E4: OpenClaw AI Agent Still Trades Autonomously

**Steps:**
1. Invoke `openclaw-trade` manually.
2. Check OpenClaw's position or balance in the `users` table.

**Expected:**
- OpenClaw opens or closes a position as determined by its strategy logic.
- No 500 error.
- `daily_claims` is not modified (OpenClaw never touches the daily reward system).

**Status:** [ ] Pass / Fail

---

### TC-E5: Tournament Join and Settlement Still Work

**Steps:**
1. As test user A, join an existing upcoming tournament.
2. Manually advance the tournament to `status = 'active'` if needed.
3. Invoke `settle-tournament` after the tournament `end_at` has passed.

**Expected:**
- Participant balances updated correctly.
- Tournament `status = 'settled'`.
- `check-achievements` is called for each participant (ACH-003 Arena Elite may be awarded).
- No 500 error on `settle-tournament`.

**Status:** [ ] Pass / Fail

---

## Section F — Cross-Feature Integration

---

### TC-F1: Daily Claim → Achievement → Notification Pipeline

**Precondition:**
Test user A has `current_streak = 6`, `last_claim_date = yesterday`, `tg_chat_id` set, and has not yet earned ACH-005 (Streak Keeper).

**Steps:**
1. Call `claim-daily-reward` for test user A.
2. Verify the streak increments to 7.
3. Verify `check-achievements` is called with `trigger_event = "streak_claimed"` and `event_data.streak = 7`.
4. Verify ACH-005 is awarded.
5. Verify a congratulations notification is sent to Telegram (if implemented in Phase 3).

**Expected:**
- Claim returns `streak = 7`, `bonus_amount = 750`.
- `user_achievements` row for ACH-005 appears.
- `notification_log` may contain an achievement notification (if the notification for newly earned achievements is wired up).

**Status:** [ ] Pass / Fail

---

### TC-F2: Trade History Stats Are Unaffected by Daily Claims or Achievement Data

**Steps:**
1. Claim a daily reward for test user A.
2. Earn an achievement for test user A.
3. Fetch `get-trade-history` for test user A.

**Expected:**
- Stats in the trade history response (`total_closed`, `win_rate`, `cumulative_pnl`, `best_trade`, `worst_trade`) are unchanged from before the claim and achievement operations.
- No `daily_claims` or `user_achievements` data bleeds into the trade stats.

**Status:** [ ] Pass / Fail

---

## Test Execution Summary

| Section | Total TCs | Pass | Fail | Blocked |
|---------|-----------|------|------|---------|
| A — Trade History | 8 | | | |
| B — Daily Rewards | 10 | | | |
| C — Notifications | 10 | | | |
| D — Achievements | 12 | | | |
| E — Regression | 5 | | | |
| F — Integration | 2 | | | |
| **Total** | **47** | | | |

---

## Known Edge Cases and Gotchas

| # | Area | Gotcha | How to Detect |
|---|------|--------|---------------|
| 1 | Daily Rewards | UTC midnight boundary: a claim at 23:59 UTC and one at 00:01 UTC the next day are two valid claims. If the test environment is in a non-UTC timezone, ensure the `claim_date` in `daily_claims` matches UTC, not local time. | Compare `claim_date` in DB against `NOW() AT TIME ZONE 'UTC' :: DATE` in a Dashboard SQL query. |
| 2 | Notifications | `canSendNotification` fails open if `notification_log` is unreachable — a DB outage could cause a burst of notifications. | Check logs for `[telegram-notify] canSendNotification DB error` during any DB maintenance windows. |
| 3 | Achievements | `check-achievements` is called fire-and-forget from `close-trade`. A crash in achievement evaluation cannot be observed from the trade close response — check Edge Function logs explicitly for `[check-achievements]` error lines. | Filter Supabase log explorer by function name `check-achievements`. |
| 4 | Trade History | The `next_cursor` is derived from `created_at` of the last row. If two trades share an identical `created_at` timestamp (possible via batch insert), pagination may skip or repeat those rows. This is a known limitation of timestamp-based cursors. | Inspect `daily_claims` insert patterns; avoid batch-inserting trades with identical timestamps in production. |
| 5 | Concurrent Claims | The in-memory rate limiter in `claim-daily-reward` is per-isolate and may not catch all concurrent requests under high parallelism. The DB-level `UNIQUE (user_id, claim_date)` constraint on `daily_claims` is the last-line idempotency guard — confirm it is present via `\d daily_claims` or the Dashboard schema view. | Run `SELECT indexname FROM pg_indexes WHERE tablename = 'daily_claims'` to confirm the unique index exists. |
