# Phase 2 Code Review — OpenClaw Arena

> Reviewer: Tech Lead (Linus-style)
> Date: 2026-03-29
> Scope: Migrations 003–006, Edge Functions (scan-liquidations, openclaw-trade, join-tournament, settle-tournament, generate-api-key, _shared/), Frontend (lib/types.ts, OpenClawWidget, CyberPoster, page.tsx, tournaments/page.tsx)

---

## Overall Grades

| Category | Grade | Summary |
|---|---|---|
| Code Quality | 🟢 | Strong typing throughout, consistent style, no `any` except one justified escape hatch |
| Architecture Red Lines | 🟢 | All red lines respected — RLS, SECURITY DEFINER, REVOKE, server-side price |
| Security | 🟡 | Mostly excellent. Two issues: timing-safe comparison missing, x-user-id fallback trust model needs hardening |
| Race Condition Analysis | 🟢 | FOR UPDATE on every financial path, idempotency guards present and correct |
| Data Flow Verification | 🟡 | Liquidation and AI agent flows are correct. Tournament settle has one schema mismatch bug and one atomicity gap |

---

## Architecture Diagram Verification

```
Liquidation flow (verified correct):
  scan-liquidations (cron POST)
    → SELECT open trades
    → getServerSidePrice (Binance, with staleness guard 10s)
    → isBreached() per trade
    → liquidate_trade_txn RPC (atomic: FOR UPDATE → idempotency → UPDATE trades → FOR UPDATE users → UPDATE roi → INSERT liquidation_events)
    → LiquidationOutcome[] returned

AI agent flow (verified correct):
  openclaw-trade (cron POST)
    → SELECT balance + open BTC/USDT trade (parallel)
    → getServerSidePrice
    → fetchKlines → computeSignal (SMA-12)
    → stop-loss? → closeTradeViaRpc (close_trade_txn)
    → signal flip? → closeTradeViaRpc + refresh balance + openTradeViaRpc (execute_trade_txn)
    → same direction? → hold

Tournament flow (mostly correct, see BUG-001):
  settle-tournament (cron GET/POST)
    → SELECT active WHERE end_at <= now
    → forceCloseTrades → close_trade_txn per trade (per-symbol price cache)
    → settle_tournament_txn RPC (FOR UPDATE → 'settling' guard → UPDATE final_roi → RANK() → 'completed')
    → activateUpcomingTournaments (status guard on UPDATE)

Join flow (verified correct):
  join-tournament (POST, user-authenticated)
    → getUserFromAuth (JWT-first)
    → checkRateLimit
    → UUID validation
    → join_tournament_txn RPC (FOR UPDATE tournament → capacity check → FOR UPDATE user → balance check → INSERT)
```

---

## Issues Found

### BLOCKER

---

#### BUG-001: `settle-tournament` `Tournament` interface declares `symbol` field that does not exist on the DB table

**File:** `/supabase/functions/settle-tournament/index.ts` line 16
**Migration:** `005_tournaments.sql` — `tournaments` table has no `symbol` column

```typescript
// index.ts — declared but DB has no such column
interface Tournament {
  id: string;
  status: "upcoming" | "active" | "settled";  // also see BUG-002
  start_at: string;
  end_at: string;
  symbol: string;  // ← THIS COLUMN DOES NOT EXIST IN 005_tournaments.sql
}
```

At runtime `supabase.from("tournaments").select("id, status, start_at, end_at, symbol")` will return an error or silently omit the field depending on PostgREST version. The field is never accessed as `tournament.symbol` (it's accessed as `trade.symbol`), so it is currently a dead field, but the SELECT query will fail on a strict PostgREST config or return a schema-mismatch warning.

**Fix:** Remove `symbol` from the `Tournament` interface and from the `.select()` call on lines 299 and 225.

```typescript
// Correct interface
interface Tournament {
  id: string;
  status: "upcoming" | "active" | "settling" | "completed";
  start_at: string;
  end_at: string;
}

// Correct select
.select("id, status, start_at, end_at")
```

---

#### BUG-002: `settle-tournament` `Tournament.status` type is stale — missing `"settling"` and `"completed"`, uses non-existent `"settled"`

**File:** `/supabase/functions/settle-tournament/index.ts` line 13

```typescript
status: "upcoming" | "active" | "settled";  // ← wrong
```

The DB enum is `upcoming | active | settling | completed`. The string `"settled"` does not exist. This means the TypeScript type is lying. Any code that pattern-matches on this type is silently incorrect. The `activateUpcomingTournaments` function also sends `{ status: "active" }` via a direct `.update()` call (line 247) — this bypasses RLS correctly since it uses `getSupabaseAdmin()`, but the type mismatch means the compiler cannot catch future bugs.

**Fix:**

```typescript
status: "upcoming" | "active" | "settling" | "completed";
```

This type should be sourced from `lib/types.ts` which already has the correct union. Create a shared type import or duplicate it correctly.

---

### SUGGESTION

---

#### ISSUE-001: `generate-api-key` uses string equality for secret comparison — not timing-safe

**File:** `/supabase/functions/generate-api-key/index.ts` lines 53–73

```typescript
return provided === internalSecret;
```

The comment acknowledges this is not constant-time and argues the endpoint is "internal enough." This reasoning is acceptable for an MVP but should be tracked for production hardening. Deno's `crypto.subtle.timingSafeEqual` does not exist, but a manual byte-by-byte comparison via `TextEncoder` can be used.

**Recommendation:** Implement a HMAC-based check or at minimum add a GitHub issue to track this for pre-production. The current code is not a critical vulnerability given the endpoint is not publicly advertised, but it is technically exploitable via timing side-channel from within the same datacenter.

```typescript
// Safer alternative (still not perfect but meaningfully better)
function timingSafeEqual(a: string, b: string): boolean {
  const aBytes = new TextEncoder().encode(a);
  const bBytes = new TextEncoder().encode(b);
  if (aBytes.length !== bBytes.length) return false;
  let diff = 0;
  for (let i = 0; i < aBytes.length; i++) {
    diff |= aBytes[i] ^ bBytes[i];
  }
  return diff === 0;
}
```

---

#### ISSUE-002: `join-tournament` rate-limit config is missing — falls through to `DEFAULT_CONFIG` (20 req/60s)

**File:** `/supabase/functions/_shared/rate-limiter.ts` — `CONFIGS` object
**File:** `/supabase/functions/join-tournament/index.ts` line 136

```typescript
const rateLimitResult = checkRateLimit(user.id, "join-tournament");
```

The action key `"join-tournament"` is not defined in `CONFIGS`. It falls through to `DEFAULT_CONFIG` (20 requests per 60 seconds). For a financial join action, 20 joins/minute per user is excessive and could be used to hammer the `join_tournament_txn` RPC. The RPC's UNIQUE constraint prevents actual double-entry, but it generates unnecessary DB load and audit noise.

**Fix:** Add to `CONFIGS`:

```typescript
"join-tournament": {
  maxRequests: 3,
  windowMs: 60_000, // 3 join attempts per minute is generous
},
```

---

#### ISSUE-003: `settle-tournament` `forceCloseTrades` — partial failure does not block RPC call

**File:** `/supabase/functions/settle-tournament/index.ts` lines 85–176 and 182–208

When individual `close_trade_txn` calls fail (network error, RPC error), the error is pushed to `summary.errors` and execution continues. The outer `settleTournament` function then proceeds to call `settle_tournament_txn` regardless of how many trades were successfully closed.

This means: if 5 of 10 open trades failed to close, `settle_tournament_txn` runs on the remaining 5 still-open positions. The `final_roi` computation in the RPC reads `users.balance` — but those 5 users' balances still have their margin locked (trade is still open). Their `final_roi` will be computed against a balance that includes locked margin not yet returned, producing incorrect settlement numbers.

**Severity:** This is a data integrity issue in the settlement calculation. It is not a financial loss bug (the missed close_trade_txn means no funds actually move incorrectly), but it produces wrong ROI/rank values in the leaderboard.

**Fix:** If `summary.errors.length > 0` after `forceCloseTrades`, abort the `settle_tournament_txn` call and retry later. Add a retry mechanism or at minimum return early:

```typescript
async function settleTournament(...): Promise<void> {
  await forceCloseTrades(supabase, tournament, summary);

  // Do not settle if any trade failed to close — ROI would be computed
  // against incorrect balances (locked margin not yet returned).
  const priorErrorCount = summary.errors.length;
  if (priorErrorCount > 0) {
    const msg = `[settle-tournament] Skipping settle_tournament_txn for ${tournament.id}: ${priorErrorCount} trade(s) failed to close`;
    console.error(msg);
    summary.errors.push(msg);
    return;
  }

  const { error: settleError } = await supabase.rpc("settle_tournament_txn", { ... });
  ...
}
```

---

#### ISSUE-004: `openclaw-trade` — `computeMargin` function is defined AFTER its first call site

**File:** `/supabase/functions/openclaw-trade/index.ts` line 490 (call) vs line 522 (definition)

```typescript
// Line 490
const newMargin = computeMargin(refreshedBalance);

// Line 522
function computeMargin(balance: number): number { ... }
```

In TypeScript/Deno this works because function declarations are hoisted. However it is contrary to the "define before use" convention used everywhere else in the codebase. Move the `computeMargin` definition above `runAgent()`.

---

#### ISSUE-005: `scan-liquidations` — high-liquidation-rate warning fires AFTER all liquidations have been committed

**File:** `/supabase/functions/scan-liquidations/index.ts` lines 345–360

The warning is purely observational by design (the comment says so). This is acceptable for an MVP, but there is no circuit-breaker: if Binance returns a corrupt price (e.g. $0.01 for BTC), all longs will be liquidated before the warning fires. The warning becomes post-mortem noise rather than a prevention mechanism.

**Recommendation:** Add a pre-commit circuit-breaker that aborts the symbol's batch if `breachedTrades.length / symbolTrades.length > HIGH_LIQUIDATION_RATE_THRESHOLD` before calling any RPCs. This cannot roll back already-committed liquidations from previous symbols in the same scan, but it prevents runaway liquidation within a single symbol batch.

```typescript
// After computing breachedTrades, before the liquidation loop:
if (symbolTrades.length > 0 &&
    breachedTrades.length / symbolTrades.length > HIGH_LIQUIDATION_RATE_THRESHOLD) {
  console.error(`[scan-liquidations] CIRCUIT BREAKER: ${symbol} breach rate ` +
    `${(breachedTrades.length / symbolTrades.length * 100).toFixed(1)}% exceeds threshold. ` +
    `Skipping all ${breachedTrades.length} liquidations — possible price feed corruption.`);
  symbolResults.push({ symbol, market_price: marketPrice, ..., skipped_reason: "circuit_breaker" });
  continue;
}
```

---

### NIT

---

#### NIT-001: `app/page.tsx` — optimistic balance update may diverge from server state

**File:** `/Users/z/Desktop/OpenClaw Arena/app/page.tsx` lines 161 and 190

```typescript
setBalance((b) => b - marginNum);       // open trade
setBalance((b) => b + settlement);       // close trade
```

These are purely optimistic. If the Edge Function call fails after the UI has already applied the update, the displayed balance will be wrong. Given that `handleOpenTrade` and `handleCloseTrade` both have early-return paths on error before the `setBalance` call, the open-trade path is fine. The close-trade path also does the `setBalance` inside the success branch — also fine. This is actually correct.

No action needed. This nit is noted and dismissed.

---

#### NIT-002: `tournaments/page.tsx` — `loadCounts` fetches all participant rows and counts in JS

**File:** `/Users/z/Desktop/OpenClaw Arena/app/tournaments/page.tsx` lines 352–368

```typescript
const { data } = await supabase
  .from("tournament_participants")
  .select("tournament_id")
  .in("tournament_id", ids);
```

This pulls every participant row (just `tournament_id`) and counts in JavaScript. At MVP scale this is fine. Once tournaments have 100+ participants and multiple concurrent tournaments, this should be replaced with a `COUNT` grouped query via an RPC or a Postgres function.

---

#### NIT-003: `CyberPoster.tsx` — `eslint-disable` comment on auto-generated `useEffect`

**File:** `/Users/z/Desktop/OpenClaw Arena/components/CyberPoster.tsx` line 92

```typescript
// eslint-disable-next-line react-hooks/exhaustive-deps
```

The auto-generate effect intentionally omits `generatePoster` from the deps array because it should only fire on mount, not re-fire when `generating` changes. The comment is present and the intent is documented. However, the correct React pattern is an empty dep array `[]` with the function extracted to a `useCallback` outside the effect, or using a `useRef` for the guard. The current implementation works but is subtly fragile — if `posterRef.current` changes after mount, it silently uses a stale reference.

This is a minor React pattern issue, not a functionality bug.

---

#### NIT-004: `_shared/supabase-client.ts` — `hashApiKey` is exported but also re-implemented in `generate-api-key/index.ts`

**File 1:** `/supabase/functions/_shared/supabase-client.ts` line 153 — `export async function hashApiKey`
**File 2:** `/supabase/functions/generate-api-key/index.ts` line 104 — `async function sha256Hex`

Two separate SHA-256 implementations exist for the same purpose. The `generate-api-key` function does not import `hashApiKey` from `_shared/supabase-client.ts`. If either implementation is ever changed, they will diverge, producing keys that cannot be verified by the auth resolver.

**Fix:** In `generate-api-key/index.ts`, replace `sha256Hex` with an import of `hashApiKey`:

```typescript
import { getSupabaseAdmin, hashApiKey } from "../_shared/supabase-client.ts";
// Remove the local sha256Hex function
const hashedKey = await hashApiKey(rawKey);
```

This is the most important nit — it is one refactor away from a silent correctness bug.

---

#### NIT-005: `004_openclaw_agent.sql` — `tg_id = 0` assumes a UNIQUE constraint on `public.users.tg_id`

**File:** `/supabase/migrations/004_openclaw_agent.sql` line 95

The comment says "The UNIQUE constraint on tg_id means only one row can hold tg_id=0." This constraint is not defined in this migration and presumably was defined in an earlier migration (001). This is not a bug if 001 defines it, but it is an undocumented assumption. A comment referencing the migration that creates the constraint would improve readability.

---

## Security Review Summary

| Check | Status | Notes |
|---|---|---|
| API key hashing (SHA-256, not raw) | PASS | SHA-256 used in both generate and verify paths, but two separate implementations (NIT-004) |
| Auth tier model (JWT > x-user-id > API key) | PASS | Implemented correctly in `_shared/supabase-client.ts`; x-user-id only accepted when `apikey` header present |
| CORS headers include new headers | PASS | `x-user-id, x-user-email, x-api-key` all present in `cors.ts` |
| No sensitive data in error messages | PASS | All error paths return generic messages; internals logged server-side only |
| No hardcoded secrets | PASS | `SUPABASE_SERVICE_ROLE_KEY`, `INTERNAL_SECRET` read from `Deno.env` |
| Server-side price fetching | PASS | `getServerSidePrice` used in all trade-affecting functions; frontend uses WebSocket for display only |
| Timing-safe comparison for internal secret | PARTIAL | See ISSUE-001 |
| RLS on all new tables | PASS | `liquidation_events`, `tournaments`, `tournament_participants` all have RLS enabled |
| REVOKE from PUBLIC on all RPCs | PASS | All four RPCs have explicit REVOKE ALL from PUBLIC, anon, authenticated |
| SECURITY DEFINER on all RPCs | PASS | All four RPCs use SECURITY DEFINER with `SET search_path = public` |

---

## Race Condition Analysis

| Scenario | Guard | Verdict |
|---|---|---|
| Two scanner invocations liquidate the same trade simultaneously | `FOR UPDATE` on trade row → idempotency check `status != 'open'` returns NULL | SAFE |
| Two users join tournament simultaneously when 1 slot remains | `FOR UPDATE` on tournament row + COUNT under lock (not passed as arg) | SAFE — TOCTOU eliminated |
| User drains balance between join check and participant INSERT | `FOR UPDATE` on users row held until INSERT completes | SAFE |
| Two cron calls trigger settlement for same tournament | `'settling'` intermediate status acts as distributed mutex after `FOR UPDATE` | SAFE — second call re-enters 'settling' branch and produces deterministic result |
| Concurrent `execute_trade_txn` and `liquidate_trade_txn` for same user | Both lock `users` row with `FOR UPDATE` — one blocks until the other commits | SAFE |
| `openclaw-trade` opens two concurrent positions | Sequential by design (single cron invocation, `await` chain) | SAFE — but cron overlapping invocations could theoretically cause this; Supabase cron does not guarantee non-overlap |

**Note on cron overlap:** Supabase cron does not have a built-in mutex. If `openclaw-trade` takes longer than its cron interval (unlikely given the simple logic, but possible under network degradation), two agent cycles could run concurrently. The `execute_trade_txn` RPC should have its own idempotency guard (presumably it checks whether a position is already open). This should be verified in the Phase 1 migration if not already present.

---

## Data Flow Verification

### Liquidation Flow: VERIFIED CORRECT
1. Scanner fetches open trades (indexed partial index on `status='open'`)
2. Fetches server-side price per symbol (not from frontend)
3. Staleness guard (10s) before any liquidation is attempted
4. `isBreached()` correctly implements long (price <= liq) and short (price >= liq)
5. `liquidate_trade_txn` RPC: atomic, FOR UPDATE, idempotent, audit trail via `liquidation_events`
6. ROI recomputed server-side after balance change

### AI Agent Flow: VERIFIED CORRECT
1. Fetches balance and open position in parallel
2. Fetches live price server-side (not client-provided)
3. Fetches klines (12 x 5m candles) for SMA signal
4. Stop-loss (5% unrealised loss on margin) triggers close before signal evaluation
5. Signal flip triggers close-then-open with refreshed balance
6. `computeMargin` is effectively a no-op cap (MARGIN_FRACTION == MAX_MARGIN_FRACTION * 0.4, so preferred always < cap) — this is safe but the cap is unreachable

### Tournament Flow: MOSTLY CORRECT — see BUG-001, BUG-002, ISSUE-003
1. Expired active tournaments fetched by cron
2. Open trades force-closed via `close_trade_txn` (per-symbol price cached)
3. `settle_tournament_txn` called after trades closed — BUT partial close failures are not blocked (ISSUE-003)
4. RPC correctly computes `(balance - entry_balance) / entry_balance` and ranks via `RANK()` window function
5. `'settling'` intermediate status prevents double-settlement

### Join Flow: VERIFIED CORRECT
1. JWT-first auth
2. Rate-limited (using default config, see ISSUE-002)
3. UUID validation before RPC call
4. All business rules enforced inside atomic RPC (capacity, balance, status)
5. UNIQUE constraint surfaces duplicate joins as 409

---

## Final Verdict

**REQUEST CHANGES**

Two blockers must be fixed before this can be merged:

1. **BUG-001** — Remove the non-existent `symbol` field from the `Tournament` interface and the `.select()` query in `settle-tournament`. This will cause a runtime query error on strict PostgREST configs.

2. **BUG-002** — Fix the `Tournament.status` type union to match the actual DB enum (`"upcoming" | "active" | "settling" | "completed"`). The string `"settled"` does not exist in the schema.

Three suggestions should be addressed before production (not blocking merge to develop):

- **ISSUE-003** — Abort `settle_tournament_txn` when `forceCloseTrades` has errors; do not settle with incorrect balances.
- **NIT-004** — Consolidate the two SHA-256 hash implementations to prevent divergence.
- **ISSUE-002** — Add `"join-tournament"` to the rate-limiter config with a tighter limit.

One security item to track for production:

- **ISSUE-001** — Replace string equality with timing-safe comparison in `generate-api-key`.

The overall quality of Phase 2 is high. The database layer is exceptionally well-designed: every financial RPC has FOR UPDATE locks, idempotency guards, and correct SECURITY DEFINER + REVOKE coverage. The liquidation scanner is production-grade with staleness guards and per-trade error isolation. The two blockers are type/schema mismatches — easily fixed, not architectural flaws.

---

## Checklist

- [x] RLS on ALL new tables (`liquidation_events`, `tournaments`, `tournament_participants`)
- [x] All RPCs are SECURITY DEFINER + SET search_path = public
- [x] All RPCs have REVOKE ALL from PUBLIC, anon, authenticated
- [x] No hardcoded secrets
- [x] Server-side price fetching — never trusts frontend price
- [x] Atomic transactions via RPC for all financial operations
- [x] API key hashing (SHA-256)
- [x] Auth tier model (JWT > x-user-id+apikey > API key)
- [x] CORS headers include `x-api-key`, `x-user-id`, `x-user-email`
- [x] No sensitive data in error messages or logs
- [x] FOR UPDATE locks in all financial RPCs
- [x] Idempotency guards (double-liquidation: status check; double-join: UNIQUE constraint; double-settle: 'settling' guard)
- [ ] `settle-tournament` Tournament interface matches DB schema — **FAILING (BUG-001, BUG-002)**
- [ ] Partial close-trade failures block settlement — **FAILING (ISSUE-003)**
- [ ] Single SHA-256 implementation — **FAILING (NIT-004)**
- [ ] `join-tournament` rate-limit config explicitly defined — **FAILING (ISSUE-002)**
