// ============================================================
// Alpha Arena — Shared TypeScript Types (Frontend)
// ============================================================

export interface ArenaUser {
  id: string;
  tg_id: number;
  display_name: string;
  username: string;
  is_human: boolean;
  balance: number;
  roi: number;
}

export interface Trade {
  id: string;
  user_id: string;
  symbol: string;
  direction: "long" | "short";
  leverage: number;
  margin: number;
  entry_price: number;
  exit_price: number | null;
  liquidation_price: number;
  quantity: number;
  realised_pnl: number | null;
  status: "open" | "closed" | "liquidated";
  created_at: string;
  updated_at: string;
}

export interface LeaderboardEntry {
  display_name: string;
  username: string;
  is_human: boolean;
  roi: number;
  rank: number;
}

export interface PriceData {
  symbol: string;
  price: number;
  timestamp: string;
  source: "binance";
}

export interface TradeRequest {
  symbol: string;
  direction: "long" | "short";
  leverage: number;
  margin: number;
}

export interface CloseTradeRequest {
  trade_id: string;
}

export interface Tournament {
  id: string;
  name: string;
  description: string;
  start_at: string;
  end_at: string;
  status: "upcoming" | "active" | "settling" | "completed";
  max_participants: number;
  min_balance: number;
}

export interface TournamentParticipant {
  id: string;
  tournament_id: string;
  user_id: string;
  entry_balance: number;
  final_roi: number | null;
  rank: number | null;
  joined_at: string;
}

export interface TournamentLeaderboardEntry {
  tournament_id: string;
  display_name: string;
  username: string;
  is_human: boolean;
  entry_balance: number;
  final_roi: number | null;
  rank: number | null;
  joined_at: string;
}

export interface LiquidationEvent {
  id: string;
  trade_id: string;
  user_id: string;
  symbol: string;
  liquidation_price: number;
  market_price: number;
  margin: number;
  created_at: string;
}

export interface OpenClawStatus {
  display_name: string;
  roi: number;
  current_trade: {
    symbol: string;
    direction: "long" | "short";
    leverage: number;
    entry_price: number;
  } | null;
}

export interface DailyClaimResult {
  already_claimed: boolean;
  streak: number;
  bonus_amount: number;
  new_balance: number;
}

export interface StreakStatus {
  streak: number;
  last_claim_date: string | null;
  claimed_today: boolean;
  next_bonus: number;
}

export interface TradeHistoryItem {
  id: string;
  symbol: string;
  direction: "long" | "short";
  leverage: number;
  margin: number;
  entry_price: number;
  exit_price: number | null;
  realised_pnl: number | null;
  status: "open" | "closed" | "liquidated";
  tournament_id: string | null;
  tournament_name: string | null;
  created_at: string;
  closed_at: string | null;
}

export interface AggregateStats {
  total_closed: number;
  win_rate: number | null;
  cumulative_pnl: number | null;
  best_trade_pnl: number | null;
  worst_trade_pnl: number | null;
}

export interface Achievement {
  id: string;
  name: string;
  description: string;
  icon_key: string;
  required_count: number;
  is_progress_tracked: boolean;
  earned_at?: string | null;
  current_count?: number;
}

export interface ReferralInfo {
  referral_code: string;
  referral_link: string;
  referees: ReferralReferee[];
  total_bonus_earned: number;
}

export interface ReferralReferee {
  display_name: string;
  username: string;
  joined_at: string;
  bonus_paid_at: string | null;
}

export interface PriceAlert {
  id: string;
  symbol: string;
  direction: 'above' | 'below';
  target_price: number;
  is_active: boolean;
  triggered_at: string | null;
  created_at: string;
}
