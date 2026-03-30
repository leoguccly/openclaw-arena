// ============================================================
// Telegram Web App — Silent Auth & SDK Initialization
// ============================================================
// This module handles:
// 1. Reading initDataUnsafe from the TG Web App SDK
// 2. Extracting user identity (tg_id, username, first_name)
// 3. Providing auth headers for Edge Function calls
//
// SECURITY: initDataUnsafe is named "unsafe" because it has NOT been
// server-side validated. The actual authentication happens in the Edge
// Function via Supabase Auth JWT. The TG data is used for display and
// initial session bootstrapping only.
// ============================================================

// ── Dev mode: when running in browser (not inside TG), use a mock user ──
// This allows the PO to test the full UI without deploying to Telegram.
// Controlled by NEXT_PUBLIC_DEV_MODE=true in .env.local
const IS_DEV_MODE =
  typeof window !== "undefined" &&
  (process.env.NEXT_PUBLIC_DEV_MODE === "true" || !window.Telegram?.WebApp);

const MOCK_TG_USER: TelegramUser = {
  id: 999999999,
  first_name: "PO_Test",
  username: "po_test_user",
  language_code: "zh",
};

export interface TelegramUser {
  id: number;
  first_name: string;
  last_name?: string;
  username?: string;
  language_code?: string;
  is_premium?: boolean;
}

export interface TelegramWebApp {
  initData: string;
  initDataUnsafe: {
    query_id?: string;
    user?: TelegramUser;
    auth_date?: number;
    hash?: string;
    start_param?: string;
  };
  version: string;
  platform: string;
  colorScheme: "light" | "dark";
  isExpanded: boolean;
  viewportHeight: number;
  viewportStableHeight: number;
  ready: () => void;
  expand: () => void;
  close: () => void;
  MainButton: {
    text: string;
    color: string;
    textColor: string;
    isVisible: boolean;
    isActive: boolean;
    show: () => void;
    hide: () => void;
    onClick: (callback: () => void) => void;
  };
  BackButton: {
    isVisible: boolean;
    show: () => void;
    hide: () => void;
    onClick: (callback: () => void) => void;
  };
  HapticFeedback: {
    impactOccurred: (style: "light" | "medium" | "heavy" | "rigid" | "soft") => void;
    notificationOccurred: (type: "error" | "success" | "warning") => void;
  };
  setHeaderColor: (color: string) => void;
  setBackgroundColor: (color: string) => void;
  isVersionAtLeast: (version: string) => boolean;
  switchInlineQuery: (query: string, chatTypes?: string[]) => void;
  openTelegramLink: (url: string) => void;
}

declare global {
  interface Window {
    Telegram?: {
      WebApp: TelegramWebApp;
    };
  }
}

/**
 * Returns the TG Web App instance, or null if not running inside Telegram.
 */
export function getTelegramWebApp(): TelegramWebApp | null {
  if (typeof window === "undefined") return null;
  return window.Telegram?.WebApp ?? null;
}

/**
 * Returns the current TG user from initDataUnsafe, or mock user in dev mode.
 */
export function getTelegramUser(): TelegramUser | null {
  const webapp = getTelegramWebApp();
  const realUser = webapp?.initDataUnsafe?.user ?? null;

  if (realUser) return realUser;

  // Dev mode fallback — return mock user so UI works in browser
  if (IS_DEV_MODE) {
    console.log("[tg-auth] Dev mode: using mock TG user");
    return MOCK_TG_USER;
  }

  return null;
}

/**
 * Initializes the TG Web App SDK:
 * - Signals readiness to Telegram
 * - Expands to full viewport
 * - Sets dark theme header/background
 * In dev mode: returns null but getTelegramUser() still returns mock data.
 */
export function initTelegramWebApp(): TelegramWebApp | null {
  if (IS_DEV_MODE) {
    console.log("[tg-auth] Dev mode: TG Web App SDK not available, using mock identity");
    return null;
  }

  const webapp = getTelegramWebApp();
  if (!webapp) return null;

  // Signal to Telegram that the app is ready
  webapp.ready();

  // Expand to full screen (removes half-sheet mode)
  webapp.expand();

  // Force dark theme to match our cyberpunk UI
  try {
    webapp.setHeaderColor("#0A0A0B");
    webapp.setBackgroundColor("#0A0A0B");
  } catch {
    // Some older TG clients don't support setHeaderColor
  }

  return webapp;
}

/**
 * Generates auth headers for Edge Function calls.
 * Sends x-user-id for the Flutter SDK workaround path,
 * plus the Supabase JWT if available.
 */
export function getAuthHeaders(accessToken?: string): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  const user = getTelegramUser();
  if (user) {
    headers["x-user-id"] = String(user.id);
  }

  if (accessToken) {
    headers["Authorization"] = `Bearer ${accessToken}`;
  }

  return headers;
}
