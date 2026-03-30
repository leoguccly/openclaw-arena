# Phase 3 Code Review — OpenClaw Arena

**Reviewer**: Tech Lead
**Date**: 2026-03-29
**Scope**: Migrations 008–011, Edge Functions (claim-daily-reward, get-trade-history, get-achievements, check-achievements, send-notifications, _shared/telegram-notify), Frontend (StreakWidget, HistoryPage, AchievementsPage, app/page.tsx)

---

## Overall Grades

| Category | Grade | Summary |
|---|---|---|
| Code Quality | 🟢 | Consistently typed, well-structured, proper error handling throughout |
| Architecture Red Lines | 🟡 | RLS correct, SECURITY DEFINER correct — two gaps need fixing before prod |
| Security | 🟡 | No hardcoded secrets, good rate-limiting — two concrete issues |
| Race Conditions | 🟢 | Daily claim is iron-clad; achievement double-award is safe; one advisory |
| Data Flow | 🟢 | claim → balance → streak → achievement chain is coherent end-to-end |

**Final Verdict: REQUEST CHANGES** — two blockers must be resolved before merging to main.

---

## Migrations

### 008_daily_rewards.sql — 🟢

Excellent. The `award_daily_reward_txn` function is the right place for this logic.

Strengths:
- `FOR UPDATE` on the user row correctly serialises concurrent claims for the same user. Double-tap from the same device cannot double-spend because the second call will either hit the `last_claim_date` guard after the first commit or find the `UNIQUE` constraint on `daily_claims` and `DO NOTHING`.
- `SECURITY DEFINER` + `SET search_path = public` is correctly applied. `REVOKE EXECUTE FROM PUBLIC / anon / authenticated` followed by `GRANT ... TO service_role` is the right pattern — no authenticated user can call this directly.
- Bonus schedule is deterministic and expressed in one readable `CASE` block.
- Streak reset logic (consecutive-day check) is correct.

Minor observation: The `new_balance` in the final `RETURN` is computed as `v_user.balance + v_bonus` (arithmetic on the pre-`UPDATE` snapshot). This is numerically correct because `balance` was captured under `FOR UPDATE` before any other write could happen, but it reads slightly misleadingly. A `RETURNING balance INTO ...` after the `UPDATE` would eliminate any future confusion. Not a blocker.

### 009_notifications.sql — 🟡 (one blocker)

**BLOCKER-1**: `streak_reminder_sent_today` is referenced in `send-notifications/index.ts` (both the `SELECT` query and the subsequent `UPDATE`), but this column is not added to `public.users` anywhere in this migration or any other visible migration. The function will fail at runtime with a column-not-found error for every streak reminder run. Either add the column in this migration or remove the feature from the edge function until it lands.

```sql
-- Missing from 009_notifications.sql:
ALTER TABLE public.users
  ADD COLUMN streak_reminder_sent_today BOOLEAN NOT NULL DEFAULT FALSE;
```

A nightly reset job (or a generated column comparing `last_claim_date` to `CURRENT_DATE`) would also need to zero this flag each UTC day. Without the reset mechanism the flag will permanently block reminders after the first send.

Everything else in this migration is clean. The three partial indexes on `notification_log` are well-designed. The `delivered = TRUE` partial index correctly excludes failed deliveries from rate-limit counts.

### 010_achievements.sql — 🟢

Clean. The three-table design (catalogue / earned / progress) is the right shape.

The `user_achievements` public-read policy (anon can see all earned rows) is intentional per the comment and acceptable for a public leaderboard product. The trade-off is documented in the migration header.

One note: the `get-achievements/index.ts` edge function queries the `achievements` table expecting a `code` column, but the migration defines the PK as `id` (e.g. `'ACH-001'`) with no separate `code` column. The function's type definition also declares both `id` and `code`. In practice `EVALUATORS` in `check-achievements` keys on `def.code`, but `achievements.code` does not exist in the schema — only `achievements.id`. This will cause the evaluator dispatch to never match anything at runtime.

**BLOCKER-2**: Either rename `id` to `code` in the seed (and use a surrogate PK), or add a `code TEXT NOT NULL UNIQUE` column to the `achievements` table and update the seed. The simpler fix is to add:

```sql
ALTER TABLE public.achievements ADD COLUMN code TEXT GENERATED ALWAYS AS (id) STORED;
```

...or simply accept that `id` is the stable code and update `check-achievements/index.ts` to use `def.id` everywhere instead of `def.code`.

### 011_trade_history.sql — 🟢

`security_barrier = true` on the view is correctly applied and the comment explains why. The composite index `(user_id, created_at DESC, status)` covers the three predicates the history query uses. The `closed_at` alias for `updated_at` is a sensible DX improvement.

---

## Edge Functions

### _shared/telegram-notify.ts — 🟡

The rate-limit implementation in `canSendNotification` has a **logic ordering issue**: Rule 3 (gap since last message) is evaluated first, then Rule 2 (daily cap), then Rule 1 (hourly cap). This is functionally correct but can silently pass through a burst: if a user has received 4 messages today, Rule 2 would catch the 5th, but Rule 3 is checked first using the most recent row. If the last message was >15 minutes ago but the daily cap is already exhausted, the function correctly returns `false` at Rule 2. So the ordering does not create a security gap — it is just an unusual evaluation order. No change required.

More important: the function logs a successful send and then attempts to write `notification_log`. The log row includes `chat_id` and `message` fields that are not present in the `notification_log` table schema (migration 009 defines only `user_id, notification_type, payload, sent_at, delivered`). The insert will either fail silently (the error is caught and logged but not fatal) or, if the schema was extended elsewhere, succeed. This means **rate-limit state is silently corrupted**: after every successful Telegram send, the log row is not written, so the in-DB rate limit counts never increment, and a user can receive unlimited messages until the Supabase function process restarts.

This is a severity-2 issue (not a blocker for the architecture, but a real operational defect). The fix is to align the insert payload with the actual schema:

```typescript
await supabase.from("notification_log").insert({
  user_id: userId,
  notification_type: notificationType,
  payload: { message: message.slice(0, 200), chat_id: chatId },  // store in JSONB payload
  sent_at: new Date().toISOString(),
  delivered: true,
});
```

### claim-daily-reward/index.ts — 🟢

The chain is correct: authenticate → rate-limit burst guard → verify is_human → call RPC. The `is_human` check at the edge function level is redundant given the same check exists in the RPC, but redundancy here is a feature, not a smell — it avoids a wasted DB round-trip for bot accounts.

The in-memory `checkRateLimit` (from `rate-limiter.ts`) is appropriate as a burst guard layered on top of the DB-level idempotency. The two layers are complementary: the in-memory limiter blocks rapid double-taps at the network edge; the `FOR UPDATE` + `UNIQUE` constraint in the RPC handles concurrent calls that evade the edge check (different isolates, or after a cold start).

### get-trade-history/index.ts — 🟢

Cursor-based pagination is correct. The `parseParams` validation with allowlists for `symbol` and `status` is good practice. The `fetchAggregateStatsDirect` fallback that loads all closed trades into memory has an appropriate `NOTE` warning and should be treated as a temporary measure.

Minor: the function is invoked with `body: { stats_only: true }` from `HistoryPage` for the stats-only call, but the edge function does not handle a `stats_only` flag — it always runs the full trade page query. This means the stats-only call also runs the trade page query and returns an unused page of trades. Not a correctness issue; the frontend simply discards `res.data.trades`. But it wastes a DB query on every stats refresh. Addressable in a follow-up.

### get-achievements/index.ts — 🟡

This function expects an `achievements` row to have both `id` and `code` fields (the `AchievementDefinition` interface declares both). The migration only has `id`. This is the same schema mismatch as BLOCKER-2 above — fixing the migration fixes this function too.

The categorisation logic (`categorise` in both the backend function and the frontend page) is duplicated. The backend already returns `{ earned, in_progress, locked }` but the frontend calls `supabase.functions.invoke("get-achievements")` and then pulls `res.data?.achievements` — a flat array. These are mismatched: the edge function returns `{ success, data: { earned, in_progress, locked } }` but the page reads `res.data?.achievements`. The page will always get an empty array and show the empty state regardless of what the user has earned. This is a **data-shape mismatch bug**.

Fix in `achievements/page.tsx`:

```typescript
// current (wrong):
const data = (res.data?.achievements ?? []) as Achievement[];

// correct:
const earned     = (res.data?.data?.earned     ?? []) as Achievement[];
const inProgress = (res.data?.data?.in_progress ?? []) as Achievement[];
const locked     = (res.data?.data?.locked      ?? []) as Achievement[];
// then merge or pass separately
```

Or simpler: call the get-achievements function and pass the structured response directly to the page without re-running `categorise` on the frontend.

### check-achievements/index.ts — 🟡

The service-role gate checks `req.headers.get("apikey")` against `SUPABASE_SERVICE_ROLE_KEY`. This is a reasonable internal guard but it means the function must be invoked with the raw service-role key in a header. Any internal caller (e.g., a webhook trigger or another edge function) must handle this correctly. The approach is acceptable for an internal-only function, but document the calling convention in the function header to prevent future callers from bypassing it accidentally.

The `upsertProgress` function has a **read-then-write race**: it fetches the current count, adds the increment in TypeScript, and then upserts. Two concurrent calls for the same `(user_id, achievement_id)` can both read count=2, both compute count=3, and both upsert count=3 — effectively losing one increment. For ACH-001 (Claw Crusher, requires 3 beats), this means the counter could report 3 wins when only 2 actually occurred, or it could silently undercount.

The correct fix is a single SQL `UPDATE ... SET current_count = current_count + $increment WHERE ...` executed via an RPC, which Postgres executes atomically under a row-lock. The current approach is fine for low-frequency events in a small-scale app but is a latent correctness bug under concurrent load.

### send-notifications/index.ts — 🟡

Three issues:

1. **`rivalry_alert` vs `rivalry`**: The function calls `sendTelegramNotification(..., "rivalry_alert", ...)` but the `notification_log.notification_type` CHECK constraint in migration 009 only allows `'rivalry'` (not `'rivalry_alert'`). The insert will fail the constraint check and the log row will not be written, breaking rate-limiting for rivalry notifications.

2. **No service-role gate on the cron endpoint**: The function accepts both `POST` and `GET` with no authentication check whatsoever. Any unauthenticated caller who knows the function URL can trigger all three notification jobs. At minimum add a `Authorization: Bearer <cron-secret>` check or restrict via Supabase dashboard to internal-only invocations.

3. **Sequential job execution**: The three jobs run sequentially (`await runTournamentReminders` then `await runStreakReminders` then `await runRivalryAlerts`). For a cron function with a 10-second wall-clock budget, this is fine today. If notification volumes grow, wrap them in `Promise.allSettled` to run in parallel. Advisory only.

---

## Frontend

### lib/types.ts — 🟡

`AggregateStats` declares `cumulative_pnl: number | null` and `best_trade_pnl / worst_trade_pnl`, but `get-trade-history/index.ts` returns `TradeStats` which uses `cumulative_pnl: number` (not nullable) and `best_trade / worst_trade` (no `_pnl` suffix). The field names do not align:

| types.ts | edge function TradeStats |
|---|---|
| `cumulative_pnl` | `cumulative_pnl` (matches) |
| `best_trade_pnl` | `best_trade` (mismatch) |
| `worst_trade_pnl` | `worst_trade` (mismatch) |

The `StatsBar` in `history/page.tsx` reads `stats.best_trade_pnl` and `stats.worst_trade_pnl`, which will be `undefined` from the actual response. The stats panel will always show `—` for Best and Worst trade even when data is available.

Also `ArenaUser` is missing the new Phase 3 columns: `current_streak`, `last_claim_date`, `tg_chat_id`, `notifications_enabled`. These do not need to be on the frontend type if they are not consumed by the client, but if any future component reads them directly from a `users` query, the type will be wrong.

`Achievement` mixes the DB catalogue fields with user-specific fields (`earned_at`, `current_count`). This works for the flat-list approach but creates a nullable field smell. Consider splitting into `AchievementDefinition` and `UserAchievement extends AchievementDefinition` for better clarity. Advisory only.

### components/StreakWidget.tsx — 🟡

**Bonus schedule mismatch**: `getStreakBonus` in the widget defines tiers at 3/7/14/30 days returning 100/350/500/700/1000. The database RPC `award_daily_reward_txn` defines tiers at 1/2/3/4/5/6/7+ days returning 100/150/200/250/350/500/750. These are completely different schedules. The widget will display incorrect "Tomorrow: +X USDT" values for users on streaks 3–6.

This is a UX correctness bug: the user is promised one bonus amount by the UI and receives a different amount. Fix: either centralise the schedule in a shared constant (ideally fetched from the DB or derived from the API response), or align the frontend table to exactly match the RPC table.

The widget fires the claim function on every mount (every page load). The RPC handles idempotency correctly so there is no financial risk, but it means every home-page load generates a DB round-trip and a rate-limiter check. This is acceptable given the DB-level `already_claimed` fast-path. Not a blocker.

The `bonusTimerRef` cleanup in `useEffect` return is correctly implemented.

### app/history/page.tsx — 🟢

Cursor-based pagination with `IntersectionObserver` is the right pattern. Filter change correctly resets cursor and trade list. The `useCallback` dependency array `[statusFilter, symbolFilter]` is correct. Error states and loading skeletons are handled.

The stats-only invocation issue noted in the edge function section also appears here: `body: { stats_only: true }` is sent but the function ignores it. Not a correctness bug, just an unused optimisation path.

`fmtPnl` is defined inline in both `history/page.tsx` and `app/page.tsx`. Move to a shared `lib/format.ts` utility. Advisory.

### app/achievements/page.tsx — 🟡

The `data-shape mismatch bug` noted under `get-achievements/index.ts` originates here. The page reads `res.data?.achievements` as a flat array but the edge function returns `res.data.data.earned / in_progress / locked`. This is the root cause.

The client-side `categorise` function duplicates the server-side categorisation logic. If the edge function is fixed to return the already-categorised shape, the local `categorise` function should be removed.

`fmtDate` is defined in both `history/page.tsx` and `achievements/page.tsx`. Move to `lib/format.ts`.

### app/page.tsx — 🟢

The main trading page is not in scope for Phase 3 logic changes, only for integration of `StreakWidget` and nav links. Both are correctly wired. `StreakWidget` is rendered in the right position. The Achievements and History nav links are present.

The `loadUserData` effect does `supabase.from("users").select("balance, roi").single()` without a `.eq("id", ...)` filter. This relies on the Supabase client's session context implicitly filtering via RLS — which is correct, but it is fragile and non-obvious. Adding `.eq("id", user.id)` after fetching the session would make the intent explicit. Advisory.

---

## Data Flow — Daily Claim Chain

```
StreakWidget (mount)
  → supabase.functions.invoke("claim-daily-reward")
    → getUserFromAuth (auth gate)
    → checkRateLimit (burst guard)
    → users.is_human check
    → award_daily_reward_txn RPC
        → FOR UPDATE on users
        → idempotency check (last_claim_date)
        → streak calculation
        → balance UPDATE
        → daily_claims INSERT ON CONFLICT DO NOTHING
        → RETURN { already_claimed, streak, bonus_amount, new_balance }
    → HTTP 200 { success, data }
  → StreakWidget renders streak + balance
  → [claim-daily-reward should call check-achievements trigger="streak_claimed"]  ← MISSING LINK
```

The chain is missing the final step: after a successful non-`already_claimed` claim, `claim-daily-reward` should invoke `check-achievements` with `trigger_event: "streak_claimed"` and `event_data: { streak: result.streak }` to evaluate ACH-005 (Streak Keeper). As written, ACH-005 will never be awarded. This is an integration gap, not a code bug in any individual file — but it must be wired before launch.

---

## Blockers (Must Fix Before Merge)

### BLOCKER-1: Missing `streak_reminder_sent_today` column

**File**: `/supabase/migrations/009_notifications.sql`

`send-notifications/index.ts` queries and updates `users.streak_reminder_sent_today` but the column is never created. The migration must add it, along with a mechanism to reset it daily (a scheduled job or a generated/computed expression against `last_claim_date`).

### BLOCKER-2: `achievements.code` column does not exist

**Files**: `/supabase/migrations/010_achievements.sql`, `/supabase/functions/check-achievements/index.ts`, `/supabase/functions/get-achievements/index.ts`

Both edge functions reference `def.code` / `achievement.code` but the schema only has `id`. The evaluator dispatch table in `check-achievements` keys on `def.code` — meaning no achievement evaluator will ever match, and no achievements will ever be awarded. Either add a `code` column to the migration or update both functions to use `def.id`.

---

## Severity-2 Issues (Should Fix Before Launch)

### S2-1: `notification_log` insert schema mismatch in telegram-notify.ts

**File**: `/supabase/functions/_shared/telegram-notify.ts` (line 185)

The insert includes `chat_id` and `message` fields that do not exist in the `notification_log` table. The insert fails silently on every send, so rate-limit state is never persisted to the DB, making rate-limiting effectively non-functional at scale (in-memory state only, resets on cold start).

### S2-2: Achievements page reads wrong response key

**File**: `/app/achievements/page.tsx` (line 182)

`res.data?.achievements` should be `res.data?.data?.earned` / `in_progress` / `locked`. As written, the achievements page will always be empty regardless of what the user has earned.

### S2-3: Streak bonus schedule mismatch

**File**: `/components/StreakWidget.tsx` (lines 15–20)

Frontend `getStreakBonus` tiers do not match the database RPC bonus schedule. Users will see incorrect "tomorrow's bonus" previews.

### S2-4: `rivalry_alert` notification type not in CHECK constraint

**File**: `/supabase/functions/send-notifications/index.ts` (line 357)

`notificationType` passed as `"rivalry_alert"` violates the `notification_log.notification_type` CHECK constraint which only allows `"rivalry"`. Fix by changing the call to `"rivalry"`.

### S2-5: `check-achievements` never triggered after daily claim

Integration gap: `claim-daily-reward` does not call `check-achievements` after a successful claim, so ACH-005 (Streak Keeper) is never evaluated.

### S2-6: No authentication on `send-notifications` cron endpoint

**File**: `/supabase/functions/send-notifications/index.ts` (line 399)

The function accepts any unauthenticated POST/GET. Add a shared cron secret check.

---

## Minor / Advisory

- **S3-1**: `get-trade-history` does not handle `stats_only: true` body param; frontend sends it but function ignores it, running a redundant trade-list query on every stats refresh.
- **S3-2**: `fmtDate`, `fmtPnl`, `fmtPrice` are defined in multiple files. Extract to `lib/format.ts`.
- **S3-3**: `upsertProgress` in `check-achievements` has a read-then-write race for concurrent achievement increments. Replace with a single-statement SQL increment via an RPC for correctness under concurrency.
- **S3-4**: `AggregateStats` type field names (`best_trade_pnl`, `worst_trade_pnl`) do not match the edge function response field names (`best_trade`, `worst_trade`). StatsBar always shows `—` for these two metrics.
- **S3-5**: `award_daily_reward_txn` computes `new_balance` from the pre-UPDATE snapshot variable rather than from a `RETURNING` clause. Functionally correct but fragile to future edits.
- **S3-6**: `app/page.tsx` `loadUserData` calls `.single()` without an explicit `user_id` filter; relies implicitly on RLS. Add `.eq("id", userId)` for clarity.

---

## Summary Table

| ID | Severity | File | Issue |
|---|---|---|---|
| BLOCKER-1 | Blocker | 009_notifications.sql | `streak_reminder_sent_today` column missing |
| BLOCKER-2 | Blocker | 010_achievements.sql + check/get-achievements | `achievements.code` column missing; no achievements can ever be awarded |
| S2-1 | High | _shared/telegram-notify.ts | notification_log insert fails silently; rate-limiting non-functional |
| S2-2 | High | app/achievements/page.tsx | Wrong response key; page always shows empty state |
| S2-3 | High | components/StreakWidget.tsx | Bonus schedule mismatch with DB RPC |
| S2-4 | High | send-notifications/index.ts | `rivalry_alert` violates notification_type CHECK constraint |
| S2-5 | High | claim-daily-reward + check-achievements | ACH-005 (Streak Keeper) never triggered |
| S2-6 | Medium | send-notifications/index.ts | No auth on cron endpoint |
| S3-1 | Low | get-trade-history + history/page.tsx | stats_only flag ignored |
| S3-2 | Low | history/page.tsx + achievements/page.tsx | Duplicated format helpers |
| S3-3 | Low | check-achievements/index.ts | read-then-write race in upsertProgress |
| S3-4 | Low | lib/types.ts | AggregateStats field name mismatch |
| S3-5 | Low | 008_daily_rewards.sql | new_balance from snapshot, not RETURNING |
| S3-6 | Low | app/page.tsx | loadUserData missing explicit user_id filter |

---

## Final Verdict

**REQUEST CHANGES**

The migration and edge function work is architecturally sound — RLS is on every table, SECURITY DEFINER RPCs are locked to service_role, financial operations are atomic, idempotency is double-guarded. The engineering discipline is good and the code is readable.

However, two blockers prevent merging:

1. A missing DB column (`streak_reminder_sent_today`) will crash the streak reminder job immediately on first cron run.
2. A missing `code` column / column name mismatch on `achievements` means zero achievements can ever be awarded or displayed — the entire gamification system is silently broken.

Additionally, five severity-2 issues (rate-limit state never persisted, achievements page always empty, bonus schedule mismatch, wrong notification type string, and Streak Keeper never triggered) collectively mean the three headline Phase 3 features — daily rewards, achievements, and notifications — do not work end-to-end even after the blockers are resolved.

Fix the two blockers and the five S2 issues, then re-submit. The advisory items can be batched into a follow-up.
