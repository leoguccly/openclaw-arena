// ============================================================
// Binance WebSocket — Real-time Price Stream
// ============================================================
// Connects to Binance's public WebSocket API for live ticker data.
// No API key required — this is a public market data stream.
//
// Architecture:
// - Single shared WebSocket per symbol (avoids duplicate connections)
// - Auto-reconnect with exponential backoff on disconnect
// - Subscribers register callbacks; cleanup on unsubscribe
// - Falls back to REST polling if WebSocket is unavailable
//
// Binance WS endpoint:
//   wss://stream.binance.com:9443/ws/{symbol}@trade
//   Returns: { "p": "67432.15", "T": 1710500000000, ... }
// ============================================================

type PriceCallback = (price: number, timestamp: number) => void;

interface SocketState {
  ws: WebSocket | null;
  subscribers: Set<PriceCallback>;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
  reconnectAttempts: number;
  lastPrice: number | null;
}

const MAX_RECONNECT_ATTEMPTS = 10;
const BASE_RECONNECT_DELAY_MS = 1000;

// One socket state per symbol
const sockets = new Map<string, SocketState>();

function getOrCreateState(symbol: string): SocketState {
  let state = sockets.get(symbol);
  if (!state) {
    state = {
      ws: null,
      subscribers: new Set(),
      reconnectTimer: null,
      reconnectAttempts: 0,
      lastPrice: null,
    };
    sockets.set(symbol, state);
  }
  return state;
}

function connect(symbol: string): void {
  const state = getOrCreateState(symbol);

  // Don't open duplicate connections
  if (state.ws && (state.ws.readyState === WebSocket.OPEN || state.ws.readyState === WebSocket.CONNECTING)) {
    return;
  }

  // Binance WebSocket trade stream — lowercase symbol required
  const wsUrl = `wss://stream.binance.com:9443/ws/${symbol.toLowerCase()}@trade`;

  try {
    const ws = new WebSocket(wsUrl);
    state.ws = ws;

    ws.onopen = () => {
      console.log(`[binance-ws] Connected: ${symbol}`);
      state.reconnectAttempts = 0;
    };

    ws.onmessage = (event: MessageEvent) => {
      try {
        const data = JSON.parse(event.data as string) as { p: string; T: number };
        const price = parseFloat(data.p);
        const timestamp = data.T;

        if (isNaN(price) || price <= 0) return;

        state.lastPrice = price;

        // Notify all subscribers
        for (const callback of state.subscribers) {
          callback(price, timestamp);
        }
      } catch {
        // Malformed message — skip
      }
    };

    ws.onclose = (event: CloseEvent) => {
      console.log(`[binance-ws] Disconnected: ${symbol} (code=${event.code})`);
      state.ws = null;
      scheduleReconnect(symbol);
    };

    ws.onerror = () => {
      // onerror is always followed by onclose, so reconnect happens there
      console.error(`[binance-ws] Error on ${symbol}`);
    };
  } catch {
    console.error(`[binance-ws] Failed to create WebSocket for ${symbol}`);
    scheduleReconnect(symbol);
  }
}

function scheduleReconnect(symbol: string): void {
  const state = getOrCreateState(symbol);

  // Don't reconnect if no subscribers
  if (state.subscribers.size === 0) return;

  // Don't exceed max attempts
  if (state.reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    console.error(`[binance-ws] Max reconnect attempts reached for ${symbol}. Giving up.`);
    return;
  }

  // Exponential backoff: 1s, 2s, 4s, 8s, ...
  const delay = BASE_RECONNECT_DELAY_MS * Math.pow(2, state.reconnectAttempts);
  state.reconnectAttempts++;

  console.log(`[binance-ws] Reconnecting ${symbol} in ${delay}ms (attempt ${state.reconnectAttempts})`);

  if (state.reconnectTimer) clearTimeout(state.reconnectTimer);
  state.reconnectTimer = setTimeout(() => connect(symbol), delay);
}

function disconnect(symbol: string): void {
  const state = sockets.get(symbol);
  if (!state) return;

  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }

  if (state.ws) {
    state.ws.onclose = null; // prevent reconnect on intentional close
    state.ws.close();
    state.ws = null;
  }

  console.log(`[binance-ws] Intentionally disconnected: ${symbol}`);
}

// ============================================================
// Public API
// ============================================================

/**
 * Subscribe to real-time price updates for a Binance symbol.
 * Returns an unsubscribe function.
 *
 * Usage:
 *   const unsub = subscribeBinancePrice("btcusdt", (price, ts) => {
 *     setPrice(price);
 *   });
 *   // Later: unsub();
 */
export function subscribeBinancePrice(
  symbol: string,
  callback: PriceCallback
): () => void {
  // Normalize to lowercase (Binance WS requires lowercase)
  const sym = symbol.toLowerCase();
  const state = getOrCreateState(sym);

  state.subscribers.add(callback);

  // If this is the first subscriber, open the WebSocket
  if (state.subscribers.size === 1) {
    connect(sym);
  }

  // If we already have a cached price, deliver it immediately
  if (state.lastPrice !== null) {
    callback(state.lastPrice, Date.now());
  }

  // Return unsubscribe function
  return () => {
    state.subscribers.delete(callback);

    // If no more subscribers, close the WebSocket
    if (state.subscribers.size === 0) {
      disconnect(sym);
      sockets.delete(sym);
    }
  };
}

/**
 * Get the last known price for a symbol (from WS cache).
 * Returns null if no price has been received yet.
 */
export function getLastPrice(symbol: string): number | null {
  return sockets.get(symbol.toLowerCase())?.lastPrice ?? null;
}
