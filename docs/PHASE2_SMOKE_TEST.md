# OpenClaw Arena — Phase 2 Smoke Test Checklist

> **For**: Product Owner Manual Acceptance
> **Environment**: Telegram iOS/Android App + Web App + Supabase Dashboard
> **Date**: 2026-03-29
> **Phase**: 2 (Liquidation Scanner, OpenClaw AI Agent, API Key Auth, Tournament Mode, Social Sharing)

---

## Prerequisites

Before running any test case, verify the following are in place:

- [ ] Migrations applied in order: `003_liquidation.sql` → `004_openclaw_agent.sql` → `005_tournaments.sql` → `006_tournament_rpcs.sql`
- [ ] Edge Functions deployed: `scan-liquidations`, `openclaw-trade`, `generate-api-key`, `join-tournament`, `settle-tournament`
- [ ] Phase 1 Edge Functions still deployed: `market-oracle`, `execute-trade`, `close-trade`
- [ ] `INTERNAL_SECRET` Supabase secret is set (required by `generate-api-key`)
- [ ] OpenClaw seeded user exists: `SELECT id, display_name, is_human, balance FROM public.users WHERE id = '00000000-0000-0000-0000-00000c1a0001'` returns one row with `is_human = false, balance = 10000`
- [ ] Frontend deployed with `OpenClawWidget`, `/tournaments` page, and updated `CyberPoster`

---

## Section A — Liquidation Scanner

---

### TC-A1: Basic Liquidation — Long Position Force-Closed at Liq Price

**Precondition:**
A test user has an open LONG BTC/USDT position at 100x leverage. At 100x, the liquidation price is `entry * (1 - 1/100) = entry * 0.99`. Temporarily set the DB `liquidation_price` to a value just above the current BTC market price to simulate a breached condition (e.g., via Supabase Dashboard table editor: `UPDATE trades SET liquidation_price = <current_price + 500> WHERE id = '<trade_id>'`).

**Steps:**
1. Open Supabase Dashboard > Table Editor > `trades`. Note the trade row: `id`, `user_id`, `margin`, `status = 'open'`, `liquidation_price`.
2. Note the user's current `balance` in the `users` table.
3. Invoke the scanner manually via Dashboard > Edge Functions > `scan-liquidations` > Invoke (or `curl -X POST <url>/functions/v1/scan-liquidations -H "Authorization: Bearer <service_role_key>"`).
4. Wait for the invocation to complete (< 5 seconds).
5. Inspect the JSON response body.
6. Reload the `trades` table row.
7. Reload the `liquidation_events` table.
8. Reload the `users` table row for that user.

**Expected:**
- Response body: `{ "success": true, "data": { "total_trades_liquidated": 1, ... } }`
- `trades` row: `status = 'liquidated'`, `exit_price = liquidation_price` (not market price), `realised_pnl = -<margin value>`
- `liquidation_events` table: new row inserted with matching `trade_id`, `user_id`, `symbol`, correct `liquidation_price` and `market_price`, and `margin`
- `users.balance`: unchanged (settlement = 0; margin was already deducted at open)
- `users.roi`: recomputed to reflect current balance

**Status:** [ ] Pass / Fail

---

### TC-A2: Basic Liquidation — Short Position Force-Closed at Liq Price

**Precondition:**
A test user has an open SHORT BTC/USDT position at 50x leverage. Liquidation price for a short is `entry * (1 + 1/50) = entry * 1.02`. Set `liquidation_price` to just below current market price via Dashboard (e.g., `UPDATE trades SET liquidation_price = <current_price - 200>`).

**Steps:**
1. Note the trade's `id`, `margin`, and the user's `balance`.
2. Invoke `scan-liquidations` (POST or GET to the Edge Function URL).
3. Inspect the response.
4. Check `trades` row status and `liquidation_events`.

**Expected:**
- `trades.status = 'liquidated'`
- `liquidation_events` row present with `direction = 'short'`
- Same balance/ROI behaviour as TC-A1

**Status:** [ ] Pass / Fail

---

### TC-A3: Liquidation Status Visible on Trade History (Frontend)

**Precondition:**
TC-A1 or TC-A2 has been completed — a trade with `status = 'liquidated'` exists for the test user.

**Steps:**
1. Open the TG Web App as the test user.
2. Navigate to the trade history or position list.
3. Locate the liquidated trade in the UI.

**Expected:**
- The trade card shows "LIQUIDATED" as its status label (not "CLOSED" or "OPEN")
- The PnL displayed matches the full margin loss (negative, equal to `-margin`)
- No open position card is shown for that trade

**Status:** [ ] Pass / Fail

---

### TC-A4: No Open Trades — Scanner Returns Empty Summary

**Precondition:**
All trades in the `trades` table have `status != 'open'` (close or liquidate any open ones first).

**Steps:**
1. Invoke `scan-liquidations`.
2. Inspect the response body.

**Expected:**
- `{ "success": true, "data": { "total_trades_scanned": 0, "total_trades_liquidated": 0, "symbols_scanned": 0, ... } }`
- No errors in the response
- No new rows in `liquidation_events`

**Status:** [ ] Pass / Fail

---

### TC-A5: Idempotency — Double Liquidation of Same Trade Is a No-Op

**Precondition:**
A trade has just been liquidated (TC-A1 completed). The trade's `status = 'liquidated'`.

**Steps:**
1. Without changing anything in the DB, invoke `scan-liquidations` again immediately.
2. Inspect the response.
3. Check `liquidation_events` row count for that `trade_id`.

**Expected:**
- Scanner response: `total_trades_liquidated = 0` for this scan (no open trades to liquidate)
- `liquidation_events` table still has exactly ONE row for that `trade_id` (no duplicate)
- `users.balance` is unchanged from the first liquidation
- No error is returned — the RPC's idempotency guard (`IF v_trade.status != 'open' THEN RETURN NULL`) handles the second call silently

**Status:** [ ] Pass / Fail

---

### TC-A6: Stale Price Guard — Scanner Skips Symbol When Price Is Old

**Precondition:**
This test validates the `MAX_PRICE_AGE_MS = 10_000` guard. Simulate a stale price by temporarily modifying the `getServerSidePrice` behaviour (if staging allows mocking) or verify the guard exists in logs. Alternatively, check Edge Function logs from a previous run where Binance was slow.

**Steps:**
1. Review Edge Function logs from a previous `scan-liquidations` invocation where Binance was unreachable or slow.
2. OR: In a local/staging environment, mock `getServerSidePrice` to return a timestamp older than 10 seconds.
3. Invoke `scan-liquidations`.

**Expected:**
- Response includes `symbols_skipped: 1` (or more)
- The affected symbol's result shows `skipped_reason` containing "stale" or the age in ms
- No liquidations occur for that symbol
- Other symbols (if any) are still processed normally
- No 500 error — skipping is graceful

**Status:** [ ] Pass / Fail

---

### TC-A7: High Liquidation Rate Warning Flag

**Precondition:**
Set up a scenario where more than 50% of all open trades are breached (e.g., insert 4 open trades and manipulate `liquidation_price` on 3 of them to be breached). This tests the `HIGH_LIQUIDATION_RATE_THRESHOLD = 0.5` warning.

**Steps:**
1. Create 4+ open trades for different users via `execute_trade_txn` RPC or direct DB insert.
2. Manipulate `liquidation_price` on at least 3 of them to be immediately breached at current market price.
3. Invoke `scan-liquidations`.
4. Inspect the response body.

**Expected:**
- `{ "success": true, "data": { "high_liquidation_rate_warning": true, ... } }`
- All breached trades are still liquidated (warning is observational only, does not block processing)
- Edge Function logs show `WARNING: High liquidation rate detected`

**Status:** [ ] Pass / Fail

---

## Section B — OpenClaw AI Agent

---

### TC-B1: Manual Invocation — Agent Opens a Position When No Position Exists

**Precondition:**
OpenClaw user (`id = '00000000-0000-0000-0000-00000c1a0001'`) has no open BTC/USDT trades. Balance is >= 100 USDT.

**Steps:**
1. Verify via Dashboard: `SELECT * FROM trades WHERE user_id = '00000000-0000-0000-0000-00000c1a0001' AND status = 'open'` returns empty.
2. Invoke `openclaw-trade` via POST: `curl -X POST <url>/functions/v1/openclaw-trade -H "Authorization: Bearer <service_role_key>"`.
3. Inspect the response body.
4. Check the `trades` table for a new row belonging to OpenClaw.

**Expected:**
- Response: `{ "success": true, "data": { "action": "open", "detail": "Opened long/short at ... with margin=..." } }`
- New trade row in `trades` with `user_id = '00000000-0000-0000-0000-00000c1a0001'`, `symbol = 'BTC/USDT'`, `leverage = 10`, `status = 'open'`
- `margin = balance * 0.02` (approximately, capped at 5% of balance)
- `liquidation_price` is mathematically correct: `entry * (1 - 1/10)` for long, `entry * (1 + 1/10)` for short
- `users.balance` for OpenClaw is reduced by the margin amount

**Status:** [ ] Pass / Fail

---

### TC-B2: Agent Holds When Signal Matches Existing Position

**Precondition:**
OpenClaw has an existing open LONG position (created in TC-B1 or manually inserted). Current BTC price is above SMA(12) so the signal is still LONG.

**Steps:**
1. Confirm OpenClaw has an open LONG trade.
2. Invoke `openclaw-trade` again.
3. Inspect response.
4. Check that no new trades were opened or closed.

**Expected:**
- Response: `{ "success": true, "data": { "action": "hold", "detail": "Signal LONG agrees with open long position. Holding." } }`
- Trade count for OpenClaw remains the same (1 open trade)
- `users.balance` for OpenClaw unchanged

**Status:** [ ] Pass / Fail

---

### TC-B3: Agent Closes and Reopens on Signal Flip

**Precondition:**
OpenClaw has an existing open LONG position. To simulate a signal flip, temporarily arrange for the current BTC price to be below SMA(12) — this requires either waiting for market conditions or mocking on staging.

**Steps:**
1. Confirm OpenClaw has an open LONG trade. Note the trade ID.
2. Trigger a situation where current price < SMA(12) (verify via Edge Function logs or manual Binance kline check).
3. Invoke `openclaw-trade`.
4. Inspect response.
5. Check the `trades` table.

**Expected:**
- Response: `{ "action": "signal_flip", "detail": "Closed long trade <id>. Opened short at ... with margin=..." }`
- The old LONG trade: `status = 'closed'`, `exit_price` near current market price, `realised_pnl` calculated
- A new SHORT trade opened with `status = 'open'`
- `users.balance` updated to reflect the closed trade's settlement, then reduced again by new trade's margin

**Status:** [ ] Pass / Fail

---

### TC-B4: Agent Triggers Stop-Loss When Unrealised Loss Exceeds 5%

**Precondition:**
OpenClaw has an open trade where the current unrealised loss fraction exceeds `TRAILING_STOP_LOSS_FRACTION = 0.05` (5% of margin). To simulate: open a LONG trade at a price now well above current market, so `unrealised_pnl / margin > 5%`.

**Steps:**
1. Manually insert or arrange an open trade for OpenClaw with an entry price that causes > 5% unrealised loss at current market price.
2. Invoke `openclaw-trade`.
3. Inspect response.
4. Check that no new position is opened in the same cycle.

**Expected:**
- Response: `{ "action": "stop_loss", "detail": "Closed ... trade ... due to stop-loss. Loss=X%" }` where X > 5
- The trade is closed, `status = 'closed'`
- No new trade is opened in this same invocation cycle
- `users.balance` updated with the (negative) settlement

**Status:** [ ] Pass / Fail

---

### TC-B5: Agent Skips When Balance Below Minimum (100 USDT)

**Precondition:**
Temporarily reduce OpenClaw's balance below 100 USDT via direct DB update: `UPDATE users SET balance = 50 WHERE id = '00000000-0000-0000-0000-00000c1a0001'`. Ensure no open position exists.

**Steps:**
1. Set balance to 50.
2. Invoke `openclaw-trade`.
3. Inspect response.
4. Restore balance after the test.

**Expected:**
- Response: `{ "success": true, "data": { "action": "skip", "detail": "Balance ... is below minimum 100 USDT. Skipping." } }`
- No new trade opened
- `trades` table unchanged

**Status:** [ ] Pass / Fail

---

### TC-B6: OpenClaw Widget Shows ROI on Frontend

**Precondition:**
OpenClaw user has a non-zero ROI (has traded and has a realised or unrealised gain/loss). At minimum the `leaderboard_view` should include the row where `username = 'openclaw_lobster'`.

**Steps:**
1. Open the TG Web App.
2. Navigate to the main trading page.
3. Observe the widget area near the top of the page.

**Expected:**
- A compact single-line widget is visible showing "OpenClaw" with the lobster emoji
- The widget displays "ROI" and a formatted percentage (e.g., "+2.15%" in neon green or "-0.80%" in orange)
- If ROI is positive, a subtle pulse animation ring is visible around the lobster emoji
- The widget refreshes every 30 seconds (not observable directly, but no stale-forever behaviour)
- If `leaderboard_view` has a `rank` for OpenClaw, the rank number is shown (e.g., "#3")

**Status:** [ ] Pass / Fail

---

### TC-B7: OpenClaw Appears on Leaderboard With Lobster Badge

**Precondition:**
OpenClaw user exists with `is_human = false`.

**Steps:**
1. Open the Leaderboard page in the TG Web App.
2. Find the OpenClaw entry in the list.

**Expected:**
- OpenClaw appears in the leaderboard (not hidden)
- The lobster badge/icon (🦞) is shown instead of the human badge (👤)
- Display name shows "OpenClaw"
- Balance and ROI are shown correctly

**Status:** [ ] Pass / Fail

---

## Section C — API Key Authentication

---

### TC-C1: Generate API Key — Success Path

**Precondition:**
`INTERNAL_SECRET` is configured as a Supabase secret. A valid test user UUID is known.

**Steps:**
1. Call `generate-api-key` with the correct `X-Internal-Secret` header:
   ```
   curl -X POST <url>/functions/v1/generate-api-key \
     -H "X-Internal-Secret: <INTERNAL_SECRET value>" \
     -H "Content-Type: application/json" \
     -d '{"user_id": "<valid-user-uuid>", "label": "smoke-test-key"}'
   ```
2. Inspect the response body.
3. Check the `api_keys` table in Supabase Dashboard.

**Expected:**
- HTTP 201 status
- Response: `{ "success": true, "data": { "key_prefix": "oca_xxxxxxxx", "raw_key": "oca_...", "label": "smoke-test-key" } }`
- `raw_key` starts with `"oca_"` and is 36 characters total
- `api_keys` table has a new row: `user_id`, `key_prefix` (first 12 chars of raw key), `hashed_key` (SHA-256 hex, not the raw key), `label = 'smoke-test-key'`, `is_active = true`
- The `raw_key` is NOT stored in the DB — only the `hashed_key` is persisted

**Status:** [ ] Pass / Fail

---

### TC-C2: API Key Auth on execute-trade (Tier 3 Auth Path)

**Precondition:**
An API key was generated for a test user in TC-C1. The test user has sufficient balance (>= 10 USDT margin). Note the full `raw_key` from TC-C1 — it will not be shown again.

**Steps:**
1. Call `execute-trade` using only the `X-API-Key` header (no JWT Bearer token, no `x-user-id`):
   ```
   curl -X POST <url>/functions/v1/execute-trade \
     -H "X-API-Key: <raw_key from TC-C1>" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "BTC/USDT", "direction": "long", "leverage": 10, "margin": 10}'
   ```
2. Inspect the response.
3. Check the `trades` table.
4. Check `api_keys.last_used_at` for the key row.

**Expected:**
- HTTP 201 status
- Response: `{ "success": true, "data": { "id": "...", "symbol": "BTC/USDT", ... } }`
- New trade row in `trades` attributed to the test user's `user_id`
- `api_keys.last_used_at` is updated to the current time (fire-and-forget update)
- Edge Function logs show: `[auth] Resolved identity via API key for user: <user_id>`

**Status:** [ ] Pass / Fail

---

### TC-C3: API Key Auth — Invalid Key Returns 401

**Precondition:**
None.

**Steps:**
1. Call `execute-trade` with a fake/invalid `X-API-Key` header:
   ```
   curl -X POST <url>/functions/v1/execute-trade \
     -H "X-API-Key: oca_thisisafakekeythatdoesnotexist00" \
     -H "Content-Type: application/json" \
     -d '{"symbol": "BTC/USDT", "direction": "long", "leverage": 10, "margin": 10}'
   ```
2. Inspect the response.

**Expected:**
- HTTP 401 status
- Response: `{ "error": "Unauthorized" }`
- No trade is created
- Edge Function logs show: `[auth] API key provided but not found or inactive`

**Status:** [ ] Pass / Fail

---

### TC-C4: generate-api-key — Missing X-Internal-Secret Returns 401

**Precondition:**
None.

**Steps:**
1. Call `generate-api-key` without the `X-Internal-Secret` header:
   ```
   curl -X POST <url>/functions/v1/generate-api-key \
     -H "Content-Type: application/json" \
     -d '{"user_id": "<any-uuid>"}'
   ```
2. Inspect the response.

**Expected:**
- HTTP 401 status
- Response: `{ "error": "Unauthorized" }`
- No API key row is created in `api_keys`

**Status:** [ ] Pass / Fail

---

### TC-C5: generate-api-key — Duplicate Label Returns 409

**Precondition:**
TC-C1 completed successfully. The label `"smoke-test-key"` already exists for the test user.

**Steps:**
1. Call `generate-api-key` again with the same user and label:
   ```
   curl -X POST <url>/functions/v1/generate-api-key \
     -H "X-Internal-Secret: <INTERNAL_SECRET>" \
     -H "Content-Type: application/json" \
     -d '{"user_id": "<same-user-uuid>", "label": "smoke-test-key"}'
   ```
2. Inspect the response.

**Expected:**
- HTTP 409 status
- Response: `{ "error": "An API key with the label \"smoke-test-key\" already exists for this user." }`
- No new row in `api_keys`

**Status:** [ ] Pass / Fail

---

### TC-C6: generate-api-key — Invalid user_id Format Returns 400

**Precondition:**
None.

**Steps:**
1. Call `generate-api-key` with a non-UUID `user_id`:
   ```
   curl -X POST <url>/functions/v1/generate-api-key \
     -H "X-Internal-Secret: <INTERNAL_SECRET>" \
     -H "Content-Type: application/json" \
     -d '{"user_id": "not-a-uuid"}'
   ```
2. Inspect the response.

**Expected:**
- HTTP 400 status
- Response: `{ "error": "user_id must be a valid UUID" }`

**Status:** [ ] Pass / Fail

---

## Section D — Tournament Mode

---

### TC-D1: Create Tournament and Verify DB Structure

**Precondition:**
Migration 005 and 006 have been applied. The `tournaments` and `tournament_participants` tables exist.

**Steps:**
1. Insert a tournament via Supabase Dashboard SQL editor:
   ```sql
   INSERT INTO public.tournaments (name, description, start_at, end_at, status, max_participants, min_balance)
   VALUES (
     'Smoke Test Tournament',
     'Created for Phase 2 smoke testing',
     NOW() - INTERVAL '1 minute',
     NOW() + INTERVAL '1 hour',
     'active',
     10,
     100
   )
   RETURNING id, name, status, max_participants, min_balance;
   ```
2. Note the returned `id`.
3. Verify `tournament_status` ENUM exists: `SELECT enumlabel FROM pg_enum JOIN pg_type ON pg_type.oid = pg_enum.enumtypid WHERE typname = 'tournament_status'`.
4. Verify `trades.tournament_id` column exists: `SELECT column_name FROM information_schema.columns WHERE table_name = 'trades' AND column_name = 'tournament_id'`.

**Expected:**
- Tournament row inserted with `status = 'active'`
- ENUM values include: `upcoming`, `active`, `settling`, `completed`
- `trades.tournament_id` column exists with nullable FK to `tournaments.id`

**Status:** [ ] Pass / Fail

---

### TC-D2: Join Tournament — Success Path With Balance Snapshot

**Precondition:**
TC-D1 completed. Tournament ID is known. Test user is authenticated (JWT available) with balance >= 100 USDT.

**Steps:**
1. Call `join-tournament`:
   ```
   curl -X POST <url>/functions/v1/join-tournament \
     -H "Authorization: Bearer <user-jwt>" \
     -H "Content-Type: application/json" \
     -d '{"tournament_id": "<tournament-id-from-TC-D1>"}'
   ```
2. Inspect the response body.
3. Check `tournament_participants` table.
4. Note the `entry_balance` value.

**Expected:**
- HTTP 200 status
- Response: `{ "success": true, "data": { "tournament_id": "...", "user_id": "...", "entry_balance": <current balance>, "joined_at": "...", ... } }`
- `tournament_participants` table has a new row with `entry_balance` equal to the user's current balance at the time of joining
- `final_roi` and `rank` are both NULL (not yet settled)

**Status:** [ ] Pass / Fail

---

### TC-D3: Join Tournament — Tournaments Page Loads and Shows the Tournament

**Precondition:**
TC-D1 completed. At least one active tournament exists. Test user is logged in.

**Steps:**
1. In the TG Web App, navigate to the `/tournaments` page (via a link or direct URL).
2. Observe the "Live" tab.
3. Tap the tournament card to expand it.
4. Tap "Join Tournament" if not already joined.

**Expected:**
- Page loads without error, showing the tab bar: "Live", "Upcoming", "Ended"
- "Live" tab shows the smoke test tournament with status badge "LIVE" (green)
- Card shows participant count, min balance, and time remaining
- Expanding the card reveals a "Join Tournament" button (if not yet joined) or "Joined" indicator (if already joined)
- After joining, button changes to "Joined" and participant count increments by 1
- TG haptic feedback triggers on successful join

**Status:** [ ] Pass / Fail

---

### TC-D4: Join Tournament Twice — Second Join Returns 409

**Precondition:**
TC-D2 completed. The test user is already a participant in the tournament.

**Steps:**
1. Call `join-tournament` again with the same `tournament_id` and the same user's JWT.

**Expected:**
- HTTP 409 status
- Response: `{ "error": "You have already joined this tournament." }`
- No duplicate row in `tournament_participants`

**Status:** [ ] Pass / Fail

---

### TC-D5: Join Tournament With Insufficient Balance Returns 400

**Precondition:**
A user with balance < 100 USDT exists (or temporarily reduce a test user's balance). The tournament has `min_balance = 100`.

**Steps:**
1. Reduce test user balance: `UPDATE users SET balance = 50 WHERE id = '<user-id>'`.
2. Call `join-tournament` for that user.
3. Restore balance after test.

**Expected:**
- HTTP 400 status
- Response: `{ "error": "Insufficient balance to join this tournament." }`
- No `tournament_participants` row for this user

**Status:** [ ] Pass / Fail

---

### TC-D6: Join Tournament That Has Ended — Returns 409 (Closed)

**Precondition:**
Create a completed tournament: `INSERT INTO tournaments (..., status = 'completed', ...)`.

**Steps:**
1. Insert a tournament with `status = 'completed'`.
2. Call `join-tournament` with its ID.

**Expected:**
- HTTP 409 status
- Response: `{ "error": "This tournament is no longer accepting participants." }`
- `join_tournament_txn` raises `tournament_closed` exception

**Status:** [ ] Pass / Fail

---

### TC-D7: Join Non-Existent Tournament — Returns 404

**Precondition:**
None.

**Steps:**
1. Call `join-tournament` with a valid-format UUID that does not exist in the `tournaments` table:
   ```
   -d '{"tournament_id": "00000000-0000-0000-0000-000000000000"}'
   ```

**Expected:**
- HTTP 404 status
- Response: `{ "error": "Tournament not found." }`

**Status:** [ ] Pass / Fail

---

### TC-D8: Tournament Settlement — settle-tournament Force-Closes Open Trades and Assigns Rankings

**Precondition:**
A tournament exists with `status = 'active'` and `end_at` in the past. At least 2 users have joined (TC-D2 completed for multiple users). At least 1 participant has an open trade tagged with `tournament_id` (verify `trades.tournament_id IS NOT NULL`).

**Steps:**
1. Set the tournament's `end_at` to the past if not already: `UPDATE tournaments SET end_at = NOW() - INTERVAL '1 second' WHERE id = '<tournament-id>'`.
2. Invoke `settle-tournament`:
   ```
   curl -X POST <url>/functions/v1/settle-tournament \
     -H "Authorization: Bearer <service_role_key>"
   ```
3. Inspect the response body.
4. Check `tournaments` table — status should be `completed`.
5. Check `tournament_participants` — `final_roi` and `rank` should be populated.
6. Check open trades tagged with this `tournament_id` — they should now be `closed`.

**Expected:**
- HTTP 200 response: `{ "success": true, "data": { "settledTournaments": ["<tournament-id>"], "forceClosedTrades": <N>, ... } }`
- `tournaments.status = 'completed'`
- All `tournament_participants` rows have `final_roi` (numeric, can be positive or negative) and `rank` (integer starting at 1)
- Rankings are ordered by `final_roi DESC`, ties broken by `joined_at ASC`
- Force-closed trades: `status = 'closed'`, `exit_price` = market price at settlement time, `realised_pnl` computed correctly

**Status:** [ ] Pass / Fail

---

### TC-D9: Tournament Settlement Idempotency — Settling Completed Tournament Returns Safe Error

**Precondition:**
TC-D8 completed. The tournament's `status = 'completed'`.

**Steps:**
1. Invoke `settle-tournament` again (same URL, same body).
2. Inspect the response.

**Expected:**
- The function may return HTTP 207 or 200 with errors, or handle gracefully
- The `settle_tournament_txn` RPC raises `invalid_status: Cannot settle tournament with status=completed`
- No rankings are overwritten
- No additional force-closes occur
- The error is surfaced in the `errors` array of the response body, not as an unhandled crash

**Status:** [ ] Pass / Fail

---

### TC-D10: Upcoming Tournament Auto-Activation

**Precondition:**
Create a tournament with `status = 'upcoming'` and `start_at` in the past.

**Steps:**
1. Insert: `INSERT INTO tournaments (name, start_at, end_at, status) VALUES ('Auto Activation Test', NOW() - INTERVAL '5 minutes', NOW() + INTERVAL '2 hours', 'upcoming')`.
2. Invoke `settle-tournament`.
3. Check the tournament's status.

**Expected:**
- Response includes `activatedTournaments: ["<new-tournament-id>"]`
- `tournaments.status` changes from `upcoming` to `active` for the inserted row

**Status:** [ ] Pass / Fail

---

### TC-D11: Tournament Leaderboard View — No user_id Exposed

**Precondition:**
TC-D2 completed. `tournament_leaderboard_view` has rows.

**Steps:**
1. Query the view from the Supabase Dashboard SQL editor:
   ```sql
   SELECT * FROM public.tournament_leaderboard_view LIMIT 5;
   ```
2. Inspect the returned columns.

**Expected:**
- Columns visible: `tournament_id`, `display_name`, `username`, `is_human`, `entry_balance`, `final_roi`, `rank`, `joined_at`
- Column `user_id` is NOT present in the output (intentionally excluded from view projection)
- Column `balance` (current user balance) is NOT present

**Status:** [ ] Pass / Fail

---

## Section E — Social Sharing (CyberPoster v2)

---

### TC-E1: CyberPoster Shows vs OpenClaw Comparison Panel

**Precondition:**
OpenClaw has a non-zero ROI (at least one trade has been opened and the `leaderboard_view` returns a `roi` value for `username = 'openclaw_lobster'`). The frontend is deployed with the updated `CyberPoster` that accepts `openclawRoi` prop.

**Steps:**
1. Open the TG Web App and place and close a trade (any direction, any PnL).
2. After closing, the CyberPoster modal should appear automatically.
3. Observe the poster content.

**Expected:**
- The poster shows a "YOU vs OPENCLAW" comparison section
- "👤 YOU" side shows the user's cumulative ROI (formatted as "+X.XX%")
- "🦞 OPENCLAW" side shows OpenClaw's ROI with the correct sign and color (green for positive, orange for negative)
- The "VS" text appears between the two columns
- The section is only visible when `openclawRoi != null` — if OpenClaw has no data, this section is absent

**Status:** [ ] Pass / Fail

---

### TC-E2: CyberPoster Shows Tournament Rank Badge When Applicable

**Precondition:**
TC-D8 completed (tournament settled). Test user's `tournament_participants` row has a `rank` value. The frontend correctly passes `tournamentRank` prop to `CyberPoster`.

**Steps:**
1. After a tournament has settled, close a trade.
2. When the CyberPoster appears, observe whether the tournament rank badge is present.

**Expected:**
- A badge reads "🏆 TOURNAMENT RANK #N" where N is the user's final rank
- Badge is styled with a neon-colored border matching the trade direction (green/orange)
- If the user is not in a tournament or the trade has no `tournament_id`, the badge is absent

**Status:** [ ] Pass / Fail

---

### TC-E3: Social Sharing — Telegram switchInlineQuery Path

**Precondition:**
The TG Web App is running in Telegram (not a regular browser). The TG SDK version is >= 6.9 (which supports `switchInlineQuery`). A poster has been generated (TC-E1 completed).

**Steps:**
1. After CyberPoster generates a PNG, tap the "Share Battle Report" button.
2. Observe what happens in the Telegram app.

**Expected:**
- If TG SDK >= 6.9: `tgWebApp.switchInlineQuery()` is called, transitioning the user to an inline query sharing flow within Telegram (share to chats/groups/channels)
- The share text format is: "{emoji} {pnl%} on {symbol} {direction} {leverage}x — OpenClaw Arena"
- No browser share dialog or download occurs (TG native takes priority)

**Status:** [ ] Pass / Fail

---

### TC-E4: Social Sharing — Web Share API Fallback

**Precondition:**
The app is running in a browser context where `navigator.share` is available but TG's `switchInlineQuery` is not (e.g., mobile Safari or Chrome outside TG, or TG SDK < 6.9). A poster PNG has been generated.

**Steps:**
1. Open the app in a mobile browser (or simulate TG SDK absence).
2. Generate a poster and tap "Share Battle Report".

**Expected:**
- The native OS share sheet appears (iOS Share extension or Android share intent)
- The PNG file is offered as an attachment (`openclaw-battle-report.png`)
- The share text is included

**Status:** [ ] Pass / Fail

---

### TC-E5: Social Sharing — Download Fallback

**Precondition:**
`navigator.share` is unavailable (e.g., desktop Chrome or an environment where `canShare({ files })` returns false). A poster PNG has been generated.

**Steps:**
1. Open the app in a desktop browser.
2. Generate a poster and tap "Share Battle Report".

**Expected:**
- A file download is triggered automatically (`openclaw-battle-report.png`)
- No error dialog or crash
- The downloaded PNG is a valid image file that opens correctly

**Status:** [ ] Pass / Fail

---

### TC-E6: CyberPoster PNG Quality — Retina Sharp on High-DPI Devices

**Precondition:**
The app is running on a high-DPI device (iPhone 15 Pro at 3x, or any modern Android flagship at 2.75x+).

**Steps:**
1. Generate a poster.
2. Long-press the poster image to save it to the device photo library.
3. Open the saved image in the native photo viewer and zoom in to maximum.

**Expected:**
- Text in the poster (ROI numbers, labels, taunt text) is sharp and crisp at native resolution
- No blurry or pixelated text visible even at 2x zoom in the photo viewer
- Image dimensions should be `390 * devicePixelRatio` x `640 * devicePixelRatio` pixels

**Status:** [ ] Pass / Fail

---

## Section F — Phase 1 Regression Tests

---

### TC-F1: Manual Trade Execution Still Works (execute-trade, Regression)

**Precondition:**
Test user has balance >= 10 USDT. No open position for the chosen symbol.

**Steps:**
1. Open the TG Web App.
2. Select BTC/USDT, set leverage to 10x, margin to 50 USDT, direction LONG.
3. Tap the execute trade button.

**Expected:**
- Trade executes successfully (HTTP 201 from `execute-trade`)
- Position card appears showing entry price, liquidation price, live PnL
- `users.balance` decreases by 50 USDT
- No regression errors introduced by Phase 2 migrations

**Status:** [ ] Pass / Fail

---

### TC-F2: Manual Trade Close Still Works (close-trade, Regression)

**Precondition:**
TC-F1 completed. An open trade exists.

**Steps:**
1. On the position card, tap "Close Position".
2. Confirm the close.

**Expected:**
- Trade closes (HTTP 200 from `close-trade`)
- `trades.status = 'closed'`, `realised_pnl` computed correctly
- `users.balance` updated with settlement
- CyberPoster modal appears
- No crash or regression from Phase 2 changes

**Status:** [ ] Pass / Fail

---

### TC-F3: Leaderboard Still Loads and Shows Human/AI Badge (Regression)

**Precondition:**
At least 2 users exist (one human, OpenClaw AI). Phase 2 migrations applied.

**Steps:**
1. Open the Leaderboard page in the TG Web App.
2. Observe entries.

**Expected:**
- Leaderboard loads without error
- Human users show 👤 badge
- OpenClaw shows 🦞 badge
- ROI values displayed correctly
- Top 3 neon glow effects still present
- `tg_id` not exposed in any response or HTML

**Status:** [ ] Pass / Fail

---

### TC-F4: Duplicate Position Rejection Still Works (Regression)

**Precondition:**
Test user already has an open BTC/USDT position.

**Steps:**
1. Attempt to open another BTC/USDT position for the same user (via API or UI).

**Expected:**
- HTTP 409 from `execute-trade`
- Error message: "You already have an open BTC/USDT position. Close it before opening a new one."
- No duplicate trade row created

**Status:** [ ] Pass / Fail

---

### TC-F5: Insufficient Balance Rejection Still Works (Regression)

**Precondition:**
Test user has balance = 5 USDT. Minimum margin is 10 USDT.

**Steps:**
1. Attempt to open a trade with `margin = 10`.

**Expected:**
- HTTP 400 from `execute-trade`
- Error: "Insufficient balance to cover the required margin."
- `users.balance` unchanged

**Status:** [ ] Pass / Fail

---

### TC-F6: RLS — Users Cannot Read Other Users' Data (Security Regression)

**Precondition:**
Two test users exist. User A is authenticated.

**Steps:**
1. From User A's browser session, execute: `supabase.from('users').select('tg_id, balance').order('roi', { ascending: false }).limit(5)`
2. Check how many rows are returned.

**Expected:**
- Only 1 row returned: User A's own row (RLS policy `USING (auth.uid() = id)`)
- Other users' `tg_id` and `balance` are not accessible
- Phase 2 migrations did not introduce any new RLS bypass

**Status:** [ ] Pass / Fail

---

### TC-F7: Phase 2 Migrations Did Not Break Existing RPC Functions

**Precondition:**
Migrations 003-006 have been applied on top of 001-002.

**Steps:**
1. Via Supabase Dashboard SQL editor, verify all RPCs still exist:
   ```sql
   SELECT proname FROM pg_proc
   WHERE proname IN (
     'execute_trade_txn',
     'close_trade_txn',
     'liquidate_trade_txn',
     'join_tournament_txn',
     'settle_tournament_txn'
   )
   ORDER BY proname;
   ```

**Expected:**
- All 5 RPC names returned
- No "function does not exist" errors during TC-F1 and TC-F2

**Status:** [ ] Pass / Fail

---

## Acceptance Sign-Off

| TC | Feature | Result | Tester | Date |
|----|---------|--------|--------|------|
| TC-A1 | Liquidation: long position liquidated | [ ] Pass / [ ] Fail | | |
| TC-A2 | Liquidation: short position liquidated | [ ] Pass / [ ] Fail | | |
| TC-A3 | Liquidation: "LIQUIDATED" visible on frontend | [ ] Pass / [ ] Fail | | |
| TC-A4 | Liquidation: empty scan returns summary | [ ] Pass / [ ] Fail | | |
| TC-A5 | Liquidation: idempotency (no double-liquidation) | [ ] Pass / [ ] Fail | | |
| TC-A6 | Liquidation: stale price guard skips symbol | [ ] Pass / [ ] Fail | | |
| TC-A7 | Liquidation: high liquidation rate warning flag | [ ] Pass / [ ] Fail | | |
| TC-B1 | AI Agent: opens position when none exists | [ ] Pass / [ ] Fail | | |
| TC-B2 | AI Agent: holds when signal matches position | [ ] Pass / [ ] Fail | | |
| TC-B3 | AI Agent: closes and reopens on signal flip | [ ] Pass / [ ] Fail | | |
| TC-B4 | AI Agent: stop-loss triggers at 5% loss | [ ] Pass / [ ] Fail | | |
| TC-B5 | AI Agent: skips when balance < 100 USDT | [ ] Pass / [ ] Fail | | |
| TC-B6 | Frontend: OpenClaw widget shows ROI | [ ] Pass / [ ] Fail | | |
| TC-B7 | Leaderboard: OpenClaw shows lobster badge | [ ] Pass / [ ] Fail | | |
| TC-C1 | API Key: generate key success | [ ] Pass / [ ] Fail | | |
| TC-C2 | API Key: authenticate execute-trade via X-API-Key | [ ] Pass / [ ] Fail | | |
| TC-C3 | API Key: invalid key returns 401 | [ ] Pass / [ ] Fail | | |
| TC-C4 | API Key: missing internal secret returns 401 | [ ] Pass / [ ] Fail | | |
| TC-C5 | API Key: duplicate label returns 409 | [ ] Pass / [ ] Fail | | |
| TC-C6 | API Key: invalid user_id format returns 400 | [ ] Pass / [ ] Fail | | |
| TC-D1 | Tournament: DB structure verified | [ ] Pass / [ ] Fail | | |
| TC-D2 | Tournament: join success + balance snapshot | [ ] Pass / [ ] Fail | | |
| TC-D3 | Tournament: /tournaments page loads and shows tournament | [ ] Pass / [ ] Fail | | |
| TC-D4 | Tournament: joining twice returns 409 | [ ] Pass / [ ] Fail | | |
| TC-D5 | Tournament: insufficient balance returns 400 | [ ] Pass / [ ] Fail | | |
| TC-D6 | Tournament: joining completed tournament returns 409 | [ ] Pass / [ ] Fail | | |
| TC-D7 | Tournament: non-existent tournament returns 404 | [ ] Pass / [ ] Fail | | |
| TC-D8 | Tournament: settlement force-closes trades + assigns ranks | [ ] Pass / [ ] Fail | | |
| TC-D9 | Tournament: re-settling completed tournament is safe | [ ] Pass / [ ] Fail | | |
| TC-D10 | Tournament: upcoming tournament auto-activates | [ ] Pass / [ ] Fail | | |
| TC-D11 | Tournament: leaderboard view does not expose user_id | [ ] Pass / [ ] Fail | | |
| TC-E1 | Poster: vs OpenClaw comparison shown | [ ] Pass / [ ] Fail | | |
| TC-E2 | Poster: tournament rank badge shown | [ ] Pass / [ ] Fail | | |
| TC-E3 | Sharing: TG switchInlineQuery path | [ ] Pass / [ ] Fail | | |
| TC-E4 | Sharing: Web Share API fallback | [ ] Pass / [ ] Fail | | |
| TC-E5 | Sharing: download fallback | [ ] Pass / [ ] Fail | | |
| TC-E6 | Poster: Retina-sharp PNG on high-DPI device | [ ] Pass / [ ] Fail | | |
| TC-F1 | Regression: execute-trade still works | [ ] Pass / [ ] Fail | | |
| TC-F2 | Regression: close-trade still works | [ ] Pass / [ ] Fail | | |
| TC-F3 | Regression: leaderboard loads correctly | [ ] Pass / [ ] Fail | | |
| TC-F4 | Regression: duplicate position rejected | [ ] Pass / [ ] Fail | | |
| TC-F5 | Regression: insufficient balance rejected | [ ] Pass / [ ] Fail | | |
| TC-F6 | Regression: RLS prevents cross-user data access | [ ] Pass / [ ] Fail | | |
| TC-F7 | Regression: all RPC functions exist after migrations | [ ] Pass / [ ] Fail | | |

---

## Go/No-Go Criteria

**Blocking (all must pass before production deploy):**
- TC-A1, TC-A2: Core liquidation correctness
- TC-A5: Idempotency — a double-liquidation would destroy user balances
- TC-C3, TC-C4: Auth security — invalid keys must be rejected
- TC-D4: Joining twice must be prevented at DB level
- TC-D8: Settlement must close trades and assign correct rankings
- TC-D9: Re-settling a completed tournament must not corrupt data
- TC-F6: RLS regression — any breach here blocks deploy immediately
- TC-F7: All RPCs exist — broken migrations fail the entire service

**Important (fix before deploy, escalate if cannot):**
- TC-A3: Users must see liquidation status in the UI
- TC-B1, TC-B2, TC-B6: OpenClaw must be visible and trading
- TC-C1, TC-C2: API key generation and auth must work end-to-end
- TC-D2, TC-D3: Tournament join flow must work from the frontend
- TC-E1: vs OpenClaw comparison is a core Phase 2 feature
- TC-F1, TC-F2: Phase 1 trading must not regress

**Nice-to-have (log and fix in follow-up sprint if failing):**
- TC-A6, TC-A7: Edge-case guards — unlikely to affect normal usage
- TC-B3, TC-B4, TC-B5: Advanced agent behaviours — agent still trades without these
- TC-E4, TC-E5, TC-E6: Sharing fallbacks — TG path works, fallbacks are secondary
- TC-D10: Auto-activation — can be triggered manually if cron is late

> **Deploy standard**: All Blocking TCs must pass. Fewer than 3 Important TCs may remain as known issues with filed tickets. No go if TC-F6 fails for any reason.
