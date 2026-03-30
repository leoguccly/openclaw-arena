import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Alpha Arena",
  description: "Human vs AI — Crypto Trading Arena",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  // viewport-fit=cover is CRITICAL for TG Web App SafeArea on iOS.
  // Without it, env(safe-area-inset-*) in globals.css returns 0px,
  // and bottom buttons get hidden behind the iOS home indicator.
  viewportFit: "cover",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <head>
        {/* TG Web App SDK — must load before React hydration */}
        <script src="https://telegram.org/js/telegram-web-app.js" defer />
        {/* Space Grotesk for the cyberpunk mono feel */}
        <link
          href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&display=swap"
          rel="stylesheet"
        />
      </head>
      <body className="min-h-screen">
        {children}
      </body>
    </html>
  );
}
