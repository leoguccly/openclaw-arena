# Phase 2: OpenClaw Arena — Feature Specification

> **Created**: 2026-03-29
> **Status**: Approved for Development
> **Sprint**: 2 weeks (2026-03-31 ~ 2026-04-13)

---

## Priority & Build Order

| # | Feature | Priority | Effort | Rationale |
|---|---------|----------|--------|-----------|
| 1 | Liquidation Scanner | P0 | M | Game correctness prerequisite; all other features depend on it |
| 2 | OpenClaw AI Agent | P1 | M | Core narrative unlock — "the lobster actually trades" |
| 3 | Tournament Mode | P2 | L | Engagement + retention layer; needs liquidation + AI opponent |
| 4 | Social Sharing Enhancement | P3 | M | Distribution layer; needs tournament results to exist |

---

## Feature A: Liquidation Scanner (P0)

### User Stories

- **US-A1**: As a trader, when my position's current price crosses the liquidation threshold, my trade is auto-closed within 60 seconds so I don't accumulate phantom losses.
- **US-A2**: As a trader, I can see "LIQUIDATED" status on my trade history so I know it was force-closed.

### Technical Design

- **Trigger**: `pg_cron` job every 30 seconds OR Edge Function cron every 60 seconds
- **Flow**:
  1. Query all `trades WHERE status = 'open'` (use `idx_trades_liquidation_scan`)
  2. Batch by symbol, fetch current price from Binance REST API (reuse `getServerSidePrice`)
  3. For each trade: if long and `price <= liquidation_price`, OR short and `price >= liquidation_price` → liquidate
  4. Call `liquidate_trade_txn` RPC (atomic: set status='liquidated', exit_price=liquidation_price, realised_pnl=-margin, settlement=0, update user balance)
  5. Insert row into `liquidation_events` audit table

### Edge Cases

| ID | Case | Handling |
|----|------|----------|
| EC-A1 | Price recovers between scan cycles | Accepted risk for paper trading; 60s interval is sufficient |
| EC-A2 | User manually closes while scanner runs | `liquidate_trade_txn` checks `status = 'open'` with FOR UPDATE lock; if already closed, no-op |
| EC-A3 | Binance price stale (> 10s) | Abort scan cycle, log warning, retry next interval |
| EC-A4 | Scanner crashes mid-batch | Each liquidation is independent; partial completion is safe |
| EC-A5 | Pre-existing breached positions on first deploy | Scanner handles them on next cycle — no special migration needed |

### New DB Objects

```sql
-- Table: liquidation_events (audit trail)
CREATE TABLE public.liquidation_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id UUID NOT NULL REFERENCES public.trades(id),
  user_id UUID NOT NULL REFERENCES public.users(id),
  symbol TEXT NOT NULL,
  liquidation_price NUMERIC(20, 8) NOT NULL,
  market_price NUMERIC(20, 8) NOT NULL,
  margin NUMERIC(18, 4) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RPC: liquidate_trade_txn
-- Similar to close_trade_txn but:
--   status = 'liquidated' (not 'closed')
--   exit_price = liquidation_price
--   realised_pnl = -margin
--   settlement = 0
```

### API Endpoint

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `scan-liquidations` | Internal (cron) | service_role | Scans and liquidates breached positions |

---

## Feature B: OpenClaw AI Agent (P1)

### User Stories

- **US-B1**: As the system, OpenClaw (the lobster) auto-trades every 10 minutes using a momentum strategy so humans have a real opponent.
- **US-B2**: As a trader, I can see OpenClaw's current position and ROI on the leaderboard and trading page.
- **US-B3**: As a developer, I can generate API keys for the agent to authenticate against trade endpoints.
- **US-B4**: As a trader, API key auth works on execute-trade and close-trade so agents can trade programmatically.

### Technical Design

#### AI Agent Cron (openclaw-trade)

- **Trigger**: Edge Function cron every 10 minutes
- **Strategy (v1 — Simple Momentum)**:
  1. Fetch last 12 candles (5-min klines) from Binance REST API
  2. Compute: if close[now] > SMA(12) → signal = LONG, else → SHORT
  3. If no open position and signal exists → open trade (2% of balance, 10x leverage)
  4. If open position and signal flips → close current, open opposite
  5. If open position and drawdown > 5% → close (trailing stop)
- **Constraints**: Max 5% of balance per trade, max 20x leverage, max 1 position per symbol

#### API Key Authentication

- Add `X-API-Key` header support to `getUserFromAuth()` as **Tier 3** (after JWT, after x-user-id)
- Lookup: SHA-256 hash the provided key → query `api_keys WHERE hashed_key = hash AND is_active = true`
- On match: resolve user_id from the api_keys row, update `last_used_at`
- Rate limit: same per-user limits as human traders

#### API Key Management Endpoints

| Endpoint | Method | Auth | Request | Response |
|----------|--------|------|---------|----------|
| `generate-api-key` | POST | service_role | `{ user_id }` | `{ key_prefix, raw_key }` (raw_key shown once) |
| `list-api-keys` | GET | JWT | — | `[{ id, key_prefix, label, is_active, last_used_at }]` |
| `revoke-api-key` | POST | JWT | `{ key_id }` | `{ success: true }` |

### Frontend Addition

- **OpenClaw Status Widget** on trading page header: "🦞 OpenClaw: LONG BTC 10x | ROI: +12.5%"
- Query OpenClaw's current open trade + ROI from leaderboard_view + trades (via a new view or Edge Function)

---

## Feature C: Tournament Mode (P2)

### User Stories

- **US-C1**: As a trader, I can browse upcoming/active/completed tournaments.
- **US-C2**: As a trader, I can join a tournament (balance snapshot taken at entry).
- **US-C3**: As a trader, I can see a tournament-specific leaderboard during competition.
- **US-C4**: As the system, when a tournament ends, all open positions are market-closed and final ROI is calculated.

### Technical Design

#### New Tables

```sql
-- tournaments
CREATE TABLE public.tournaments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT DEFAULT '',
  start_at TIMESTAMPTZ NOT NULL,
  end_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'upcoming'
    CHECK (status IN ('upcoming', 'active', 'settling', 'completed')),
  max_participants INT DEFAULT 100,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- tournament_participants
CREATE TABLE public.tournament_participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id UUID NOT NULL REFERENCES public.tournaments(id),
  user_id UUID NOT NULL REFERENCES public.users(id),
  entry_balance NUMERIC(18, 4) NOT NULL,  -- snapshot at join
  final_roi NUMERIC(10, 6),               -- computed at settlement
  rank INT,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tournament_id, user_id)
);
```

- `trades` table gets optional `tournament_id UUID REFERENCES tournaments(id)` column
- Trades within a tournament period + by a participant are tagged with `tournament_id`

#### Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `list-tournaments` | GET | anon/auth | List tournaments by status |
| `join-tournament` | POST | JWT | Join tournament, snapshot balance |
| `settle-tournament` | Internal (cron) | service_role | End tournament, close positions, compute rankings |

#### Tournament Settlement Flow

1. Set status = 'settling'
2. For each participant with open positions: force-close at market price
3. Compute tournament ROI = (current_balance - entry_balance) / entry_balance
4. Rank participants, write `final_roi` and `rank`
5. Set status = 'completed'

### Edge Cases

| ID | Case | Handling |
|----|------|----------|
| EC-C1 | User joins with 0 balance | Reject: minimum balance 100 USDT to join |
| EC-C2 | Position liquidated during tournament | Normal liquidation; tournament ROI reflects the loss |
| EC-C3 | Tie in final ROI | Break by `joined_at` (earlier joiner wins) |
| EC-C4 | Tournament ends with no participants | Set status = 'completed', no rankings |

### Frontend

- `/tournaments` page: list of tournaments with status badges
- Tournament detail: mini-leaderboard, countdown timer, join button
- Trading page: show tournament badge if user is in active tournament

---

## Feature D: Social Sharing Enhancement (P3)

### User Stories

- **US-D1**: As a trader, my battle report shows "You vs OpenClaw" ROI comparison.
- **US-D2**: As a trader, I can share battle reports directly to Telegram chat.
- **US-D3**: As a trader, my battle report shows tournament rank if I'm in one.

### Technical Design

- Update `CyberPoster.tsx`: add OpenClaw ROI comparison bar
- Use `WebApp.switchInlineQuery()` for native TG sharing (detect via `isVersionAtLeast('6.9')`)
- Add tournament rank badge to poster if `tournament_id` exists on the closed trade
- Fallback: Web Share API → download PNG

### MVP Scope

- No referral system in v2.0 (defer to v2.1)
- No animated reports (defer to v2.1)

---

## Success Metrics

| Metric | Target (30 days post-launch) | Measurement |
|--------|------------------------------|-------------|
| Liquidation events/day | > 50 | `COUNT(liquidation_events)` daily |
| OpenClaw trade frequency | 6/hour (every 10 min) | Cron execution logs |
| Leaderboard view rate | > 40% of sessions | Page view analytics |
| Tournament participation | > 25% of WAU | `tournament_participants` / WAU |
| Battle report share rate | > 8% of closed trades | Share button click tracking |

---

## Phase 2.5: Architecture Hardening (Post-Review Patches)

### EC-X1: Extreme Market Conditions — Bankruptcy Protection

**Scenario:** 100x leveraged position, Binance price moves 2%+ within the 60-second liquidation scanner interval. Position blows past liquidation price into negative equity. User manually closes before scanner fires.

**Problem:** `close_trade_txn` computes `new_balance = balance + settlement`. If concurrent settlements race, the CHECK constraint `balance >= 0` aborts the entire transaction, leaving a zombie `open` trade.

**Solution (Migration 007):**
- `close_trade_txn` clamps balance to `GREATEST(0, computed_balance)` BEFORE the UPDATE
- `liquidate_trade_txn` adds belt-and-suspenders post-lock clamp
- `bankruptcy_events` audit table records every socialized loss for reconciliation
- The CHECK constraint stays as last-line defense but is never triggered by the RPC

**Invariant:** No trade can ever be stuck in `open` status due to a balance constraint violation.

### EC-X2: Large Tournament Settlement — Timeout Protection

**Scenario:** Tournament with 500+ participants and hundreds of open trades. `settle-tournament` Edge Function attempts to force-close all trades sequentially, exceeding the 60-second function timeout.

**Problem:** Function killed mid-batch. Trades left in inconsistent state. Settlement RPC never called.

**Solution:**
- Batch processing: trades processed in pages of 20 (`BATCH_SIZE`)
- Budget-aware loop: checks wall-clock time against `MAX_EXECUTION_MS = 50s` before each batch
- Idempotent state machine:
  1. Tournament transitions `active` → `settling` (distributed mutex) before any force-close
  2. If budget exhausted mid-batch, function returns. Tournament stays `settling`
  3. Next cron tick finds `settling` tournaments, resumes force-close from remaining open trades
  4. `settle_tournament_txn` only called when zero open trades remain
- Settlement RPC itself accepts `settling` as valid entry state for retry safety

**Invariant:** A tournament settlement always completes eventually, regardless of how many cron ticks it takes.

### EC-X3: AI Agent Front-Running — Timing Obfuscation

**Scenario:** Human players observe OpenClaw trades at exactly :00, :10, :20, :30 etc. They front-run by opening opposite positions seconds before the cron fires.

**Problem:** Fixed 10-minute cron schedule is fully predictable.

**Solution:**
- Random timing jitter: 0-120 second cryptographic random delay (`crypto.getRandomValues`) at the start of each cycle
- Margin jitter: position size varies randomly between 1.5%-2.5% of balance (not fixed 2%)
- Actual trade execution: cron fires at :00 but trade may happen at :00:03 to :02:00

**Invariant:** No external observer can predict when OpenClaw will act within a given 10-minute window.

---

## Migration Plan

| Migration | Description |
|-----------|-------------|
| `003_liquidation.sql` | `liquidation_events` table + `liquidate_trade_txn` RPC |
| `004_openclaw_agent.sql` | Seed OpenClaw user row + API key auth tier in RPC |
| `005_tournaments.sql` | `tournaments` + `tournament_participants` tables + `tournament_id` on trades |
| `006_tournament_rpcs.sql` | `join_tournament_txn` + `settle_tournament_txn` RPCs |
| `007_bankruptcy_protection.sql` | `bankruptcy_events` table + bankruptcy-safe `close_trade_txn` / `liquidate_trade_txn` |

---

## 2-Week Sprint Plan

### Week 1: Liquidation Scanner + AI Agent

| Day | Task |
|-----|------|
| 1-2 | Migration 003 + `liquidate_trade_txn` RPC + `scan-liquidations` Edge Function |
| 3 | Migration 004 + API key auth in `supabase-client.ts` + `generate-api-key` Edge Function |
| 4-5 | `openclaw-trade` Edge Function (momentum strategy) + OpenClaw status widget on frontend |
| 5 | Integration test: run both crons 24h on staging |

### Week 2: Tournament Mode + Social + Polish

| Day | Task |
|-----|------|
| 6-8 | Migration 005-006 + tournament Edge Functions + `/tournaments` page |
| 9-10 | CyberPoster v2 (vs OpenClaw comparison) + TG native sharing |
| 11-12 | Edge case handling + UI polish + mobile testing |
| 13-14 | Full QA on Telegram (iOS + Android) + deploy + launch first tournament |
