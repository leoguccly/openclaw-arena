/**
 * Single source of truth for all trading symbol mappings.
 * Every Edge Function MUST import from here — never hardcode locally.
 */

/** Display format used by frontend and DB */
export const TRADING_SYMBOLS = ["BTC/USDT", "ETH/USDT"] as const;
export type TradingSymbol = typeof TRADING_SYMBOLS[number];

/** Maps display notation → Binance ticker notation */
export const SYMBOL_TO_BINANCE: Record<string, string> = {
  "BTC/USDT": "BTCUSDT",
  "ETH/USDT": "ETHUSDT",
};

/** Reverse map: Binance → display */
export const BINANCE_TO_SYMBOL: Record<string, string> = {
  "BTCUSDT": "BTC/USDT",
  "ETHUSDT": "ETH/USDT",
};

export function toBinanceSymbol(displaySymbol: string): string | null {
  return SYMBOL_TO_BINANCE[displaySymbol] ?? null;
}
