/**
 * Single source of truth for all trade math.
 * Every Edge Function MUST import from here — never duplicate locally.
 */

export type Direction = "long" | "short";

/**
 * Liquidation price: the price at which the entire margin is lost.
 *
 * Long:  entry * (1 - 1/leverage)
 * Short: entry * (1 + 1/leverage)
 */
export function computeLiquidationPrice(
  entryPrice: number,
  direction: Direction,
  leverage: number
): number {
  if (direction === "long") {
    return entryPrice * (1 - 1 / leverage);
  }
  return entryPrice * (1 + 1 / leverage);
}

/**
 * Notional quantity of base currency controlled by this position.
 * quantity = (margin * leverage) / entry_price
 */
export function computeQuantity(
  margin: number,
  leverage: number,
  entryPrice: number
): number {
  return (margin * leverage) / entryPrice;
}

/**
 * Computes the realised PnL for a closed position.
 *
 * Long:  quantity * (exit_price - entry_price)
 * Short: quantity * (entry_price - exit_price)
 *
 * A profitable long position exits above entry; a profitable short exits below.
 */
export function computePnl(
  direction: Direction,
  quantity: number,
  entryPrice: number,
  exitPrice: number
): number {
  if (direction === "long") {
    return quantity * (exitPrice - entryPrice);
  }
  return quantity * (entryPrice - exitPrice);
}

/**
 * Settlement amount returned to the user's balance.
 * Clamped to >= 0: you cannot lose more than your margin.
 *
 * settlement = margin + pnl  (clamped at 0)
 */
export function computeSettlement(margin: number, pnl: number): number {
  return Math.max(0, margin + pnl);
}

/**
 * Unrealised PnL for an open position at the current market price.
 *
 * Long:  quantity * (current_price - entry_price)
 * Short: quantity * (entry_price - current_price)
 */
export function computeUnrealisedPnl(
  direction: Direction,
  quantity: number,
  entryPrice: number,
  currentPrice: number
): number {
  if (direction === "long") {
    return quantity * (currentPrice - entryPrice);
  }
  return quantity * (entryPrice - currentPrice);
}
