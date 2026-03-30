/** @type {import('next').NextConfig} */
const nextConfig = {
  // Telegram Web App runs inside an iframe — allow it
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          {
            key: "X-Frame-Options",
            value: "ALLOWALL",
          },
        ],
      },
    ];
  },
};

module.exports = nextConfig;
