# Lock Ordering Specification

**Status:** Active system invariant (enforced from migration 012 onward)
**Scope:** All Supabase RPCs (PostgreSQL stored functions) that acquire `FOR UPDATE` row locks across multiple tables in a single transaction.

---

## The Problem: Deadlock from Inconsistent Lock Order

PostgreSQL detects deadlocks by finding cycles in the waits-for graph. A cycle forms when:

- Transaction A holds lock on Row X and is waiting for lock on Row Y.
- Transaction B holds lock on Row Y and is waiting for lock on Row X.

Neither transaction can proceed. PostgreSQL kills one of them with `ERROR 40P01: deadlock detected`.

### The concrete scenario in OpenClaw Arena (pre-012)

```
T1: execute_trade_txn
    1. FOR UPDATE on users row U1    <-- holds U1
    2. INSERT into trades ...        <-- may conflict with unique index

T2: close_trade_txn
    1. FOR UPDATE on trades row T1   <-- holds T1
    2. FOR UPDATE on users row U1    <-- waiting for U1 (held by T1)

T1 is waiting for the trades INSERT lock (held or blocked by T2).
T2 is waiting for U1 (held by T1).
Cycle formed. PostgreSQL kills one of them.
```

This could occur under normal production load whenever a user manually closes a trade while simultaneously opening another position.

---

## The Solution: Canonical Lock Ordering

Establish a fixed global order. Every transaction that needs locks on multiple tables must acquire them in this sequence:

```
1. tournaments   (if this table is involved)
2. users         (always lock before trades)
3. trades        (always lock after users)
```

Two transactions that acquire locks in the same order can never form a cycle: T1 waiting for a lock that T2 holds means T2 acquired it first, which means T2 will finish and release before T1 can be blocked. No cycle.

---

## Why This Order

The ordering was chosen to minimise lock scope in the most common concurrent scenario: multiple trades closing for the same user simultaneously.

**Rationale for `users` before `trades`:**

`execute_trade_txn` must lock `users` first (to prevent double-spend). Making `close_trade_txn` and `liquidate_trade_txn` also lock `users` first ensures the pair never forms a cycle.

**Rationale for `tournaments` before `users`:**

`join_tournament_txn` needs to lock the tournament row to enforce the capacity cap before it checks the user's balance. A user joining a tournament while simultaneously executing a trade would form a cycle if the orders were reversed. Since no other RPC locks `tournaments`, putting it at position 1 is safe and requires no other RPC changes.

---

## RPC Lock Acquisition Table

All `FOR UPDATE` locks, listed in acquisition order per RPC, as of migration 012.

| RPC | Migration | Lock 1 | Lock 2 | Lock 3 |
|-----|-----------|--------|--------|--------|
| `execute_trade_txn` | 002 | `users FOR UPDATE` | `trades INSERT` (no explicit row lock) | — |
| `close_trade_txn` | 012 | `users FOR UPDATE` | `trades FOR UPDATE` | — |
| `liquidate_trade_txn` | 012 | `users FOR UPDATE` | `trades FOR UPDATE` | — |
| `join_tournament_txn` | 006 | `tournaments FOR UPDATE` | `users FOR UPDATE` | — |
| `settle_tournament_txn` | 006 | `tournaments FOR UPDATE` | — | — |
| `award_daily_reward_txn` | 008 | `users FOR UPDATE` | — | — |

No cycle is possible among any pair of these RPCs because every RPC that touches both `users` and `trades` acquires `users` first, and every RPC that touches both `tournaments` and `users` acquires `tournaments` first.

---

## The Peek-Then-Lock Pattern

`close_trade_txn` and `liquidate_trade_txn` both need to read the trade row before locking it (to validate ownership and perform fast idempotency checks). Under the new ordering, the trade lock is acquired after the user lock. This creates an apparent chicken-and-egg problem: how do we validate the trade before we have its lock, if locking it first violates the ordering?

The answer is the **peek-then-lock** pattern:

```
Peek   — SELECT from trades (no FOR UPDATE) to validate existence,
         ownership, and optionally fast-exit on idempotency.
Lock   — FOR UPDATE on users (canonical position 2).
Lock   — FOR UPDATE on trades (canonical position 3).
Check  — Re-validate trade status under both locks.
Act    — Mutate both rows.
```

### Why the peek is safe

| Property | Reason |
|----------|--------|
| `trade.user_id` | Immutable after INSERT. Ownership check in the peek requires no lock. |
| `trade.status` | Mutable. The peek is an optimisation only. The authoritative status check is the re-validation under the trade FOR UPDATE lock. |
| Stale 'open' read | If the peek observes `status = 'open'` while another transaction is concurrently closing the trade, the re-check under both locks sees the committed `status = 'closed'` and raises the correct error (for `close_trade_txn`) or returns NULL (for `liquidate_trade_txn`, idempotency path). |

### TOCTOU (Time-of-Check-Time-of-Use) analysis

The peek introduces a window between the status read and the trade lock. Three scenarios:

1. **Trade stays 'open':** Re-check passes, mutation proceeds normally.
2. **Trade closed between peek and re-check:** Re-check sees `status != 'open'`, raises `trade_not_found` (close) or returns NULL (liquidate). Correct behaviour.
3. **Trade opened again between peek and re-check:** Not possible. A trade's status can only move forward: `open` → `closed` or `open` → `liquidated`. There is no backward transition.

The re-check under both locks is the invariant that makes the peek safe. It must not be removed.

---

## How to Add a New RPC Without Creating Deadlocks

Follow this checklist every time you write a new stored function that acquires `FOR UPDATE` locks on more than one table.

### Step 1: Identify every table the RPC will lock

List every `SELECT ... FOR UPDATE` and `UPDATE` statement. For the purpose of lock ordering, an `UPDATE` without a preceding `SELECT ... FOR UPDATE` acquires a row-level lock implicitly at execution time; treat it as locking the table at the position where it appears in the function body.

### Step 2: Sort the tables using the canonical order

```
Position 1: tournaments
Position 2: users
Position 3: trades
Position 4+: any new tables (assign them a position, document it here)
```

If your new RPC needs to lock a table not listed above, assign it a position and update this document before merging. Never assign a new table the same position as an existing one.

### Step 3: Reorder your SQL statements if necessary

The `FOR UPDATE` statements in your function body must appear in canonical position order. If a business-logic reason seems to require acquiring a lower-position lock first, use the peek-then-lock pattern: read without lock, acquire locks in order, re-validate.

### Step 4: Document the lock sequence in the RPC header comment

Every stored function that acquires multiple locks must include a comment block of this form:

```sql
-- Lock order (canonical):
--   1. <table_name> FOR UPDATE   (canonical position N)
--   2. <table_name> FOR UPDATE   (canonical position M)
```

### Step 5: Add a row to the RPC Lock Acquisition Table above

Submit a PR that updates this document alongside the migration. The table is the single source of truth for the operational team.

### Step 6: Verify with a deadlock scenario analysis

Before merging, identify every existing RPC that shares at least one table with your new RPC. For each pair, confirm that the lock acquisition sequences do not form a cycle. Document this analysis in the PR description.

---

## Adding a New Table to the Ordering

If a future feature requires locking a new table `foo` inside an RPC that also locks `users` or `trades`:

1. Decide where `foo` falls in the global order based on the dependency direction of your business logic. Prefer assigning it position 1 (locked first) if it acts as a container or capacity limiter (like `tournaments`), or a position after `trades` if it is a detail record locked after settlement.
2. Assign an explicit integer position and add it to the canonical order list at the top of this document.
3. Audit every existing RPC that touches `foo` to ensure they follow the new position. Write migrations to fix any that do not.
4. Update the RPC Lock Acquisition Table.

---

## Incident Reference

The deadlock risk was identified during migration 012 (2026-03-29). The pre-012 situation:

| RPC | Pre-012 lock order |
|-----|--------------------|
| `execute_trade_txn` | `users` then `trades INSERT` |
| `close_trade_txn` | `trades FOR UPDATE` then `users FOR UPDATE` |
| `liquidate_trade_txn` | `trades FOR UPDATE` then `users FOR UPDATE` |

Migration 012 rewrote `close_trade_txn` and `liquidate_trade_txn` to acquire the `users` lock first, eliminating the cycle. No changes were made to `execute_trade_txn`, `join_tournament_txn`, `settle_tournament_txn`, or `award_daily_reward_txn` because those functions already followed the correct order or did not participate in the conflicting lock pair.

All bankruptcy fund logic, idempotency guards, and ROI recomputation from migration 007 were preserved without modification.
