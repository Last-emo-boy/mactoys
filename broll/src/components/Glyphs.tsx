// Menu bar template glyphs, drawn in the spirit of the SF Symbols the app and macOS use there
// (puzzlepiece.extension.fill for MacToys, cup.and.saucer.fill for Awake, sun.max for Power Display).

import React from "react";

type G = React.FC<{ size?: number; color?: string }>;

const Svg: React.FC<{ size: number; children: React.ReactNode; vb?: string }> = ({ size, children, vb = "0 0 20 20" }) => (
  <svg width={size} height={size} viewBox={vb} style={{ display: "block", overflow: "visible" }}>
    {children}
  </svg>
);

export const PuzzleGlyph: G = ({ size = 18, color = "#fff" }) => (
  <Svg size={size}>
    <path
      fill={color}
      d="M5.2 6.2h2.4a2.35 2.35 0 1 1 4.6 0h2.4a1.6 1.6 0 0 1 1.6 1.6v2.2a2.35 2.35 0 1 1 0 4.6v1.6a1.6 1.6 0 0 1-1.6 1.6H5.2a1.6 1.6 0 0 1-1.6-1.6V7.8a1.6 1.6 0 0 1 1.6-1.6z"
    />
  </Svg>
);

export const CupGlyph: G = ({ size = 18, color = "#fff" }) => (
  <Svg size={size}>
    <path fill={color} d="M3.6 6.4h10.2v3.6a5.1 5.1 0 0 1-10.2 0z" />
    <path fill="none" stroke={color} strokeWidth="1.5" d="M13.6 7.6h1.2a1.9 1.9 0 0 1 0 3.8h-1.6" />
    <ellipse cx="8.7" cy="16.3" rx="7.1" ry="1.55" fill={color} />
  </Svg>
);

export const SunGlyph: G = ({ size = 18, color = "#fff" }) => (
  <Svg size={size}>
    <circle cx="10" cy="10" r="3.3" fill="none" stroke={color} strokeWidth="1.5" />
    {Array.from({ length: 8 }, (_, i) => {
      const a = (i * Math.PI) / 4;
      return (
        <line
          key={i}
          x1={10 + Math.cos(a) * 5.6}
          y1={10 + Math.sin(a) * 5.6}
          x2={10 + Math.cos(a) * 7.8}
          y2={10 + Math.sin(a) * 7.8}
          stroke={color}
          strokeWidth="1.5"
          strokeLinecap="round"
        />
      );
    })}
  </Svg>
);

export const WifiGlyph: G = ({ size = 18, color = "#fff" }) => (
  <Svg size={size}>
    {[7.6, 5.0, 2.5].map((r, i) => (
      <path
        key={r}
        d={`M${10 - r * 1.25} ${15 - r * 0.95} A ${r * 1.6} ${r * 1.6} 0 0 1 ${10 + r * 1.25} ${15 - r * 0.95}`}
        fill="none"
        stroke={color}
        strokeWidth={1.75}
        strokeLinecap="round"
        opacity={i === 0 ? 1 : 1}
      />
    ))}
    <circle cx="10" cy="15.2" r="1.35" fill={color} />
  </Svg>
);

export const BatteryGlyph: G = ({ size = 18, color = "#fff" }) => (
  <Svg size={size} vb="0 0 26 20">
    <rect x="1" y="5.5" width="21" height="10" rx="3" fill="none" stroke={color} strokeOpacity="0.55" strokeWidth="1.2" />
    <rect x="3" y="7.5" width="14.5" height="6" rx="1.6" fill={color} />
    <path d="M23.4 8.7v3.6a1.9 1.9 0 0 0 0-3.6z" fill={color} fillOpacity="0.55" />
  </Svg>
);

export const SearchGlyph: G = ({ size = 18, color = "#fff" }) => (
  <Svg size={size}>
    <circle cx="8.6" cy="8.6" r="5" fill="none" stroke={color} strokeWidth="1.7" />
    <line x1="12.3" y1="12.3" x2="16.2" y2="16.2" stroke={color} strokeWidth="1.9" strokeLinecap="round" />
  </Svg>
);

export const ControlGlyph: G = ({ size = 18, color = "#fff" }) => (
  <Svg size={size}>
    <rect x="2.4" y="3.6" width="15.2" height="5.4" rx="2.7" fill="none" stroke={color} strokeWidth="1.4" />
    <circle cx="14.9" cy="6.3" r="1.6" fill={color} />
    <rect x="2.4" y="11" width="15.2" height="5.4" rx="2.7" fill="none" stroke={color} strokeWidth="1.4" />
    <circle cx="5.1" cy="13.7" r="1.6" fill={color} />
  </Svg>
);

/** The Apple menu glyph is the system font's U+F8FF, which renders on macOS. */
export const APPLE = "\uF8FF";
