import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        // Cyberpunk arena palette — extracted from reference dashboard
        arena: {
          bg: "#0A0A0B",        // near-black background
          card: "#141416",      // card surface
          "card-hover": "#1A1A1E", // card hover state
          border: "#2A2A2E",    // subtle borders
        },
        neon: {
          green: "#00FF88",     // 暴富绿 — profit / long / bullish
          "green-dim": "#00CC6A", // muted green for secondary elements
          orange: "#FF6B35",    // 做空亏损橙 — loss / short / bearish
          "orange-dim": "#CC5529", // muted orange
        },
      },
      fontFamily: {
        mono: ["'Space Grotesk'", "ui-monospace", "SFMono-Regular", "monospace"],
      },
      boxShadow: {
        "glow-green": "0 0 20px rgba(0, 255, 136, 0.3), 0 0 60px rgba(0, 255, 136, 0.1)",
        "glow-green-intense": "0 0 30px rgba(0, 255, 136, 0.5), 0 0 80px rgba(0, 255, 136, 0.2)",
        "glow-orange": "0 0 20px rgba(255, 107, 53, 0.3), 0 0 60px rgba(255, 107, 53, 0.1)",
        "glow-orange-intense": "0 0 30px rgba(255, 107, 53, 0.5), 0 0 80px rgba(255, 107, 53, 0.2)",
      },
      animation: {
        "pulse-glow": "pulse-glow 2s ease-in-out infinite",
        "price-flash": "price-flash 0.3s ease-out",
      },
      keyframes: {
        "pulse-glow": {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.7" },
        },
        "price-flash": {
          "0%": { transform: "scale(1.05)", opacity: "0.8" },
          "100%": { transform: "scale(1)", opacity: "1" },
        },
      },
    },
  },
  plugins: [],
};

export default config;
