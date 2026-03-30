# Phase 3 Strategy: Retention & Re-engagement

> Date: 2026-03-29
> Status: Planning
> Goal: Convert pull-only usage into habitual return behavior

---

## 1. Priority Ranking (Retention Impact x Feasibility)

| Rank | Feature | Retention | Feasibility | Score | Rationale |
|------|---------|-----------|-------------|-------|-----------|
| 1 | Notification System | 5 | 4 | 20 | Directly solves the return-trigger gap. Everything else depends on this. |
| 2 | Daily Reward / Streak | 5 | 5 | 25* | Highest raw score but useless without notifications to remind users. Ships second, activates first-rank feature. |
| 3 | Achievement System | 3 | 3 | 9 | Nice depth layer but does not drive daily returns on its own. |
| 4 | Position History | 2 | 4 | 8 | Quality-of-life. Helps power users, does not move retention needle for casuals. |

*Daily Reward scores higher in isolation but has a hard dependency on notifications to actually trigger returns. Notifications are the infrastructure; streaks are the payload.

**Ship order: Notifications -> Daily Reward -> Achievements -> Position History**

---

## 2. The "Return Trigger" Gap

Phase 2 problem: rivalry and tournaments create reasons to come back, but zero mechanisms to remind users those reasons exist. The app competes against every other Telegram notification for attention and loses by default because it sends none.

**Notifications is the only feature that directly fixes this.** Streaks give users a reason to care about the notification. Achievements give them something to chase. But without the push channel, all three are passive.

The critical insight: a streak system without notifications is just a counter nobody sees. A notification system without streaks is just spam. They must ship as a pair.

---

## 3. MVP Scope Cuts

### 3A. Notification System (MVP)

**In scope:**
- TG Bot sends messages via `sendMessage` API (not inline, not web push)
- 4 notification types only:
  1. Liquidation alert ("Your BTC long just got liquidated at $XX,XXX")
  2. Tournament start/end reminder
  3. Daily streak reminder (fires once if user hasn't opened app by a set hour)
  4. AI Lobster taunt after beating user ("The Lobster crushed your position. Coming back?")
- User opt-in at first launch (single toggle: on/off)
- Server-side rate limiter (see Section 6)

**Cut from MVP:**
- Per-type notification preferences (ship in 3.1 patch)
- Rich media / inline buttons in messages
- Price alerts
- Quiet hours configuration (use sensible defaults instead)

### 3B. Daily Reward / Streak System (MVP)

**In scope:**
- Login streak counter (reset after 1 missed day)
- Fixed reward table: Day 1-6 = small coin bonus, Day 7 = larger bonus
- Single "Claim" button on home screen
- Streak count visible on profile

**Cut from MVP:**
- Escalating multipliers
- Streak freeze / protection items
- Weekly/monthly mega rewards
- Leaderboard for longest streaks

### 3C. Achievement System (MVP)

**In scope:**
- 10 achievements max, hardcoded:
  1. First Trade
  2. First Win vs Lobster
  3. Survive 3 Liquidations
  4. 7-Day Streak
  5. Win a Tournament
  6. 10x Leverage Trade
  7. 50x Leverage Trade (degenerate badge)
  8. 5 Wins vs Lobster
  9. Recover from Bankruptcy
  10. 30-Day Streak
- Badge display on profile (unlocked/locked state only)
- Toast notification on unlock

**Cut from MVP:**
- Progress bars / partial completion tracking
- Achievement points / XP system
- Achievement rarity tiers
- Social sharing of achievements

### 3D. Position History / Trade Journal (MVP)

**In scope:**
- List view of closed positions (last 50)
- Each entry: asset, direction, leverage, entry/exit price, PnL, timestamp
- Basic filter: win/loss toggle

**Cut from MVP:**
- Charts / equity curve
- Export functionality
- Notes / journaling
- Open position tracking (already exists in main UI)

---

## 4. Build Order: 1-Week Sprint Plan

**Total budget: 7 working days**

### Day 1-2: Notification Infrastructure
- TG Bot webhook setup for outbound messages
- `notification_queue` table in Supabase (user_id, type, payload, status, created_at, sent_at)
- Edge Function: `send-notification` (reads queue, calls TG Bot API, marks sent)
- Rate limiter logic (see Section 6)
- Cron trigger via pg_cron or Supabase scheduled function (every 5 min)
- User `notification_enabled` flag in profiles table

### Day 3: Notification Triggers
- Hook into existing liquidation flow -> enqueue liquidation alert
- Hook into tournament lifecycle -> enqueue start/end reminders
- AI Lobster taunt trigger -> enqueue after Lobster wins a position
- Streak reminder trigger -> scheduled check at 18:00 UTC for inactive users

### Day 4: Daily Reward / Streak System
- `user_streaks` table (user_id, current_streak, longest_streak, last_claim_date)
- Edge Function or client logic: claim reward, validate streak continuity
- Reward table config (hardcoded constants, not a DB table)
- UI: claim button on home screen, streak badge on profile

### Day 5: Achievement System
- `user_achievements` table (user_id, achievement_id, unlocked_at)
- Achievement definitions as constants (not DB-driven for MVP)
- Trigger checks: post-trade, post-liquidation, post-tournament, post-streak-claim
- UI: achievement grid on profile, unlock toast

### Day 6: Position History
- `trade_history` view or query from existing positions table (filter: closed only)
- UI: scrollable list, win/loss filter toggle
- Basic PnL coloring (green/red)

### Day 7: Integration Testing + Polish
- End-to-end notification flow test (trigger -> queue -> TG message)
- Streak edge cases (timezone boundary, double-claim prevention)
- Achievement unlock verification for all 10
- Rate limiter validation
- Deploy

---

## 5. Risk: Notification Spam Fatigue

**The biggest risk is not that notifications fail -- it's that they succeed too well and users mute the bot.**

Once a user mutes the TG bot, the entire re-engagement channel is dead. There is no "unmute reminder." This is a one-way door.

Specific risks:
1. **Liquidation storms**: High-volatility periods can trigger 5+ liquidations in minutes for leveraged users. Sending all of them will feel like spam.
2. **Tournament spam**: If tournaments run frequently, start/end notifications stack up.
3. **Lobster taunts becoming annoying**: Funny the first 3 times, irritating by the 10th.
4. **Streak reminders feeling nagging**: "You haven't logged in today" is one step from "unsubscribe."

**Mitigations:**
- Hard rate limits (Section 6)
- Aggregate liquidation alerts ("3 positions liquidated in the last hour" instead of 3 separate messages)
- Lobster taunts use a rotating pool of 20+ messages to avoid repetition
- Streak reminder tone must be playful, not guilt-driven ("The Lobster is getting comfortable without you" not "You're about to lose your streak!")
- Track mute rate as a health metric. If >5% of notified users mute within 7 days, reduce frequency immediately.

---

## 6. Notification Frequency Rules

### Hard Limits (enforced server-side, non-negotiable)

| Rule | Threshold |
|------|-----------|
| Max messages per user per hour | 2 |
| Max messages per user per day | 5 |
| Max liquidation alerts per user per hour | 1 (aggregate if multiple) |
| Max Lobster taunts per user per day | 1 |
| Max streak reminders per user per day | 1 |
| Min gap between any two messages to same user | 15 minutes |
| Quiet hours (no messages) | 00:00 - 08:00 user local time (fallback: UTC) |

### Priority Queue (when limit is hit, which message wins?)

```
Priority 1: Tournament start (time-sensitive, user opted into tournament)
Priority 2: Liquidation alert (money on the line)
Priority 3: Streak reminder (daily, predictable)
Priority 4: Lobster taunt (entertainment, most cuttable)
```

If daily cap (5) is hit, Priority 4 messages are dropped silently. Priority 3 can be dropped if 4 higher-priority messages already sent. Priority 1-2 are never dropped but still respect the hourly cap of 2.

### Monitoring KPIs

| Metric | Target | Red Line |
|--------|--------|----------|
| TG Bot block/mute rate (7-day rolling) | <3% | >5% triggers frequency review |
| Notification -> App open rate | >15% | <8% means messages are irrelevant |
| Streak reminder -> Claim conversion | >25% | <10% means wrong timing or tone |
| Messages sent per DAU per day (avg) | 1.5-2.5 | >3.5 means over-sending |

---

## Summary

Phase 3 is a retention phase. The core loop (trade, compete, lose to Lobster, try again) exists but has no external trigger. Notifications + Streaks ship as an atomic pair in Days 1-4. Achievements and History are depth features that round out the phase but are not the primary retention driver.

Ship fast, monitor mute rates, adjust frequency within the first 48 hours post-launch.
