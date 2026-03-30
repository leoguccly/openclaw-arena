# Phase 4 Strategy: Growth Engine

> Date: 2026-03-29
> Status: Proposed
> Sprint Window: 1 week

---

## 1. Priority Ranking (Growth Impact x Feasibility)

| Rank | Feature | Growth | Feasibility | Score | Ship in Sprint? |
|------|---------|--------|-------------|-------|-----------------|
| 1 | Referral System | 5 | 4 | 20 | Yes |
| 2 | Seasonal Leaderboard Reset | 4 | 5 | 20 | Yes |
| 3 | Multiple AI Personalities | 3 | 4 | 12 | Yes |
| 4 | Price Alerts | 2 | 4 | 8 | No |
| 5 | Advanced Analytics | 2 | 2 | 4 | No |

---

## 2. Why Referrals MUST Be First

No debate. Referrals are non-negotiable as the P0.

**The problem is existential.** You have retention mechanics (streaks, achievements), you have engagement depth (AI agent, tournaments, journal). What you do NOT have is a compounding acquisition channel. Every user today comes from a direct bot link. That is linear growth. Linear growth dies.

Referrals turn every retained user into an acquisition channel. The math:

- Current: 1 user acquired = 1 user. Period.
- With referrals: 1 user acquired = 1 user + (k * 1) where k is viral coefficient.
- If k > 0.3 in a TG Web App context, you are outperforming most crypto products.

Referrals also compound with everything already built:

- Streaks give users a reason to stay, which gives them time to refer.
- Tournaments give users a reason to invite friends (play against them).
- Battle reports give users shareable content, but no incentive to share. Referrals add the incentive.

Building anything else first is optimizing a bucket with no faucet.

---

## 3. MVP Scope Cuts

### Referral System (3 days)

**Ship:**
- Unique referral link per user (deep link into TG bot)
- Referral tracking (who referred whom, stored in DB)
- Dual reward: referrer gets bonus starting capital in next tournament; referred user gets same
- Referral count visible on profile
- "Invite Friends" button on main screen and post-tournament results

**Cut from MVP:**
- Tiered referral rewards (v2)
- Referral leaderboard (v2)
- Multi-level / pyramid referral tracking (never)
- Custom referral messages (v2)
- Referral analytics dashboard (v2)

### Seasonal Leaderboard Reset (2 days)

**Ship:**
- Weekly season cycle (resets every Monday 00:00 UTC)
- End-of-season snapshot: top 10 preserved in "Hall of Fame" table
- Season badge awarded to top 3 (displays on profile)
- Global leaderboard shows current season only
- "Last Season Results" view

**Cut from MVP:**
- Monthly/quarterly seasons (just do weekly)
- Season-specific rule modifiers (v2)
- Season pass / premium season rewards (v2)
- Historical season browser (v2)

### Multiple AI Personalities (2 days)

**Ship:**
- 3 personalities total: current default + 2 new
  - "Degen Dave" -- aggressive, meme-heavy, high-risk calls
  - "Careful Karen" -- conservative, risk-averse, educational
- Personality selection before starting a session
- Different system prompts per personality (no new model, just prompt engineering)
- Personality icon/name shown in chat

**Cut from MVP:**
- Unlockable personalities gated behind achievements (v2)
- Personality-specific voice/tone in notifications (v2)
- User-created personalities (never for MVP, maybe v3)
- Per-personality win rate stats (v2)

---

## 4. What to Explicitly CUT from Phase 4

### Price Alerts -- CUT

Why: Utility feature that helps individual users but generates zero viral loops. It is a retention micro-feature, and you already have streaks + achievements doing that job. Price alerts also pull the product toward "tool" positioning when the core value prop is "game." Ship in Phase 5 when you need to deepen daily utility.

### Advanced Analytics -- CUT

Why: Highest effort, lowest growth impact. Power users who want analytics are already retained. You would be spending a week building for your top 5% instead of growing the other 95%. Analytics is a Phase 6 feature when you have enough users that power-user monetization matters.

---

## 5. One-Week Sprint Plan

### Day 1 (Monday): Referral -- Backend

- DB schema: `referrals` table (referrer_id, referred_id, created_at, reward_granted)
- Generate unique referral codes per user
- TG deep link integration (bot processes referral code on /start)
- Referral validation logic (no self-referral, no duplicate referral)

### Day 2 (Tuesday): Referral -- Frontend + Rewards

- "Invite Friends" UI button (main screen, post-tournament)
- Share referral link via TG native share
- Reward granting logic: bonus capital for both parties on next tournament
- Referral count on profile page

### Day 3 (Wednesday): Referral -- Polish + Edge Cases

- Rate limiting on referral creation (max 50 referrals per user per day)
- Fraud detection: flag accounts that only refer but never trade
- Test full flow: link generation -> share -> new user joins -> both rewarded
- Referral confirmation notification to referrer

### Day 4 (Thursday): Seasonal Leaderboard -- Full Build

- Season model: weekly cycle, auto-reset via scheduled function
- End-of-season snapshot job (cron or Supabase pg_cron)
- Hall of Fame table + top-3 badge assignment
- UI: current season leaderboard + "Last Season" tab

### Day 5 (Friday): AI Personalities -- Full Build

- Define 3 personality system prompts
- Personality selection UI before session start
- Wire selected personality to AI agent prompt
- Display personality name/icon in chat interface

### Day 6 (Saturday): Integration + QA

- Full integration testing across all 3 features
- Edge case testing: referral abuse, season boundary, personality switching mid-session
- Performance check on leaderboard queries with season filter
- Fix bugs

### Day 7 (Sunday): Ship

- Deploy all 3 features behind feature flags
- Staged rollout: 10% -> 50% -> 100%
- Monitor referral creation rate, season leaderboard load, personality selection distribution
- Write announcement copy for TG channel

---

## 6. Referral Abuse Risk

### Biggest Vector: Sybil Farming

A single person creates multiple TG accounts, refers themselves repeatedly, and harvests bonus capital across accounts to dominate tournaments.

**Why this is dangerous:** TG accounts are cheap to create. Crypto-native users are experienced at sybil attacks. Bonus capital in tournaments is a direct competitive advantage that motivates abuse.

### Mitigation (Ship in MVP)

1. **Minimum activity threshold.** Referred user must complete at least 3 trades before referral reward is granted to either party. This makes farming expensive in time.

2. **Rate limit.** Cap referral rewards at 10 per user per week. The 11th referral is tracked but not rewarded. This bounds the maximum advantage.

3. **Delayed reward.** Bonus capital is granted in the NEXT tournament, not the current one. This introduces a time delay that reduces farming ROI.

4. **Flagging heuristic.** If a referred account shares device fingerprint, IP range, or TG account creation date cluster with the referrer, flag for manual review. Do not auto-ban -- false positives damage trust. Just withhold reward pending review.

5. **Decay curve.** First 5 referrals give full reward. Referrals 6-10 give 50%. Beyond 10 per week, no reward. Resets weekly. This makes the first few referrals valuable (which is where real referrals live) and farming progressively worthless.

### Mitigation (Post-MVP, Phase 4.5)

- Graph analysis: detect referral rings (A refers B, B refers C, C refers A)
- Require referred user to survive at least 1 full tournament before reward
- Tie referral rewards to referred user's ongoing activity (referrer gets drip rewards as referred user stays active)

---

## Summary

Phase 4 ships 3 features in 7 days: **Referrals, Seasonal Leaderboard, AI Personalities.**

Referrals solve the acquisition gap. Seasons create urgency and re-engagement hooks. AI personalities add depth and shareability ("I just got wrecked by Degen Dave" is inherently more shareable than "I lost to the AI").

Price Alerts and Advanced Analytics are cut. They solve problems you do not have yet.

The single metric to watch post-launch: **referral conversion rate** (referred link clicks -> new users who complete 3+ trades). Target: 15%+ within first 2 weeks.
