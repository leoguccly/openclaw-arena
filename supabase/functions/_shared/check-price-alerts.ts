// ---------------------------------------------------------------------------
// Shared price alert checker — extracted from manage-price-alerts to avoid
// serve() conflicts when imported by scan-liquidations.
// ---------------------------------------------------------------------------

import { getSupabaseAdmin } from "./supabase-client.ts";

type AlertDirection = "above" | "below";

interface PriceAlertRow {
  id: string;
  user_id: string;
  symbol: string;
  direction: AlertDirection;
  target_price: number;
  is_active: boolean;
  created_at: string;
  triggered_at: string | null;
}

/**
 * Scans active price alerts for `symbol` that are breached by `currentPrice`,
 * deactivates each one with an optimistic lock, then enqueues a
 * `send_notification` event in `event_outbox` for every triggered alert.
 *
 * No Telegram API calls are made inline.
 */
export async function checkPriceAlerts(
  supabase: ReturnType<typeof getSupabaseAdmin>,
  symbol: string,
  currentPrice: number
): Promise<{ triggered: number; errors: string[] }> {
  const errors: string[] = [];
  let triggered = 0;

  const [aboveResult, belowResult] = await Promise.all([
    supabase
      .from("price_alerts")
      .select("id, user_id, symbol, direction, target_price")
      .eq("symbol", symbol)
      .eq("direction", "above")
      .eq("is_active", true)
      .lte("target_price", currentPrice),
    supabase
      .from("price_alerts")
      .select("id, user_id, symbol, direction, target_price")
      .eq("symbol", symbol)
      .eq("direction", "below")
      .eq("is_active", true)
      .gte("target_price", currentPrice),
  ]);

  if (aboveResult.error) {
    errors.push(`Failed to fetch "above" price_alerts for ${symbol}: ${aboveResult.error.message}`);
  }
  if (belowResult.error) {
    errors.push(`Failed to fetch "below" price_alerts for ${symbol}: ${belowResult.error.message}`);
  }
  if (aboveResult.error && belowResult.error) {
    return { triggered, errors };
  }

  const breachedAlerts: PriceAlertRow[] = [
    ...((aboveResult.data ?? []) as PriceAlertRow[]),
    ...((belowResult.data ?? []) as PriceAlertRow[]),
  ];

  if (breachedAlerts.length === 0) {
    return { triggered, errors };
  }

  console.log(
    `[check-price-alerts] ${breachedAlerts.length} breached alert(s) for ${symbol} @ ${currentPrice}`
  );

  const triggeredAt = new Date().toISOString();

  for (const alert of breachedAlerts) {
    const targetPrice = parseFloat(String(alert.target_price));

    const { data: updateData, error: updateError } = await supabase
      .from("price_alerts")
      .update({ is_active: false, triggered_at: triggeredAt })
      .eq("id", alert.id)
      .eq("is_active", true)
      .select("id")
      .maybeSingle();

    if (updateError) {
      errors.push(`Failed to deactivate alert ${alert.id}: ${updateError.message}`);
      continue;
    }

    if (!updateData) {
      continue; // concurrent execution already deactivated it
    }

    const { data: userData } = await supabase
      .from("users")
      .select("telegram_chat_id, timezone_offset, display_name")
      .eq("id", alert.user_id)
      .maybeSingle();

    if (!userData?.telegram_chat_id) {
      triggered++;
      continue;
    }

    const directionEmoji = alert.direction === "above" ? "📈" : "📉";
    const directionLabel = alert.direction === "above" ? "rose above" : "fell below";

    const message =
      `${directionEmoji} <b>Price Alert Triggered</b>\n\n` +
      `Hey ${userData.display_name ?? "Trader"}!\n\n` +
      `<b>${symbol}</b> has ${directionLabel} your target price of ` +
      `<b>${targetPrice.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDT</b>.\n\n` +
      `Current price: <b>${currentPrice.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDT</b>`;

    const { error: outboxError } = await supabase
      .from("event_outbox")
      .insert({
        event_type: "send_notification",
        payload: {
          user_id: alert.user_id,
          chat_id: userData.telegram_chat_id,
          notification_type: "price_alert",
          message,
          timezone_offset: (userData as Record<string, unknown>).timezone_offset ?? 0,
          alert_id: alert.id,
          symbol,
          direction: alert.direction,
          target_price: targetPrice,
          current_price: currentPrice,
        },
      });

    if (outboxError) {
      errors.push(`Failed to insert outbox for alert ${alert.id}: ${outboxError.message}`);
      continue;
    }

    triggered++;
  }

  return { triggered, errors };
}
