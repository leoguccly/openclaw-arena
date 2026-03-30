# Phase 4 Code Review — Tech Lead Sign-Off

> Reviewer: Tech Lead
> Date: 2026-03-29
> Phase: Phase 4 (Referral System, AI Personalities, Price Alerts)
> Files Reviewed: 14 (3 migrations, 6 edge functions, 5 frontend files)

---

## Executive Summary

Phase 4 is **APPROVED WITH CONDITIONS**. The overall quality is high — the referral
RPC is the best-designed piece in the entire codebase to date, the price-alert race
condition is properly handled with an optimistic lock, and the AI personality agents
are clean, well-parameterised, and correctly isolated. There are no critical security
blockers and no lock-ordering violations.

Two issues must be fixed before merge. Five advisory items should be addressed in
follow-up tickets.

**Verdict: CONDITIONAL APPROVE — fix the two BLOCKER items below, then merge.**

---

## Blocker Items (must fix before merge)

### BLOCKER-1 — Schema Mismatch: `referral_events` columns vs Edge Function queries

**Severity: BLOCKER**
**Files:** `015_referral_system.sql`, `get-referral/index.ts`

The `referral_events` table created in migration 015 has these columns:

```
id, referrer_id, referee_id, referrer_bonus, referee_bonus, bonus_paid_at
```

The `get-referral` Edge Function queries the table with:

```typescript
.select("id, referee_id, status, bonus_amount, created_at, referee:users!...")
.eq("referrer_id", user.id)
```

It references `status`, `bonus_amount`, and `created_at` — none of which exist on
the table. The table has `referrer_bonus`, `referee_bonus`, and `bonus_paid_at`, but
no `status` column and no `bonus_amount` column.

Additionally, the `ReferralReferee` type in `lib/types.ts` exposes `bonus_paid_at`
and `username`, but `ReferralEventRow` in the edge function references `status` and
`bonus_amount`. This means:

1. The JOIN alias `referee:users!referral_events_referee_id_fkey(display_name)` does
   not select `username`, yet `ReferralReferee` in types.ts declares a `username`
   field that is rendered in `RefereeRow`.
2. The `totalBonusEarned` filter on `status === "confirmed"` will always produce 0
   because no rows will ever have a `status` field — it will be `undefined` for every
   row, meaning confirmed bonuses are never counted correctly.
3. The referral page will silently show $0.00 bonus earned for every user even when
   bonuses have been paid.

**Fix required:**

Align the select query to the actual schema. Replace:

```typescript
.select("id, referee_id, status, bonus_amount, created_at, referee:users!referral_events_referee_id_fkey(display_name)")
```

with:

```typescript
.select("id, referee_id, referrer_bonus, bonus_paid_at, referee:users!referral_events_referee_id_fkey(display_name, username)")
```

Update `ReferralEventRow` to match, drop the `status` field (all rows in the table
are by definition paid/confirmed — there is no pending state in the schema), update
the `totalBonusEarned` computation to use `referrer_bonus` rather than filtering on
`status`, and update `ReferralReferee` in `lib/types.ts` to use `bonus_paid_at`
(already present in the type) with `joined_at` mapped from `bonus_paid_at`.

Also update the `register-referral` function: it writes `referral_code_used` on the
`users` table (line 191), but migration 015 does not add that column. Either add the
column in 015 or remove that field from the UPDATE. Given it has audit value, add it:

```sql
ALTER TABLE public.users ADD COLUMN referral_code_used TEXT;
```

---

### BLOCKER-2 — `manage-price-alerts` DELETE uses soft-delete but RLS only grants physical DELETE

**Severity: BLOCKER**
**Files:** `017_price_alerts.sql`, `manage-price-alerts/index.ts`

Migration 017 grants users this RLS permission:

```sql
CREATE POLICY "price_alerts: owner can delete"
  ON public.price_alerts FOR DELETE ...
```

No UPDATE policy is granted to `authenticated` users. However, the `handleDelete`
handler in the Edge Function performs a soft-delete via `UPDATE`:

```typescript
await supabase
  .from("price_alerts")
  .update({ is_active: false })
  .eq("id", alertId)
  .eq("user_id", userId)
  .eq("is_active", true)
```

The Edge Function uses `getSupabaseAdmin()` (service_role), so the UPDATE itself
succeeds at the database level — service_role bypasses RLS. This is actually the
correct runtime behavior.

However, the mismatch is a semantic problem: the RLS documentation comment in 017
says "deletion is the canonical way to cancel" and deliberately withholds UPDATE from
authenticated users, yet the Edge Function uses UPDATE (soft-delete) rather than
DELETE. The RLS design and the implementation disagree on the cancellation mechanism.

This matters for two reasons:

1. If a future developer grants the authenticated UPDATE policy (perhaps for a
   different field), they will inadvertently allow clients to re-arm triggered alerts
   by setting `is_active = true` — the exact attack the RLS comment says the
   no-UPDATE policy prevents.
2. The soft-delete approach preserves history (good), but the migration comment
   claims physical DELETE is the canonical cancel. The discrepancy will cause
   confusion in future migrations.

**Fix required:** Pick one approach and make the code and migration consistent.

Option A (recommended — keep soft-delete, update the migration):

Remove the "owner can delete" policy from 017. Add an "owner can update is_active
only" policy scoped to `is_active = FALSE` transitions (preventing clients from
re-arming). Add a comment explaining that soft-delete is the mechanism and service
role handles the scanner's triggered_at flip.

Option B (change to physical delete in the Edge Function):

Replace the UPDATE in `handleDelete` with a physical DELETE using the service role
client. Retain the "owner can delete" RLS policy as written. Add `is_active = true`
to the WHERE clause to prevent deleting already-triggered history.

Either option resolves the inconsistency. Option A preserves history, which is
preferable for audit purposes.

---

## Issues (should fix — not blocking merge after BLOCKER review)

### ISSUE-1 — `register-referral` sends the full `start_param` value as `referral_code`

**Severity: Medium**
**Files:** `app/page.tsx` (line 63), `register-referral/index.ts`

The home page extracts `start_param` from `initDataUnsafe` and passes it directly
as the `referral_code` to the edge function:

```typescript
const startParam: string | undefined =
  window.Telegram?.WebApp?.initDataUnsafe?.start_param;
if (startParam && startParam.startsWith("ref_")) {
  supabase.functions.invoke("register-referral", {
    body: { referral_code: startParam },
  })
```

The edge function trims and uppercases the code and looks it up in the database.
Codes are generated as 8-character alphanumeric strings (e.g., `AB3K7XYZ`). If the
sharing link places a `ref_` prefix in front of the code (the `referral_link` is
`https://openclaw.arena/join?ref=AB3K7XYZ` — note no `ref_` prefix in the query
string), the `start_param` convention with the `ref_` prefix means the edge function
receives `ref_AB3K7XYZ` but looks up only `AB3K7XYZ` in the database. The 32-char
max will accept the prefixed value but the lookup will fail silently.

Verify what `start_param` looks like when a user opens the Telegram Mini App via
the referral link and strip the `ref_` prefix before sending to the edge function,
or store codes with the prefix in the database.

### ISSUE-2 — Race condition: 5-alert cap is not atomic

**Severity: Medium**
**Files:** `manage-price-alerts/index.ts` (lines 329–353)

The count check and INSERT are two separate round-trips:

```typescript
// Round-trip 1
const { count } = await supabase.from("price_alerts")
  .select("id", { count: "exact", head: true })
  .eq("user_id", userId).eq("is_active", true);

if ((count ?? 0) >= MAX_ACTIVE_ALERTS) { return 422; }

// Round-trip 2
await supabase.from("price_alerts").insert({ ... });
```

A user who fires two concurrent POST requests can race past the count check and
create 6 or more active alerts. The comment in 017 acknowledges this and notes that
a CHECK constraint is avoided for index-efficiency reasons. The recommended mitigation
is a database-level partial unique index that counts active rows per user, or moving
the count-then-insert into a SECURITY DEFINER RPC that holds a row-level advisory
lock on the user's ID for the duration.

At 5 alerts per user the practical exploit risk is low, but it is a real race
condition. File a ticket to address it before the user base grows.

### ISSUE-3 — `openclaw-chaos` stop-loss is 10x the platform maximum for bots

**Severity: Low / Design**
**Files:** `openclaw-chaos/index.ts` (line 47)

`TRAILING_STOP_LOSS_FRACTION = 0.10` (10%) means Chaos can lose 10% of its margin
before stopping. With `MAX_LEVERAGE = 50`, the notional exposure is 50x margin, so a
2% adverse move wipes the margin entirely before the stop triggers. The liquidation
RPC (`liquidate_trade_txn`) will trigger at the `liquidation_price` computed when
the trade is opened (which for a 50x trade is only 2% away from entry), so in
practice the database-level liquidation will fire long before the application-level
10% stop-loss. The stop-loss in the agent is therefore largely decorative at high
leverage, which is fine for Chaos by design — document this explicitly in the
constant comment to avoid a future developer "fixing" it by lowering it.

### ISSUE-4 — `get-referral` code-generation loop has an unreachable retry path

**Severity: Low**
**Files:** `get-referral/index.ts` (lines 156–218)

The inner `while` loop retries up to 5 times on `23505` (unique constraint
violation). However, the UPDATE uses `.is("referral_code", null)` as an idempotency
guard: if another concurrent request won the race and set the code, the UPDATE
affects 0 rows and returns no error (not 23505). The `updateError` will be `null`
but `generated` will remain `false` because `referralCode` was not assigned. The
loop then exhausts all 5 attempts unnecessarily before falling through to the
re-fetch. The real race path is the re-fetch fallback (lines 196–218), which is
correct. The retry loop only helps with genuine 32-symbol alphabet collisions (a
1-in-10^12 event). The code is logically correct but the comment "Retry up to 5
times on the unlikely event of a collision" is misleading — the 0-rows case is not a
collision. Add a check for the 0-rows outcome and go directly to the re-fetch.

### ISSUE-5 — `alerts/page.tsx` DELETE passes alert ID in body, not URL path

**Severity: Low**
**Files:** `app/alerts/page.tsx` (line 262), `manage-price-alerts/index.ts`
(lines 401–406)

The page sends DELETE with:

```typescript
supabase.functions.invoke("manage-price-alerts", {
  body: { alert_id: id },
  method: "DELETE",
})
```

The Edge Function extracts the alert ID from the URL path:

```typescript
const pathParts = url.pathname.split("/").filter(Boolean);
const alertId = pathParts[pathParts.length - 1];
```

The Supabase `functions.invoke` call does not append the `alert_id` to the URL path;
it puts it in the request body. The path will be `/manage-price-alerts` with no
additional segment, so `alertId` will equal `"manage-price-alerts"` and the handler
will return 400 `"Alert ID is required in the URL path"`.

Since Supabase Edge Functions do not easily support parameterised routes, fix this
by reading the alert ID from the request body in the DELETE handler (consistent with
how POST reads its body), not from the URL path. Update the edge function's
`handleDelete` to parse `req.json()` and extract `alert_id`, then validate and use
it as before.

---

## Architecture Red Lines — Compliance Checklist

| Red Line | Status | Notes |
|---|---|---|
| All user tables have RLS enabled | PASS | `referral_events` and `price_alerts` both have RLS |
| No UPDATE policy for triggered_at (price_alerts) | PASS | Authenticated users have no UPDATE — scanner uses service_role |
| SECURITY DEFINER RPCs revoke PUBLIC/anon/authenticated | PASS | `award_referral_bonus_txn` correctly revokes all three and grants service_role only |
| No secrets hard-coded in edge functions | PASS | All env access via `Deno.env.get()` |
| Lock ordering compliance — new RPCs | PASS | `award_referral_bonus_txn` acquires both users locks in UUID-ascending order, properly documented |
| Lock ordering compliance — price_alerts at position 4 | PASS | No existing RPC touches price_alerts; position 4 assignment is safe |
| Bot rows rejected by human-only guards | PASS | Migration 016 sets `is_human = FALSE` on both new agents; the RPC guard will reject them |
| anon has zero access to new tables | PASS | `REVOKE ALL ON ... FROM anon` present in both 015 and 017 |
| No SELECT * in migrations | PASS |  |
| Edge Functions authenticate before acting | PASS | All user-facing functions call `getUserFromAuth` before any DB operation |

---

## Security Analysis

### Referral Self-Referral Prevention

Multi-layer. The database RPC (`award_referral_bonus_txn`) checks
`p_referrer_id = p_referee_id` and raises an exception. The Edge Function
(`register-referral`) additionally checks `referrerData.id === user.id` before
calling the RPC. The idempotency guard on `referral_events.referee_id` (UNIQUE
constraint) prevents double-credit even if the code is bypassed. Defense in depth
is correct here.

### Price Alert Ownership

Ownership is enforced at three layers: RLS (INSERT `WITH CHECK (auth.uid() =
user_id)`, SELECT and DELETE scoped to `auth.uid() = user_id`), the Edge Function
explicitly filters by `userId` on every query, and the DELETE soft-update includes
`.eq("user_id", userId)` as a secondary guard. No path exists for user A to trigger,
view, or delete user B's alerts.

### Information Leakage — Referral Code Enumeration

`register-referral` returns `{ success: true }` for all outcomes (code not found,
self-referral, already-registered, DB error). This is correct — it prevents
enumeration of valid referral codes. The internal state (whether the code was valid,
whether the user was already referred) is logged server-side only.

### Double Price Alert Trigger

The optimistic lock in `checkPriceAlerts` — `.eq("is_active", true)` in the UPDATE
WHERE clause combined with `.maybeSingle()` check on the returned row — prevents
duplicate Telegram notifications from concurrent cron executions. If two
`scan-liquidations` instances run simultaneously (as can happen with Deno cold-starts
and scheduler over-trigger), only the instance whose UPDATE returns a row proceeds
to send the notification. The other instance sees `null` from `maybeSingle()` and
skips. This is a sound pattern.

### Referral Bonus Double-Pay

The UNIQUE constraint on `referral_events.referee_id` is the authoritative guard.
The RPC additionally holds FOR UPDATE locks on both user rows before checking
`referral_events`, so the existence check at step 5 is stable under concurrent
calls. `ON CONFLICT DO NOTHING` on the INSERT provides a third layer. The analysis
in the migration header correctly enumerates all concurrent scenarios. No double-pay
path exists.

---

## Race Condition Analysis

### Concurrent Referral Code Generation (get-referral)

Two concurrent requests for the same user both see `referral_code = null`, both
generate a code, and both attempt the UPDATE with `.is("referral_code", null)`. Only
one UPDATE wins (the unique index prevents both from succeeding). The loser gets 0
rows updated (no error), falls through the retry loop, and re-fetches the code set
by the winner. The re-fetch path at lines 196–218 handles this correctly. Verdict:
safe.

### Concurrent Referral Registration (register-referral)

Two concurrent requests from the same user both see `referred_by = null`, look up
the same referrer, and both attempt the UPDATE with `.is("referred_by", null)`. Only
one wins. The loser gets a 23505 or 0 rows and returns `{ success: true }`. Verdict:
safe.

### Concurrent alert deactivation (scan-liquidations + checkPriceAlerts)

Covered in the security section above. The optimistic `WHERE is_active = true` in
the UPDATE prevents double-notification. Verdict: safe.

### Concurrent alert creation (5-alert cap)

Two POST requests simultaneously pass the count check (both see count=4) and both
insert, resulting in 6 active alerts. This is the ISSUE-2 race described above.
Verdict: known gap, low severity at current scale.

### Code Generation Collision (referral codes)

Alphabet is 32 symbols, code length is 8. Keyspace is 32^8 = 1,099,511,627,776
(~10^12). At 1 million users the birthday-paradox collision probability per code
generation is ~0.09%. The retry loop (5 attempts) makes collision-induced failure
negligible. Verdict: safe.

---

## Lock Ordering Compliance

Canonical order as of Phase 4: `tournaments(1) → users(2) → trades(3) → price_alerts(4)`

| RPC | New in Phase 4? | Lock 1 | Lock 2 | Lock 3 | Compliant? |
|---|---|---|---|---|---|
| `award_referral_bonus_txn` | YES | users FOR UPDATE (lower UUID) | users FOR UPDATE (higher UUID) | — | PASS |
| `execute_trade_txn` | No | users FOR UPDATE | trades INSERT | — | PASS (unchanged) |
| `close_trade_txn` | No | users FOR UPDATE | trades FOR UPDATE | — | PASS (unchanged) |
| `liquidate_trade_txn` | No | users FOR UPDATE | trades FOR UPDATE | — | PASS (unchanged) |
| `join_tournament_txn` | No | tournaments FOR UPDATE | users FOR UPDATE | — | PASS (unchanged) |
| `settle_tournament_txn` | No | tournaments FOR UPDATE | — | — | PASS (unchanged) |
| `award_daily_reward_txn` | No | users FOR UPDATE | — | — | PASS (unchanged) |

No new RPCs touch `price_alerts` with a FOR UPDATE lock. The `checkPriceAlerts`
function performs an UPDATE on `price_alerts` rows, but it does not hold a users
lock during that UPDATE — so there is no lock-ordering concern. If a future RPC
needs to lock both users and price_alerts in the same transaction, it must acquire
users first (canonical position 2) then price_alerts (position 4). This is documented
in 017 and does not affect any current code.

The `award_referral_bonus_txn` intra-table deadlock analysis (two users rows from
the same table) is correct and complete. Locking the lower UUID first is the standard
mitigation and is properly implemented.

---

## Code Quality Ratings

| File | Quality | Notes |
|---|---|---|
| `015_referral_system.sql` | 🟢 | Exemplary. Atomic RPC, correct lock ordering, human-only guard, idempotency at two layers, outbox pattern, rollback section. Schema mismatch with edge function is a BLOCKER but the SQL itself is sound. |
| `016_ai_personalities.sql` | 🟢 | Clean seeding pattern, idempotent ON CONFLICT, sentinel tg_id convention well-documented. |
| `017_price_alerts.sql` | 🟡 | RLS design and implementation disagree on delete-vs-update (BLOCKER-2). Index strategy and table design are good. |
| `get-referral/index.ts` | 🔴 | Field name mismatches against the schema (BLOCKER-1) will produce silent incorrect results. Code generation logic is well-structured. |
| `register-referral/index.ts` | 🟢 | Correct silent-fail pattern, self-referral guard, already-referred guard, idempotency on the UPDATE. referral_code_used column missing from schema (BLOCKER-1 sub-item). |
| `openclaw-conservative/index.ts` | 🟢 | Mean reversion signal is clearly documented and correctly inverted from momentum. 3% stop-loss is appropriate. Good use of crypto.getRandomValues throughout. |
| `openclaw-chaos/index.ts` | 🟢 | Entertaining by design. Random parameters are all crypto-sourced. Stop-loss at 10% is functionally inert at high leverage (see ISSUE-3), but intentional. Multi-symbol support is clean. |
| `manage-price-alerts/index.ts` | 🟡 | DELETE path passes ID in body but edge function reads it from URL path (ISSUE-5, effectively a BLOCKER in production). Optimistic lock on trigger is correct. |
| `scan-liquidations/index.ts` (price alert integration) | 🟢 | Clean piggyback pattern. Only runs for non-skipped symbols. Errors from checkPriceAlerts do not abort the scan. |
| `lib/types.ts` | 🟡 | `ReferralReferee` shape (username, bonus_paid_at) does not match what get-referral returns (display_name only, status). Needs alignment after BLOCKER-1 fix. `PriceAlert` uses `direction` consistently with the DB schema. |
| `app/referral/page.tsx` | 🟢 | Clean component decomposition. Correct use of useCallback for fetchReferralInfo. TG share URL is properly encoded. Key-by-index on referee list is acceptable given no stable identifier is exposed. |
| `app/alerts/page.tsx` | 🔴 | DELETE invocation passes ID in body; Edge Function reads from URL path — alerts cannot be deleted (ISSUE-5). GET response shape mismatch (response is `{ alerts: [...] }` but page does `Array.isArray(data)` check on the unwrapped object). |
| `components/OpenClawWidget.tsx` | 🟢 | Good fallback to single-agent layout. agentEmoji heuristic is transparent and extensible. 30s polling interval is appropriate. |
| `app/page.tsx` (referral registration) | 🟡 | ISSUE-1: `start_param` with `ref_` prefix sent verbatim to register-referral, likely causing silent registration failure. |

---

## Summary of Required Actions

### Before Merge (Blockers)

1. **BLOCKER-1**: Fix the schema mismatch between `referral_events` columns and the
   `get-referral` query. Add `referral_code_used TEXT` column to `users` table (via
   a patch to 015 or a new migration if 015 is already applied to staging). Update
   `ReferralEventRow` interface, the `.select()` call, and `totalBonusEarned`
   computation. Update `ReferralReferee` in types.ts to match.

2. **BLOCKER-2**: Resolve the RLS DELETE vs soft-delete inconsistency. Recommend
   Option A: remove the owner DELETE policy, add a constrained owner UPDATE policy
   for `is_active = false` transitions only, update migration comments. Alternatively
   change the Edge Function to use physical DELETE (Option B).

3. **ISSUE-5** (effectively a blocker for alert deletion UX): Fix the DELETE
   invocation in `alerts/page.tsx` to pass the alert ID in a way the Edge Function
   can read it — either move ID extraction to `req.json()` in the Edge Function, or
   append the ID to the function invocation path. Also fix the GET response shape
   assumption (`res.data` is `{ alerts: [...] }`, not a plain array).

### After Merge (Follow-up Tickets)

4. **ISSUE-1**: Investigate `start_param` format in Telegram Mini App deep links and
   strip the `ref_` prefix before passing to `register-referral`, or store codes
   with the prefix.

5. **ISSUE-2**: Address the 5-alert cap race condition with an advisory lock or
   database-level enforcement before user base exceeds ~10k active users.

6. **ISSUE-3**: Add a documentation comment to `TRAILING_STOP_LOSS_FRACTION` in
   `openclaw-chaos` explaining that it is decorative at high leverage by design.

7. **ISSUE-4**: Simplify the referral code generation retry logic to detect the
   0-rows-updated concurrent-write case and go directly to the re-fetch, avoiding
   unnecessary retries.
