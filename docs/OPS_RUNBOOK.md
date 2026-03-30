# OpenClaw Arena — Production Operations Runbook

> **Audience**: On-call engineers
> **Last Updated**: 2026-03-29
> **Stack**: Supabase Edge Functions (Deno/TypeScript) + PostgreSQL

---

## 1. Cron Job Inventory

All cron jobs are triggered by the Supabase scheduler via POST. Each function also accepts GET for manual health-check invocations from the Supabase Dashboard or curl.

| Function | Schedule | Purpose | Healthy Response |
|---|---|---|---|
| `scan-liquidations` | Every 60s | Fetch live Binance prices, liquidate breached positions via `liquidate_trade_txn`, trigger price alerts for all active `price_alerts` rows | HTTP 200; `data.total_trades_scanned` present (may be 0 when no open trades exist); `data.high_liquidation_rate_warning: false` |
| `openclaw-trade` | Every 10min | AI momentum agent (BTC/USDT, 10x leverage, SMA-12 signal); applies 0–120s crypto-random jitter before acting | HTTP 200; `data.action` present (`open`, `hold`, `stop_loss`, `signal_flip`, `skip`) |
| `openclaw-conservative` | Every 15min | AI mean-reversion agent (ETH/USDT, 5x leverage, SMA-24 ±2% band); same jitter pattern | HTTP 200; `data.action` present |
| `openclaw-chaos` | Every 20min | AI random agent (BTC or ETH chosen per cycle, 5–50x leverage, 50% flip probability per cycle); same jitter pattern | HTTP 200; `data.action` present |
| `send-notifications` | Every 5min | Three sub-jobs: (A) tournament reminders 55–65 min before start, (B) streak reminders 16:00–20:00 user local time, (C) rivalry alerts when OpenClaw's rank improves | HTTP 200 (all sub-jobs clean) or 207 (partial errors); response body contains per-job counts and `errors[]` |
| `process-outbox` | Every 30s | Claim up to 10 `pending` rows from `event_outbox`, dispatch `check_achievements` or `send_notification` events, retry on failure up to `max_attempts` (default 3) | HTTP 200; `data.processed` and `data.completed` counts present |
| `settle-tournament` | Every 5min | Activate `upcoming` tournaments whose `start_at` has passed; force-close open trades in `active/settling` tournaments whose `end_at` has passed; call `settle_tournament_txn` once all trades are closed | HTTP 200 (clean) or 207 (partial errors); `data.settledTournaments[]` and `data.partialTournaments[]` present |
| `cleanup-logs` | Daily 03:00 UTC | Delete `notification_log` and `event_outbox` rows (status `completed` or `failed`) older than 7 days | HTTP 200; `data.notification_log_deleted` and `data.event_outbox_deleted` counts present |

### Cron Authentication

All cron-triggered functions require the `apikey` header set to `SUPABASE_SERVICE_ROLE_KEY`. The Supabase scheduler injects this automatically. Manual invocations must include it:

```bash
curl -X POST "${SUPABASE_URL}/functions/v1/scan-liquidations" \
  -H "apikey: ${SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}"
```

---

## 2. Monitoring Alerts

### Critical — Page Immediately

| Condition | Query / Signal | Action |
|---|---|---|
| `scan-liquidations` fails 3 consecutive times | Supabase Function logs: HTTP 500 or missing `total_trades_scanned` in response body | Open positions are not being monitored. Check Binance price feed reachability. Manually trigger to verify. Escalate if feed is down. |
| `bankruptcy_events` count > 0 in last hour | `SELECT COUNT(*) FROM public.bankruptcy_events WHERE created_at > NOW() - INTERVAL '1 hour'` | Market moved faster than the 60s scan interval. Verify Binance prices are accurate. Inspect which trades triggered it and the `socialized_loss` amounts. No user action is needed — the RPC already clamped balances. |
| `process-outbox` has > 100 pending events older than 5 min | `SELECT COUNT(*) FROM public.event_outbox WHERE status = 'pending' AND created_at < NOW() - INTERVAL '5 minutes'` | The outbox processor is behind or failing. Check function logs for dispatch errors. Restart the cron if the function is not running. Events are durable — they will drain once the processor recovers. |

### Warning — Investigate Within 24 Hours

| Condition | Query / Signal | Action |
|---|---|---|
| `event_outbox` has > 10 `failed` rows | `SELECT COUNT(*) FROM public.event_outbox WHERE status = 'failed'` | These events exhausted `max_attempts` (default 3). Inspect `error_message` column. Replay manually by resetting `status = 'pending', attempts = 0` on affected rows after fixing the root cause. |
| TG Bot mute rate > 5% over 7 days | `SELECT COUNT(*) FILTER (WHERE delivered = FALSE) / COUNT(*)::float FROM public.notification_log WHERE sent_at > NOW() - INTERVAL '7 days'` | Users are blocking the bot or deactivating accounts. Consider reducing notification frequency or adding an unsubscribe flow. |
| `scan-liquidations` response contains `high_liquidation_rate_warning: true` | Present in function response body and logs | More than 50% of open trades were breached in a single scan. This is normal during a genuine crash but may also indicate a corrupted price feed. Verify the Binance price before concluding it is a real market event. Liquidations are already committed — no rollback is possible. |
| Any AI agent returns HTTP 500 for 3 consecutive cycles | Supabase Function logs | Agent cannot trade. Balance and open positions are unaffected. Check `Kline feed unavailable` or `Price feed unavailable` in logs. Usually transient Binance API degradation. |

---

## 3. Referral Bonus Async Flow

```
User A shares ref link         User B signs up
      │                               │
      │                               ▼
      │                   register-referral (POST)
      │                    ├── Validate ref code exists
      │                    ├── Detect self-referral (reject silently)
      │                    ├── Detect returning user (ignore ref param)
      │                    └── SET users.referred_by = A's UUID
      │                        referral_events: status = 'pending'
      │
      │              (User B completes first qualifying trade)
      │              (margin >= 100 USDT, human account)
      │
      │                        close_trade_txn commits
      │                               │
      │                               ▼
      │                   qualify_referral logic
      │                    ├── Check device_fingerprint cluster
      │                    │   (reject multi-account farming)
      │                    ├── Check margin >= 100
      │                    ├── award_referral_bonus_txn RPC:
      │                    │    ├── Lock users rows (lower UUID first)
      │                    │    ├── Idempotency check (referee_id UNIQUE)
      │                    │    ├── Credit A +500 USDT
      │                    │    ├── Credit B +500 USDT
      │                    │    ├── INSERT referral_events (status = 'paid')
      │                    │    └── INSERT event_outbox (referral_bonus_paid)
      │                               │
      │                               ▼ (process-outbox, ~30s later)
      │
      └── TG notification to A: "Your referral earned you 500 USDT!"
```

### Referral Idempotency Guarantee

`referral_events` has a `UNIQUE` constraint on `referee_id`. A referee can trigger at most one payout event, ever. `award_referral_bonus_txn` uses `ON CONFLICT DO NOTHING` as a second layer for concurrent racing calls.

### Replaying a Stuck Referral

If `award_referral_bonus_txn` was never called despite the qualifying trade existing:

```sql
-- Verify the trade closed and no referral_events row exists
SELECT r.referee_id, r.referred_by, t.id AS trade_id, t.status, t.margin
FROM public.users r
JOIN public.trades t ON t.user_id = r.id
WHERE r.referred_by IS NOT NULL
  AND t.status = 'closed'
  AND t.margin >= 100
  AND NOT EXISTS (
    SELECT 1 FROM public.referral_events re WHERE re.referee_id = r.id
  );

-- If the above returns rows, call the RPC directly:
SELECT public.award_referral_bonus_txn(
  '<referrer_uuid>',
  '<referee_uuid>'
);
```

---

## 4. Database Maintenance

### Log Retention

`cleanup-logs` runs daily at 03:00 UTC. It purges:

- `notification_log`: rows older than 7 days
- `event_outbox`: rows with `status IN ('completed', 'failed')` older than 7 days

`pending` and `processing` rows are never deleted by the cleanup job — they remain available for the processor to drain.

If the cleanup function is not deployed, run manually:

```sql
DELETE FROM public.notification_log
WHERE sent_at < NOW() - INTERVAL '7 days';

DELETE FROM public.event_outbox
WHERE status IN ('completed', 'failed')
  AND created_at < NOW() - INTERVAL '7 days';
```

### Key Composite Indexes

| Table | Index | Columns / Condition | Purpose |
|---|---|---|---|
| `trades` | `idx_trades_liquidation_scan` | `(symbol, liquidation_price) WHERE status = 'open'` | Partial index used by `scan-liquidations` to locate open trades efficiently |
| `notification_log` | `idx_notification_log_rate_limit` | `(user_id, sent_at) WHERE delivered = TRUE` | Rate-limit check: count recent successful deliveries per user per notification type |
| `notification_log` | `idx_notification_log_type_rate_limit` | `(user_id, notification_type, sent_at) WHERE delivered = TRUE` | Per-type rate-limit (e.g. max 1 rivalry ping per hour) |
| `event_outbox` | `idx_event_outbox_pending` | `(created_at) WHERE status = 'pending'` | Processor polling query: fetch oldest pending rows first |
| `price_alerts` | `idx_price_alerts_active_symbol` | `(symbol) WHERE is_active = TRUE` | Scanner bulk sweep per symbol |
| `users` | `idx_users_referral_code` | `(referral_code) WHERE referral_code IS NOT NULL` | Referral code lookup on signup |
| `referral_events` | `idx_referral_events_referrer` | `(referrer_id)` | "How many users have I recruited?" queries |

### Vacuuming

Supabase manages `autovacuum` automatically. No manual `VACUUM` is required. If table bloat is suspected after a mass-liquidation event:

```sql
-- Check for bloat (requires pg_stat_user_tables)
SELECT relname, n_dead_tup, n_live_tup
FROM pg_stat_user_tables
WHERE relname IN ('trades', 'event_outbox', 'notification_log')
ORDER BY n_dead_tup DESC;
```

### Lock Ordering (Reference)

All RPCs that acquire multiple row locks follow this canonical order to prevent deadlocks:

1. `tournaments`
2. `users` (lower UUID first when locking two rows from the same table)
3. `trades`
4. `price_alerts`

See `/Users/z/Desktop/OpenClaw Arena/docs/LOCK_ORDERING.md` for the full RPC lock acquisition table.

---

## 5. Emergency Procedures

### Mass Liquidation Event

**Symptoms**: `scan-liquidations` response contains `high_liquidation_rate_warning: true`; `bankruptcy_events` table is growing; user balance complaints.

**Steps**:
1. Fetch the current Binance price manually and compare to recent trades' `liquidation_price` values:
   ```bash
   curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT"
   ```
2. If the Binance price looks accurate, this is a genuine market event. No action required — liquidations are already committed.
3. If the Binance price looks wrong (e.g. returns 0 or a nonsensical value), `scan-liquidations` already has a staleness guard (`MAX_PRICE_AGE_MS = 10000`). However, the symbol may have been processed before the guard triggered. Audit `bankruptcy_events`:
   ```sql
   SELECT trade_id, user_id, expected_balance, socialized_loss, created_at
   FROM public.bankruptcy_events
   ORDER BY created_at DESC
   LIMIT 20;
   ```
4. If liquidations were caused by a bad price feed, file a support ticket and coordinate with the Binance API status page. Balance restoration requires a manual SQL operation coordinated with the product owner — there is no automated rollback path.

### Outbox Processor Down

**Symptoms**: `event_outbox` pending count growing; achievements not being awarded; referral notifications not being sent.

**Recovery**:
1. Events accumulate safely in the database — nothing is lost.
2. Investigate `process-outbox` function logs for the root error.
3. If the function is failing on a specific event type, patch the dispatcher and redeploy:
   ```bash
   supabase functions deploy process-outbox
   ```
4. The function will automatically drain the backlog on the next cron tick (every 30s), processing in FIFO order, 10 rows per invocation.
5. If an event is permanently stuck (status = `failed`), inspect `error_message`, fix the root cause, then replay:
   ```sql
   UPDATE public.event_outbox
   SET status = 'pending', attempts = 0, error_message = NULL
   WHERE id = '<row_id>';
   ```

### Telegram Bot Token Rotation

**When**: Token is compromised, expired, or rotated per security policy.

**Steps**:
1. Generate a new token via `@BotFather` on Telegram.
2. Update the Supabase Secret:
   ```bash
   supabase secrets set TELEGRAM_BOT_TOKEN=<new_token>
   ```
3. Redeploy the functions that consume the token:
   ```bash
   supabase functions deploy send-notifications
   supabase functions deploy process-outbox
   ```
   Note: `telegram-notify.ts` is a shared module; redeploying the consumers above is sufficient.
4. Verify delivery with a manual trigger:
   ```bash
   curl -X POST "${SUPABASE_URL}/functions/v1/send-notifications" \
     -H "apikey: ${SERVICE_ROLE_KEY}" \
     -H "Authorization: Bearer ${SERVICE_ROLE_KEY}"
   ```
   Check the response for `errors: []`.

### AI Agent Balance Depletion

**Symptoms**: An agent's `action` is consistently `skip`; agent balance falls below 100 USDT.

**Recovery** (coordinate with product owner before executing):
```sql
UPDATE public.users
SET balance = 10000, roi = 0
WHERE id = '00000000-0000-0000-0000-00000c1a0001'  -- openclaw_original
   OR id = '00000000-0000-0000-0000-00000c1a0002'  -- openclaw_conservative
   OR id = '00000000-0000-0000-0000-00000c1a0003'; -- openclaw_chaos
```

### Settle-Tournament Stuck in Partial State

**Symptoms**: A tournament has `status = 'settling'` but does not progress to `completed` after several cron ticks. Open trades still exist but `settle-tournament` keeps reporting `partialTournaments`.

**Investigation**:
```sql
-- Find trades that are blocking final settlement
SELECT t.id, t.user_id, t.symbol, t.status, t.margin
FROM public.trades t
JOIN public.tournaments tn ON tn.id = t.tournament_id
WHERE tn.status = 'settling'
  AND t.status = 'open';
```

If the same trade IDs appear across multiple ticks, inspect the `errors` array in the `settle-tournament` response. A common cause is a price feed failure for a specific symbol. Once the Binance feed recovers, the next cron tick will resume automatically.

If forced resolution is needed (price feed permanently unavailable), manually close the blocking trades using the last known valid price:
```sql
SELECT public.close_trade_txn(
  '<trade_id>',
  '<user_id>',
  <last_known_price>,
  <realised_pnl>,
  <settlement>
);
```
Then re-trigger `settle-tournament`:
```bash
curl -X POST "${SUPABASE_URL}/functions/v1/settle-tournament" \
  -H "apikey: ${SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}"
```

---

## 6. Useful Queries

```sql
-- Open trade count by symbol
SELECT symbol, COUNT(*) AS open_trades
FROM public.trades WHERE status = 'open'
GROUP BY symbol;

-- Outbox backlog by event type
SELECT event_type, status, COUNT(*) AS count
FROM public.event_outbox
GROUP BY event_type, status
ORDER BY event_type, status;

-- Recent notification delivery rate (last 24h)
SELECT
  notification_type,
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE delivered) AS delivered,
  ROUND(COUNT(*) FILTER (WHERE delivered)::numeric / COUNT(*) * 100, 1) AS delivery_pct
FROM public.notification_log
WHERE sent_at > NOW() - INTERVAL '24 hours'
GROUP BY notification_type;

-- Tournament status summary
SELECT status, COUNT(*) AS count FROM public.tournaments GROUP BY status;

-- Active price alerts by symbol
SELECT symbol, direction, COUNT(*) AS alert_count
FROM public.price_alerts WHERE is_active = TRUE
GROUP BY symbol, direction;

-- Recent referral payouts
SELECT re.bonus_paid_at, u_r.display_name AS referrer, u_e.display_name AS referee,
       re.referrer_bonus, re.referee_bonus
FROM public.referral_events re
JOIN public.users u_r ON u_r.id = re.referrer_id
JOIN public.users u_e ON u_e.id = re.referee_id
ORDER BY re.bonus_paid_at DESC
LIMIT 20;
```
