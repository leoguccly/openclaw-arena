# OpenClaw Arena — Phase 4 Smoke Test Checklist

> **For**: Product Owner Manual Acceptance
> **Environment**: Telegram iOS/Android App + Supabase Dashboard + Edge Function curl invocations
> **Date**: 2026-03-29
> **Phase**: 4 (Referral System, Multiple AI Personalities, Price Alerts)

---

## Prerequisites

Before running any test case, verify the following are in place:

- [ ] All Phase 4 migrations applied in order:
  - `015_referral_system.sql` — `referral_code`, `referred_by`, `referral_bonus_earned` columns on `users`; `referral_events` table; `award_referral_bonus_txn` RPC; RLS policies
  - `016_ai_personalities.sql` — `avatar_slug` column on `users`; auth stubs and `public.users` rows for Conservative (`...0c1a0002`) and Chaos (`...0c1a0003`); backfill `openclaw_original` slug on `...0c1a0001`
  - `017_price_alerts.sql` — `price_alerts` table; partial index `idx_price_alerts_active_symbol`; RLS policies
- [ ] All Phase 4 Edge Functions deployed:
  - `get-referral` (GET)
  - `register-referral` (POST)
  - `openclaw-conservative` (POST, cron every 30 min)
  - `openclaw-chaos` (POST, cron every 15 min)
  - `manage-price-alerts` (GET / POST / DELETE)
  - `scan-liquidations` updated with `checkPriceAlerts` integration
- [ ] Phase 1–3 Edge Functions still deployed and healthy: `market-oracle`, `execute-trade`, `close-trade`, `scan-liquidations`, `openclaw-trade`, `generate-api-key`, `join-tournament`, `settle-tournament`, `get-trade-history`, `claim-daily-reward`, `send-notifications`, `check-achievements`, `get-achievements`, `process-outbox`
- [ ] Three AI agent rows confirmed:
  ```sql
  SELECT id, display_name, is_human, balance, avatar_slug
  FROM public.users
  WHERE id IN (
    '00000000-0000-0000-0000-00000c1a0001',
    '00000000-0000-0000-0000-00000c1a0002',
    '00000000-0000-0000-0000-00000c1a0003'
  );
  ```
  Expected: 3 rows, all `is_human = false`, balances = 10000, slugs = `openclaw_original`, `openclaw_conservative`, `openclaw_chaos`
- [ ] `price_alerts` table exists and is empty: `SELECT COUNT(*) FROM public.price_alerts` returns 0
- [ ] `referral_events` table exists and is empty: `SELECT COUNT(*) FROM public.referral_events` returns 0
- [ ] No existing `referral_code` values on test users: `SELECT referral_code FROM public.users WHERE is_human = true LIMIT 5` returns all NULL
- [ ] `TELEGRAM_BOT_TOKEN` Supabase Secret is set and functional (validated in Phase 3)
- [ ] Frontend deployed with: `/referral` page, `/alerts` page, leaderboard updated to render `avatar_slug` and AI personality names
- [ ] Test user A — a human account used throughout; has at least one completed trade (closed or liquidated) from Phase 1–3 testing
- [ ] Test user B — a second fresh human account with no trades; used for referral registration tests
- [ ] Supabase URL and service role key available for direct curl invocations

---

## Section R — Referral System

---

### TC-R1: First-Time Code Generation — GET Returns a Stable Code for a User With No Prior Code

**Precondition:**
Test user A has `referral_code = NULL` in the `users` table (confirmed in prerequisites).

**Steps:**
1. Call the Edge Function as test user A:
   ```
   curl -X GET "<SUPABASE_URL>/functions/v1/get-referral" \
     -H "Authorization: Bearer <USER_A_JWT>"
   ```
2. Inspect the response body.
3. Query the database:
   ```sql
   SELECT referral_code FROM public.users WHERE id = '<USER_A_ID>';
   ```
4. Call the same endpoint again (second request).

**Expected:**
- HTTP 200 on both calls.
- Response body contains `referral_code` (8 characters, uppercase alphanumeric from the `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` alphabet — no ambiguous characters I, O, 0, 1).
- Response body contains `referral_link` in the format `https://openclaw.arena/join?ref=<CODE>` (or the value of `REFERRAL_BASE_URL` env var).
- `referees` array is empty (`[]`), `total_bonus_earned` is `0`.
- Database shows the same code now stored in `users.referral_code`.
- Second call returns the identical code (idempotent — code was not regenerated).

**Status:** [ ] Pass / Fail

---

### TC-R2: Code Stability — Repeated Calls Never Regenerate the Code

**Precondition:**
TC-R1 completed. User A now has a `referral_code` in the database.

**Steps:**
1. Record the code returned in TC-R1.
2. Call `get-referral` five more times as user A.
3. Compare all returned codes.

**Expected:**
- All six calls (including TC-R1) return the exact same `referral_code` string.
- No new code is written to the database (check `updated_at` if available, or verify via SQL).

**Status:** [ ] Pass / Fail

---

### TC-R3: Successful Referral Registration — New User Registers With a Valid Code

**Precondition:**
User A has a `referral_code` (from TC-R1). User B has `referred_by = NULL`.

**Steps:**
1. Call `register-referral` as user B, passing user A's code:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/register-referral" \
     -H "Authorization: Bearer <USER_B_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"referral_code": "<USER_A_CODE>"}'
   ```
2. Query the database:
   ```sql
   SELECT referred_by FROM public.users WHERE id = '<USER_B_ID>';
   ```

**Expected:**
- HTTP 200, body `{"success": true}`.
- `users.referred_by` for user B is now set to user A's UUID.
- `users.referral_code_used` for user B is set to the code string.

**Status:** [ ] Pass / Fail

---

### TC-R4: Self-Referral Blocking — User Cannot Register Their Own Code

**Precondition:**
User A has a `referral_code` (from TC-R1).

**Steps:**
1. Call `register-referral` as user A, passing user A's own code:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/register-referral" \
     -H "Authorization: Bearer <USER_A_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"referral_code": "<USER_A_CODE>"}'
   ```
2. Query the database: `SELECT referred_by FROM public.users WHERE id = '<USER_A_ID>'`

**Expected:**
- HTTP 200, body `{"success": true}` (silent skip — no error exposed).
- `users.referred_by` for user A remains NULL.
- No row inserted in `referral_events`.
- Supabase Edge Function logs show: `Self-referral attempt by user <ID> — silent skip`.

**Status:** [ ] Pass / Fail

---

### TC-R5: Invalid Code — Nonexistent Code Is Silently Ignored

**Steps:**
1. Call `register-referral` as user B with a made-up code that does not exist:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/register-referral" \
     -H "Authorization: Bearer <USER_B_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"referral_code": "FAKECODE"}'
   ```

**Expected:**
- HTTP 200, body `{"success": true}`.
- `users.referred_by` for user B is unchanged (remains NULL or the value set in TC-R3).
- No row inserted in `referral_events`.
- Response body does not reveal whether the code exists or not.

**Status:** [ ] Pass / Fail

---

### TC-R6: Already-Referred User — Registering a Second Code Has No Effect

**Precondition:**
TC-R3 completed. User B already has `referred_by = <USER_A_ID>`.

**Steps:**
1. Create or use a third test user C. Get user C's referral code (call `get-referral` as user C).
2. Call `register-referral` as user B, passing user C's code:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/register-referral" \
     -H "Authorization: Bearer <USER_B_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"referral_code": "<USER_C_CODE>"}'
   ```
3. Query: `SELECT referred_by FROM public.users WHERE id = '<USER_B_ID>'`

**Expected:**
- HTTP 200, `{"success": true}` (silent skip).
- `users.referred_by` for user B is still user A's UUID — not overwritten.

**Status:** [ ] Pass / Fail

---

### TC-R7: Bonus Atomicity — First Completed Trade Pays Both Parties Exactly Once

**Precondition:**
TC-R3 completed. User B has `referred_by = <USER_A_ID>`. User B has no completed trades yet.
Record user A's balance before the test: `SELECT balance FROM public.users WHERE id = '<USER_A_ID>'`
Record user B's balance before the test: `SELECT balance FROM public.users WHERE id = '<USER_B_ID>'`

**Steps:**
1. As user B, open a trade via `execute-trade`, then immediately close it via `close-trade` (or wait for it to be liquidated by `scan-liquidations`).
2. After the close/liquidation is confirmed (trade `status` = `closed` or `liquidated`), query:
   ```sql
   SELECT * FROM public.referral_events WHERE referee_id = '<USER_B_ID>';
   SELECT balance FROM public.users WHERE id = '<USER_A_ID>';
   SELECT balance FROM public.users WHERE id = '<USER_B_ID>';
   ```
3. Have user B close a second trade.
4. Re-query `referral_events`.

**Expected:**
- After the first trade closes: exactly one row in `referral_events` with `referrer_id = <USER_A_ID>` and `referee_id = <USER_B_ID>`.
- User A's balance increased by exactly 500 USDT compared to the pre-test value.
- User B's balance includes an additional 500 USDT bonus on top of the trade PnL.
- `referral_bonus_earned` on user A's row increased by 500.
- After the second trade closes: still exactly one row in `referral_events` — no duplicate payout. Balances unchanged by a second bonus.

**Status:** [ ] Pass / Fail

---

### TC-R8: Idempotency Guard — RPC Called Twice for Same Referee Returns already_paid

**Precondition:**
TC-R7 completed. `referral_events` contains one row for user B.

**Steps:**
1. Call `award_referral_bonus_txn` directly via the Supabase SQL editor:
   ```sql
   SELECT public.award_referral_bonus_txn(
     '<USER_A_ID>'::UUID,
     '<USER_B_ID>'::UUID,
     500,
     500
   );
   ```
2. Check user balances after this direct call.

**Expected:**
- The function returns `{"already_paid": true, "referrer_bonus": 0, "referee_bonus": 0, ...}`.
- Balances are unchanged (no additional 500 credited to either party).
- Still exactly one row in `referral_events`.

**Status:** [ ] Pass / Fail

---

### TC-R9: Referral Page — Referrer Sees Their Referee in the Confirmed List

**Precondition:**
TC-R7 completed. User A referred user B and the bonus was paid.

**Steps:**
1. Open the TG Web App as user A.
2. Navigate to the `/referral` page.
3. Observe the list of referees.

**Expected:**
- User A's referral code and share link are visible on the page.
- User B appears in a "Confirmed Referrals" section (or equivalent) with `bonus_paid_at` timestamp shown.
- `total_bonus_earned` shows 500 (or the accumulated total if user A has multiple confirmed referrals).
- The share button, when tapped, opens the TG native share sheet or copies the link to clipboard (fallback on desktop).

**Status:** [ ] Pass / Fail

---

### TC-R10: Concurrent Referral Bonus Race — Two Simultaneous First-Trade Closes Do Not Double-Pay

**Precondition:**
A fresh pair: user D referred user E. User E has no completed trades.

**Steps:**
1. Trigger two simultaneous calls to `award_referral_bonus_txn` (e.g., two concurrent SQL executions in the Supabase Dashboard with identical arguments, or two rapid `close-trade` invocations if the test environment permits).
   ```sql
   -- Run both concurrently in separate query tabs:
   SELECT public.award_referral_bonus_txn('<USER_D_ID>'::UUID, '<USER_E_ID>'::UUID, 500, 500);
   ```
2. After both queries complete, count rows in `referral_events`:
   ```sql
   SELECT COUNT(*) FROM public.referral_events WHERE referee_id = '<USER_E_ID>';
   ```
3. Check user D's balance increment.

**Expected:**
- Exactly one row in `referral_events` for user E — the `UNIQUE (referee_id)` constraint and `ON CONFLICT DO NOTHING` ensure only one write wins.
- User D's balance increased by exactly 500, not 1000.
- No PostgreSQL error surfaces to the caller (the losing call returns `{"already_paid": true}`).

**Status:** [ ] Pass / Fail

---

### TC-R11: Bot Account Rejection — AI Agent Cannot Be Referrer or Referee

**Steps:**
1. Call `award_referral_bonus_txn` with the Conservative agent as referrer:
   ```sql
   SELECT public.award_referral_bonus_txn(
     '00000000-0000-0000-0000-00000c1a0002'::UUID,
     '<USER_A_ID>'::UUID
   );
   ```
2. Call with a bot as referee:
   ```sql
   SELECT public.award_referral_bonus_txn(
     '<USER_A_ID>'::UUID,
     '00000000-0000-0000-0000-00000c1a0002'::UUID
   );
   ```

**Expected:**
- Both calls raise a PostgreSQL exception: `"Referrer ... is not a human account"` or `"Referee ... is not a human account"` respectively.
- No rows written to `referral_events`.
- No balance changes.

**Status:** [ ] Pass / Fail

---

### TC-R12: Unauthenticated Requests Return 401

**Steps:**
1. Call `get-referral` without an Authorization header:
   ```
   curl -X GET "<SUPABASE_URL>/functions/v1/get-referral"
   ```
2. Call `register-referral` without an Authorization header:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/register-referral" \
     -H "Content-Type: application/json" \
     -d '{"referral_code": "ANYTHING"}'
   ```

**Expected:**
- Both return HTTP 401 with `{"error": "Unauthorized"}`.

**Status:** [ ] Pass / Fail

---

## Section AI — Multiple AI Personalities

---

### TC-AI1: Leaderboard Shows All Three AI Agents

**Steps:**
1. Open the TG Web App as any authenticated user.
2. Navigate to the leaderboard (main screen or dedicated leaderboard tab).
3. Observe the AI-tagged entries.

**Expected:**
- Three AI rows visible: "OpenClaw" (original), "OpenClaw Conservative", "OpenClaw Chaos".
- Each row shows a distinct icon (resolved from `avatar_slug`: `openclaw_original`, `openclaw_conservative`, `openclaw_chaos`).
- Each row shows a lobster/bot marker distinguishing it from human rows.
- ROI values for Conservative and Chaos may be 0 if no trades have occurred yet; the rows still appear.

**Status:** [ ] Pass / Fail

---

### TC-AI2: Conservative Agent — Cron Invocation Produces a Valid Action

**Steps:**
1. Trigger the Conservative agent manually:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/openclaw-conservative" \
     -H "Authorization: Bearer <SERVICE_ROLE_KEY>"
   ```
2. Check the response body.
3. Query the database:
   ```sql
   SELECT id, symbol, direction, leverage, margin, status
   FROM public.trades
   WHERE user_id = '00000000-0000-0000-0000-00000c1a0002'
   ORDER BY created_at DESC
   LIMIT 1;
   ```

**Expected:**
- HTTP 200, `{"success": true, "data": {"action": "<one of: open, hold, stop_loss, signal_flip, signal_flip_close_only, skip>", "detail": "..."}}`.
- If `action = "open"`: a new trade row exists for the Conservative agent with `symbol = "ETH/USDT"` and `leverage = 5`.
- If `action = "hold"` or `"skip"`: no new trade row; existing position (if any) is unchanged.
- No HTTP 500. Logs in the Supabase Dashboard show the SMA computation output (SMA value, deviation percentage, bands).

**Status:** [ ] Pass / Fail

---

### TC-AI3: Conservative Agent — Symbol Is ETH/USDT and Leverage Is Exactly 5x

**Precondition:**
TC-AI2 produced `action = "open"`.

**Steps:**
1. Query the most recent open trade for the Conservative agent:
   ```sql
   SELECT symbol, leverage, direction, margin, entry_price
   FROM public.trades
   WHERE user_id = '00000000-0000-0000-0000-00000c1a0002'
     AND status = 'open'
   ORDER BY created_at DESC
   LIMIT 1;
   ```

**Expected:**
- `symbol = 'ETH/USDT'`.
- `leverage = 5` (the `LEVERAGE` constant; never exceeds `MAX_LEVERAGE = 5`).
- `margin` is between 0.5% and 1.5% of the agent's balance at trade time (jittered around `MARGIN_FRACTION = 0.01`), and never exceeds 5% of balance (`MAX_MARGIN_FRACTION = 0.05`).
- `direction` is either `long` or `short` — consistent with the mean reversion signal (SMA deviation determines direction).

**Status:** [ ] Pass / Fail

---

### TC-AI4: Conservative Agent — Stop-Loss Fires at 3% Margin Loss

**Precondition:**
Conservative agent has an open trade. Use the SQL editor to simulate a price movement that puts the trade at a 3%+ unrealised loss against its margin.

**Steps:**
1. Find the open trade:
   ```sql
   SELECT id, direction, entry_price, quantity, margin
   FROM public.trades
   WHERE user_id = '00000000-0000-0000-0000-00000c1a0002' AND status = 'open';
   ```
2. Manually trigger the agent again via curl. In the test environment, temporarily set the price feed to return a price that causes `abs(unrealisedPnl) / margin >= 0.03` for the existing trade.
3. Observe the action.

**Expected:**
- Response contains `"action": "stop_loss"`.
- The trade `status` in the database is now `closed`.
- Conservative agent balance changes by the settlement amount (may be a loss).
- No new position is opened in the same cron cycle (stop-loss cycle ends after close).

**Status:** [ ] Pass / Fail

---

### TC-AI5: Conservative Agent — Mean Reversion Signal Logic

**Steps:**
Inspect the Supabase Edge Function logs after several cron invocations (or after TC-AI2).

**Expected (log verification):**
- When `deviation > +2%` (price more than 2% above SMA): logged signal is `SHORT`.
- When `deviation < -2%` (price more than 2% below SMA): logged signal is `LONG`.
- When deviation is within ±2%: logged action is `hold`, no trade opened or closed on signal basis.
- This is the inverse of the momentum (original OpenClaw) strategy — confirm by checking that on any given tick the original OpenClaw's last logged signal is the opposite direction if it was computed around the same time.

**Status:** [ ] Pass / Fail

---

### TC-AI6: Chaos Agent — Cron Invocation Produces a Valid Action

**Steps:**
1. Trigger the Chaos agent manually:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/openclaw-chaos" \
     -H "Authorization: Bearer <SERVICE_ROLE_KEY>"
   ```
2. Check the response body.
3. Query the database:
   ```sql
   SELECT id, symbol, direction, leverage, margin, status
   FROM public.trades
   WHERE user_id = '00000000-0000-0000-0000-00000c1a0003'
   ORDER BY created_at DESC
   LIMIT 3;
   ```

**Expected:**
- HTTP 200, `{"success": true, "data": {"action": "...", "detail": "..."}}`.
- If `action = "open"`: a new trade row exists with `symbol` being either `BTC/USDT` or `ETH/USDT`; `leverage` is an integer in `[5, 50]`.
- If `action = "chaos_flip"`: the previous trade is now `closed` and a new trade is open in the opposite direction on the same symbol.
- No HTTP 500. Logs show the randomly chosen symbol, direction, and leverage.

**Status:** [ ] Pass / Fail

---

### TC-AI7: Chaos Agent — Leverage Range Is 5 to 50 Inclusive

**Steps:**
Trigger the Chaos agent 10 times via curl (if the environment allows rapid re-triggering without balance depletion, or reset the agent's balance between calls):
```
for i in {1..10}; do
  curl -s -X POST "<SUPABASE_URL>/functions/v1/openclaw-chaos" \
    -H "Authorization: Bearer <SERVICE_ROLE_KEY>" | jq '.data.detail'
done
```
Then query: `SELECT DISTINCT leverage FROM public.trades WHERE user_id = '00000000-0000-0000-0000-00000c1a0003' ORDER BY leverage`

**Expected:**
- All observed leverage values are integers within `[5, 50]`.
- No leverage value of 4 or less, or 51 or more, ever appears.
- Over 10+ calls, both `BTC/USDT` and `ETH/USDT` appear as symbol choices (may require more calls to confirm both; acceptable if one symbol dominates by chance in a small sample).

**Status:** [ ] Pass / Fail

---

### TC-AI8: Chaos Agent — Stop-Loss Fires at 10% Margin Loss

**Precondition:**
Chaos agent has an open trade. Simulate a price movement causing `abs(unrealisedPnl) / margin >= 0.10`.

**Steps:**
(Same structure as TC-AI4, but targeting the Chaos agent and threshold = 10%.)

**Expected:**
- Response contains `"action": "stop_loss"`.
- Trade is closed in the database.
- Agent balance reflects the loss.

**Status:** [ ] Pass / Fail

---

### TC-AI9: Chaos Agent — Balance Guard Prevents Trading Below 100 USDT

**Precondition:**
Temporarily set the Chaos agent's balance to 50 USDT via a direct SQL update (test only):
```sql
UPDATE public.users SET balance = 50 WHERE id = '00000000-0000-0000-0000-00000c1a0003';
```

**Steps:**
1. Trigger the Chaos agent via curl.
2. Query for new trades.

**Expected:**
- Response contains `"action": "skip"` with detail mentioning the balance is below 100 USDT.
- No new trade opened for the Chaos agent.

**Teardown:** Restore the agent's balance to a working value.

**Status:** [ ] Pass / Fail

---

### TC-AI10: Conservative Agent — Balance Guard at 100 USDT

**Precondition:**
Temporarily set Conservative agent's balance to 99 USDT:
```sql
UPDATE public.users SET balance = 99 WHERE id = '00000000-0000-0000-0000-00000c1a0002';
```

**Steps:**
1. Trigger the Conservative agent via curl.
2. Query for new trades.

**Expected:**
- Response contains `"action": "skip"`.
- No new trade opened.

**Teardown:** Restore balance.

**Status:** [ ] Pass / Fail

---

### TC-AI11: ACH-001 (Claw Crusher) Evaluates Against Best AI ROI

**Precondition:**
At least one of the three AI agents has a non-zero ROI. A human user has a higher ROI than the leading AI.

**Steps:**
1. Check the current best AI ROI:
   ```sql
   SELECT MAX(roi) FROM public.users WHERE is_human = false;
   ```
2. Ensure human user A's ROI exceeds this value (close a profitable trade if necessary).
3. Trigger `check-achievements` via `close-trade` or directly.
4. Check: `SELECT * FROM public.user_achievement_progress WHERE user_id = '<USER_A_ID>' AND achievement_id = 'ACH-001'`

**Expected:**
- ACH-001 progress for user A reflects "beating" the best AI ROI.
- The `event_data` passed to the achievement evaluator used the dynamically queried best AI ROI (not a hardcoded value). Verify via Edge Function logs: the log line from `close-trade` should show `openclaw_roi=<VALUE>` matching the `MAX(roi)` query result above.

**Status:** [ ] Pass / Fail

---

## Section PA — Price Alerts

---

### TC-PA1: Create Alert — POST Returns 201 With the New Alert Row

**Steps:**
1. Call `manage-price-alerts` as user A to create a BTC above-alert:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
     -H "Authorization: Bearer <USER_A_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "BTC/USDT", "condition": "above", "target_price": 999999999}'
   ```
   (Use a very high target price to prevent the alert from triggering immediately.)
2. Inspect the response body.
3. Query: `SELECT * FROM public.price_alerts WHERE user_id = '<USER_A_ID>' AND is_active = true`

**Expected:**
- HTTP 201, body contains `{"success": true, "data": {"alert": {"id": "...", "symbol": "BTC/USDT", "condition": "above", "target_price": 999999999, "is_active": true, ...}}}`.
- One row in `price_alerts` with `is_active = true`, `triggered_at = NULL`.

**Status:** [ ] Pass / Fail

---

### TC-PA2: List Active Alerts — GET Returns Only Active Alerts for the Caller

**Precondition:**
TC-PA1 completed.

**Steps:**
1. Call GET:
   ```
   curl -X GET "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
     -H "Authorization: Bearer <USER_A_JWT>"
   ```
2. Repeat as user B (who has no alerts).

**Expected:**
- User A response: HTTP 200, `data.alerts` contains the alert created in TC-PA1.
- User B response: HTTP 200, `data.alerts` is `[]`.
- The response does not include alerts belonging to other users (RLS verified).

**Status:** [ ] Pass / Fail

---

### TC-PA3: Max 5 Alerts Cap — Sixth Alert Returns 422

**Precondition:**
User A has 0 active alerts. Create 5 alerts (use high target prices to prevent triggering):

```
# Repeat 5 times with different target_price values:
curl -X POST "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
  -H "Authorization: Bearer <USER_A_JWT>" \
  -H "Content-Type: application/json" \
  -d '{"symbol": "ETH/USDT", "condition": "above", "target_price": 999999}'
```

**Steps:**
1. After 5 successful alert creations, verify the count:
   ```sql
   SELECT COUNT(*) FROM public.price_alerts WHERE user_id = '<USER_A_ID>' AND is_active = true;
   ```
   Expected: 5.
2. Attempt to create a sixth alert:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
     -H "Authorization: Bearer <USER_A_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "BTC/USDT", "condition": "below", "target_price": 1}'
   ```

**Expected:**
- The sixth POST returns HTTP 422 with `{"error": "Maximum of 5 active alerts allowed. Please delete an existing alert first."}`.
- Still exactly 5 rows in `price_alerts` with `is_active = true` for user A.

**Status:** [ ] Pass / Fail

---

### TC-PA4: Delete Alert — Soft-Delete Sets is_active to False

**Precondition:**
User A has at least one active alert. Record its `id` from TC-PA1 or TC-PA3.

**Steps:**
1. Delete the alert:
   ```
   curl -X DELETE "<SUPABASE_URL>/functions/v1/manage-price-alerts/<ALERT_ID>" \
     -H "Authorization: Bearer <USER_A_JWT>"
   ```
2. Query: `SELECT is_active, deleted_by_user FROM public.price_alerts WHERE id = '<ALERT_ID>'`
3. Attempt to GET active alerts and verify the deleted alert is absent.

**Expected:**
- HTTP 200, `{"success": true, "data": {"deactivated_id": "<ALERT_ID>"}}`.
- `is_active = false`, `deleted_by_user = true` (if the schema persists this flag; otherwise only `is_active = false` is required).
- The row still exists in the table (soft delete, not physical delete).
- The GET endpoint no longer returns this alert.
- If user A was at 5 alerts, they can now create a new one (count is back to 4 active).

**Status:** [ ] Pass / Fail

---

### TC-PA5: Delete Non-Owned Alert — Returns 404

**Precondition:**
User A has an active alert. User B exists.

**Steps:**
1. Attempt to delete user A's alert using user B's JWT:
   ```
   curl -X DELETE "<SUPABASE_URL>/functions/v1/manage-price-alerts/<USER_A_ALERT_ID>" \
     -H "Authorization: Bearer <USER_B_JWT>"
   ```
2. Verify user A's alert status is unchanged.

**Expected:**
- HTTP 404, `{"error": "Alert not found or already inactive"}`.
- User A's alert remains `is_active = true` in the database.

**Status:** [ ] Pass / Fail

---

### TC-PA6: Alert Trigger (Above) — scan-liquidations Fires the Alert and Deactivates It

**Precondition:**
User A has a BTC/USDT alert with `condition = "above"` and `target_price` set to a value slightly below the current BTC market price. User A's `telegram_chat_id` is populated (from Phase 3 notification setup).

To set up without waiting for the real price, insert a synthetic alert via the service role:
```sql
INSERT INTO public.price_alerts (user_id, symbol, condition, target_price, is_active)
VALUES ('<USER_A_ID>', 'BTC/USDT', 'above', 1, true);
-- target_price = 1 will always be below the real BTC price and trigger immediately
```

**Steps:**
1. Note the alert `id`.
2. Manually invoke `scan-liquidations`:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/scan-liquidations" \
     -H "Authorization: Bearer <SERVICE_ROLE_KEY>"
   ```
3. Query: `SELECT is_active, triggered_at, triggered_price FROM public.price_alerts WHERE id = '<ALERT_ID>'`
4. Check Telegram: user A should receive a notification.

**Expected:**
- `is_active = false`, `triggered_at` is set to a recent timestamp, `triggered_price` matches the BTC price fetched during the scan.
- User A receives a Telegram message matching the format: `"BTC/USDT has rose above your target price of 1.00 USDT. Current price: <PRICE> USDT"` (or the exact format implemented in `manage-price-alerts`).
- Supabase logs for `scan-liquidations` show: `Price alerts: 1 triggered for BTC/USDT`.

**Status:** [ ] Pass / Fail

---

### TC-PA7: Alert Trigger (Below) — ETH Below-Alert Fires Correctly

**Precondition:**
Insert a synthetic ETH below-alert with a very high `target_price` that the current price will always be below:
```sql
INSERT INTO public.price_alerts (user_id, symbol, condition, target_price, is_active)
VALUES ('<USER_A_ID>', 'ETH/USDT', 'below', 999999999, true);
```

**Steps:**
1. Trigger `scan-liquidations`.
2. Check `price_alerts` row: `SELECT is_active, triggered_price FROM public.price_alerts WHERE user_id = '<USER_A_ID>' AND symbol = 'ETH/USDT'`
3. Check Telegram.

**Expected:**
- Alert deactivated: `is_active = false`, `triggered_price` is a valid ETH price.
- Telegram notification mentions "fell below" not "rose above".

**Status:** [ ] Pass / Fail

---

### TC-PA8: Double-Trigger Prevention — Concurrent scan-liquidations Calls Do Not Send Two Notifications

**Precondition:**
Insert a fresh BTC above-alert at `target_price = 1` for user A.

**Steps:**
1. Simultaneously invoke `scan-liquidations` twice (run the curl command in two terminals at the same moment, or use a load testing tool).
2. After both complete, query: `SELECT COUNT(*) FROM public.price_alerts WHERE id = '<ALERT_ID>' AND is_active = false`
3. Check that only one Telegram message arrived for this alert.

**Expected:**
- The `price_alerts` row shows `is_active = false` (one deactivation happened).
- Only one TG notification was sent for this alert (the second concurrent scan found `is_active = false` after the optimistic lock update, so it skipped the notification).
- Supabase logs for one of the two scan invocations show: `Alert <ID> was already deactivated by concurrent execution — skipping`.

**Status:** [ ] Pass / Fail

---

### TC-PA9: Alert Not Triggered When Condition Is Not Met

**Precondition:**
Insert a BTC above-alert with `target_price = 999999999` (will never be triggered at current prices).

**Steps:**
1. Trigger `scan-liquidations`.
2. Query the alert: `SELECT is_active FROM public.price_alerts WHERE id = '<ALERT_ID>'`

**Expected:**
- `is_active = true` — the alert was not triggered.
- No Telegram notification for this alert.
- Supabase logs do not show this alert as triggered.

**Status:** [ ] Pass / Fail

---

### TC-PA10: Null telegram_chat_id — Alert Triggers But Notification Is Skipped Gracefully

**Precondition:**
Create a test user F who has `telegram_chat_id = NULL`. Insert an always-triggering alert:
```sql
INSERT INTO public.price_alerts (user_id, symbol, condition, target_price, is_active)
VALUES ('<USER_F_ID>', 'BTC/USDT', 'above', 1, true);
```

**Steps:**
1. Trigger `scan-liquidations`.
2. Query: `SELECT is_active, triggered_at FROM public.price_alerts WHERE user_id = '<USER_F_ID>'`

**Expected:**
- Alert is deactivated: `is_active = false`, `triggered_at` is set.
- No Telegram notification error surfaced (the Edge Function skipped the send silently).
- Supabase logs show: `User <ID> has no telegram_chat_id — skipping notification`.
- `scan-liquidations` returned HTTP 200 without errors.

**Status:** [ ] Pass / Fail

---

### TC-PA11: Input Validation — Invalid Symbol, Condition, and Price Rejected

**Steps:**
1. Invalid symbol:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
     -H "Authorization: Bearer <USER_A_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "DOGE/USDT", "condition": "above", "target_price": 1}'
   ```
2. Invalid condition:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
     -H "Authorization: Bearer <USER_A_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "BTC/USDT", "condition": "sideways", "target_price": 1}'
   ```
3. Price of zero:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
     -H "Authorization: Bearer <USER_A_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "BTC/USDT", "condition": "above", "target_price": 0}'
   ```
4. Negative price:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/manage-price-alerts" \
     -H "Authorization: Bearer <USER_A_JWT>" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "BTC/USDT", "condition": "above", "target_price": -100}'
   ```

**Expected:**
- All four requests return HTTP 400 with a descriptive error field.
- No rows inserted in `price_alerts`.
- Specific error messages:
  - Invalid symbol: mentions the allowed symbols (`BTC/USDT`, `ETH/USDT`).
  - Invalid condition: mentions `above` or `below`.
  - Price <= 0: `"target_price must be a positive number"`.

**Status:** [ ] Pass / Fail

---

### TC-PA12: Delete Already-Inactive Alert — Returns 404

**Precondition:**
TC-PA6 completed. The triggered BTC alert is now `is_active = false`.

**Steps:**
1. Attempt to delete the already-inactive alert:
   ```
   curl -X DELETE "<SUPABASE_URL>/functions/v1/manage-price-alerts/<TRIGGERED_ALERT_ID>" \
     -H "Authorization: Bearer <USER_A_JWT>"
   ```

**Expected:**
- HTTP 404, `{"error": "Alert not found or already inactive"}`.

**Status:** [ ] Pass / Fail

---

### TC-PA13: Price Feed Failure During Scan — Alerts for That Symbol Are Skipped

**Precondition:**
This test requires a way to make the Binance price feed temporarily unavailable for one symbol. If the environment does not permit network manipulation, this can be validated by reviewing the existing price-feed-skip logic documented in `scan-liquidations` and confirmed via TC-PA9 (normal miss path) as acceptable coverage.

**Steps (if network manipulation is available):**
1. Block outbound connections to `api.binance.com` at the test environment level.
2. Insert an active BTC/USDT alert at `target_price = 1` for user A.
3. Trigger `scan-liquidations`.
4. Restore network access.
5. Query: `SELECT is_active FROM public.price_alerts WHERE id = '<ALERT_ID>'`

**Expected:**
- Alert remains `is_active = true` — not triggered because the price fetch failed.
- `scan-liquidations` returned HTTP 200 (scan completed for other symbols; failed symbol is skipped, not fatal).
- Supabase logs show `Price feed unavailable` for BTC/USDT and `skipped_reason` in the symbol result.

**Status:** [ ] Pass / Fail / Skipped (environment limitation)

---

### TC-PA14: Price Alert Does Not Affect Liquidation Scanning

**Precondition:**
User A has an open trade that is near (but not at) its liquidation price. User A also has an active price alert.

**Steps:**
1. Trigger `scan-liquidations`.
2. Verify the trade was NOT liquidated (price did not breach the liquidation price).
3. Verify alert processing ran independently of the liquidation step.

**Expected:**
- The trade is still open (`status = 'open'`).
- If the alert condition was met, it triggered independently.
- If not met, the alert is still active.
- `scan-liquidations` returned HTTP 200; the two code paths (liquidation and price alerts) are independent.

**Status:** [ ] Pass / Fail

---

## Section FE — Frontend

---

### TC-FE1: Referral Page — Share Button Opens TG Share Sheet

**Steps:**
1. Open the TG Web App on iOS or Android as user A.
2. Navigate to the `/referral` page.
3. Tap the "Share" or "Invite Friends" button.

**Expected:**
- The Telegram native share sheet opens with the referral link pre-filled in the text field.
- The link format matches `https://openclaw.arena/join?ref=<CODE>` (or the configured base URL).
- On desktop (where TG share API may be unavailable), the button falls back to copying the link to clipboard; a confirmation toast or message appears.

**Status:** [ ] Pass / Fail

---

### TC-FE2: Alerts Page — Create, View, and Delete Flow

**Steps:**
1. Open the `/alerts` page as user A (with 0 active alerts after TC-PA4 cleanup).
2. Tap "New Alert". Fill in: symbol = BTC/USDT, condition = above, target price = 999999999.
3. Submit the form.
4. Verify the alert appears in the Active tab.
5. Tap the delete icon next to the alert. Confirm deletion.
6. Verify the alert disappears from the Active tab.

**Expected:**
- New alert appears in the Active tab immediately after creation (no page reload required).
- The Active tab shows `active_count` badge or counter that increments on create and decrements on delete.
- After deletion, if the user had no other alerts, the empty-state prompt is shown: "No active alerts. Set one to get notified when your target price is hit."
- No browser console errors throughout the flow.

**Status:** [ ] Pass / Fail

---

### TC-FE3: Alerts Page — Max 5 Cap Enforced in UI

**Precondition:**
User A has 5 active alerts (from TC-PA3 setup).

**Steps:**
1. Open the `/alerts` page as user A.
2. Observe the "New Alert" button or form.

**Expected:**
- The "New Alert" button is disabled, or the form displays "Maximum 5 active alerts reached."
- User cannot submit a sixth alert via the UI.

**Status:** [ ] Pass / Fail

---

### TC-FE4: Leaderboard — AI Agent Rows Show Distinct Slugs and Labels

**Steps:**
1. Open the TG Web App and navigate to the leaderboard.
2. Locate the three AI agent rows.

**Expected:**
- "OpenClaw" (original) row shows the `openclaw_original` avatar or icon.
- "OpenClaw Conservative" row shows the `openclaw_conservative` avatar or icon, distinct from the original.
- "OpenClaw Chaos" row shows the `openclaw_chaos` avatar or icon, distinct from both.
- All three are visually distinct from human player rows.
- `is_human = false` marker (lobster icon, bot badge, or equivalent) is present on all three.

**Status:** [ ] Pass / Fail

---

### TC-FE5: Referral Auto-Registration via start_param

**Precondition:**
User A has a referral code. A fresh TG account (user G) has never opened the bot before.

**Steps:**
1. Open `t.me/OpenClawBot?start=<USER_A_CODE>` (or the equivalent deep link for the configured bot) on a device logged in as user G.
2. Accept the bot and open the Web App.
3. After initialization, query: `SELECT referred_by FROM public.users WHERE tg_id = '<USER_G_TG_ID>'`

**Expected:**
- The Web App reads `initDataUnsafe.start_param` and automatically calls `register-referral` with the code.
- `users.referred_by` for user G is set to user A's UUID.
- No error shown to user G; onboarding proceeds normally.

**Status:** [ ] Pass / Fail

---

## Section REG — Phase 1–3 Regression

---

### TC-REG1: Trade Execution Still Works

**Steps:**
1. As user A, open a new BTC/USDT long trade via `execute-trade`.
2. Close it via `close-trade`.

**Expected:**
- Both calls return HTTP 200.
- Trade appears in the `trades` table as `open`, then `closed`.
- User A's balance changes correctly.

**Status:** [ ] Pass / Fail

---

### TC-REG2: Liquidation Scan Still Works for Existing Open Trades

**Steps:**
1. Open a highly leveraged trade as a test user at or near the current price (so liquidation is imminent).
2. Trigger `scan-liquidations`.

**Expected:**
- The trade is liquidated if the price condition is met.
- `scan-liquidations` returns HTTP 200 with `trades_liquidated >= 1` in the summary.
- The Phase 4 price alert step does not break the liquidation path.

**Status:** [ ] Pass / Fail

---

### TC-REG3: Daily Reward Claim Still Works

**Steps:**
1. As user A (who has not claimed today), call `claim-daily-reward`.

**Expected:**
- HTTP 200, balance increases by the reward amount, streak increments.

**Status:** [ ] Pass / Fail

---

### TC-REG4: Achievement Check Still Works

**Steps:**
1. Trigger `check-achievements` (via a `close-trade` call or directly).

**Expected:**
- HTTP 200, no errors.
- ACH-001 through ACH-006 definitions still exist: `SELECT COUNT(*) FROM public.achievements` returns 6.

**Status:** [ ] Pass / Fail

---

### TC-REG5: Original OpenClaw Agent (Aggressive) Still Trades

**Steps:**
1. Trigger `openclaw-trade` manually:
   ```
   curl -X POST "<SUPABASE_URL>/functions/v1/openclaw-trade" \
     -H "Authorization: Bearer <SERVICE_ROLE_KEY>"
   ```

**Expected:**
- HTTP 200, valid action returned.
- `users` row for `00000000-0000-0000-0000-00000c1a0001` is unmodified by Phase 4 migrations (avatar_slug is now `openclaw_original`, balance and ROI unchanged).

**Status:** [ ] Pass / Fail

---

### TC-REG6: RLS on referral_events — User Cannot Read Other Users' Events

**Steps:**
1. Query `referral_events` as user A using their JWT (via the Supabase client, not service role):
   ```sql
   -- Execute via Supabase REST API with user A's JWT, not the service role key
   SELECT * FROM public.referral_events;
   ```

**Expected:**
- User A sees only rows where `referrer_id = <USER_A_ID>` OR `referee_id = <USER_A_ID>`.
- Rows belonging to other users (where neither column matches user A's ID) are invisible.
- No HTTP 403 or 500 — RLS silently filters, not blocks, the query.

**Status:** [ ] Pass / Fail

---

## Summary Scorecard

| Section | Tests | Pass | Fail | Skipped |
|---------|-------|------|------|---------|
| R — Referral System | 12 | | | |
| AI — AI Personalities | 11 | | | |
| PA — Price Alerts | 14 | | | |
| FE — Frontend | 5 | | | |
| REG — Phase 1–3 Regression | 6 | | | |
| **Total** | **48** | | | |

**Phase 4 is SHIP-READY when:**
- All P0 tests pass: TC-R1 through TC-R12, TC-PA1 through TC-PA8, TC-PA11, TC-FE1 through TC-FE4
- All AI personality tests pass: TC-AI1 through TC-AI11
- All regression tests pass: TC-REG1 through TC-REG6
- TC-PA13 is either passing or formally accepted as Skipped due to environment limitations
- Zero open Fail entries in the scorecard above

---

## Known Spec Deviations to Verify at Runtime

The following items represent differences between the Phase 4 spec and the actual implementation discovered during code review. Confirm each during testing:

1. **Conservative leverage is 5x, not 3x.** The spec (PHASE4_SPEC.md Feature 2) states `LEVERAGE = 3x`, but the deployed `openclaw-conservative/index.ts` uses `LEVERAGE = 5, MAX_LEVERAGE = 5`. Verify with the tech lead which value is authoritative before signing off on TC-AI3.

2. **Conservative stop-loss is 3%, not 10%.** The spec mentions a "10% margin loss" stop for Conservative (wider than Aggressive's 5%), but the code uses `TRAILING_STOP_LOSS_FRACTION = 0.03` (3%). Verify the intended value with the tech lead before signing off on TC-AI4.

3. **Chaos leverage range is 5–50x, not 1–20x.** The spec states "leverage drawn uniformly from integers [1, 20]" but the code uses `MIN_LEVERAGE = 5, MAX_LEVERAGE = 50`. Verify with the tech lead before signing off on TC-AI7.

4. **Chaos flip probability is ~50%, not 30%.** The spec states "30% chance it closes and re-randomises" but the code flips on each cycle with ~50% probability (based on `randomDirection() !== existingTrade.direction`). Verify intended behaviour with the tech lead.

5. **Migration numbering uses 015–017, not 009–011.** The spec references migrations `009_referral_system`, `010_ai_personalities`, `011_price_alerts`; the actual files are `015_referral_system`, `016_ai_personalities`, `017_price_alerts`. This is expected given Phase 3 consumed migrations 008–014.

6. **`register-referral` does not populate `referral_code_used`.** Verify whether this column exists in the `015_referral_system.sql` migration. The Edge Function code references it (`referral_code_used: code`), but the SQL schema in PHASE4_SPEC.md does not include this column. If the column is absent, TC-R3 should not check for it.
