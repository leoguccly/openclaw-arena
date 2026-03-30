"use client";

import { useMemo } from "react";

// ============================================================
// Sparkline — Zero-dependency SVG live price chart
// ============================================================
// Pure SVG <polyline> + <linearGradient> area fill.
// No Chart.js, no ECharts, no external libraries.
//
// Performance:
// - useMemo for point calculation (only recalcs when data changes)
// - SVG is GPU-accelerated on all modern browsers
// - CSS transition on the polyline for smooth visual updates
// ============================================================

interface SparklineProps {
  /** Array of price values (most recent last). Min 2 points to draw. */
  data: number[];
  /** SVG viewport width */
  width?: number;
  /** SVG viewport height */
  height?: number;
  /** Line color in hex */
  color?: string;
  /** Whether to show the area gradient fill */
  showArea?: boolean;
}

export default function Sparkline({
  data,
  width = 320,
  height = 60,
  color,
  showArea = true,
}: SparklineProps) {
  // Auto-detect color: green if latest > oldest, orange if down
  const resolvedColor = useMemo(() => {
    if (color) return color;
    if (data.length < 2) return "#00FF88";
    return data[data.length - 1] >= data[0] ? "#00FF88" : "#FF6B35";
  }, [data, color]);

  // Compute SVG points from data
  const { points, areaPoints } = useMemo(() => {
    if (data.length < 2) return { points: "", areaPoints: "" };

    const min = Math.min(...data);
    const max = Math.max(...data);
    const range = max - min || 1; // avoid division by zero

    // Padding: leave 2px top/bottom so the line doesn't clip
    const padY = 4;
    const drawHeight = height - padY * 2;

    const pts = data.map((val, i) => {
      const x = (i / (data.length - 1)) * width;
      // Invert Y because SVG Y-axis goes downward
      const y = padY + drawHeight - ((val - min) / range) * drawHeight;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });

    const linePoints = pts.join(" ");

    // Area: same points + close path along bottom edge
    const areaPath = `${linePoints} ${width},${height} 0,${height}`;

    return { points: linePoints, areaPoints: areaPath };
  }, [data, width, height]);

  if (data.length < 2) return null;

  // Unique gradient ID per instance (in case multiple sparklines exist)
  const gradientId = `sparkline-grad-${resolvedColor.replace("#", "")}`;

  return (
    <svg
      width="100%"
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="none"
      className="overflow-visible"
    >
      <defs>
        {/* Vertical gradient: neon color at top → transparent at bottom */}
        <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={resolvedColor} stopOpacity={0.25} />
          <stop offset="100%" stopColor={resolvedColor} stopOpacity={0} />
        </linearGradient>
      </defs>

      {/* Area fill — subtle gradient beneath the line */}
      {showArea && (
        <polygon
          points={areaPoints}
          fill={`url(#${gradientId})`}
          style={{ transition: "all 0.4s ease-out" }}
        />
      )}

      {/* The sparkline itself */}
      <polyline
        points={points}
        fill="none"
        stroke={resolvedColor}
        strokeWidth={1.5}
        strokeLinecap="round"
        strokeLinejoin="round"
        style={{
          transition: "all 0.4s ease-out",
          filter: `drop-shadow(0 0 6px ${resolvedColor}60)`,
        }}
      />

      {/* Current price dot (last point) — pulsing neon */}
      {data.length >= 2 && (() => {
        const min = Math.min(...data);
        const max = Math.max(...data);
        const range = max - min || 1;
        const padY = 4;
        const drawHeight = height - padY * 2;
        const lastVal = data[data.length - 1];
        const cx = width;
        const cy = padY + drawHeight - ((lastVal - min) / range) * drawHeight;
        return (
          <>
            {/* Outer glow */}
            <circle cx={cx} cy={cy} r={4} fill={resolvedColor} opacity={0.3}>
              <animate
                attributeName="r"
                values="4;6;4"
                dur="2s"
                repeatCount="indefinite"
              />
            </circle>
            {/* Inner dot */}
            <circle cx={cx} cy={cy} r={2} fill={resolvedColor} />
          </>
        );
      })()}
    </svg>
  );
}
