import React from "react";
import { AbsoluteFill } from "remotion";
import { HEIGHT, WIDTH } from "../config";
import { useLocalFrame } from "../context";
import { Wallpaper } from "../components/World";
import type { Rect } from "../scenes";

/** Soft light drifting over the wallpaper, so a still desktop breathes. Pure function of the frame. */
export const Aurora: React.FC<{ strength?: number; seed?: number }> = ({ strength = 1, seed = 0 }) => {
  const f = useLocalFrame() + seed * 1000;
  const t = f / 60;
  const blobs = [
    { x: 0.28 + 0.06 * Math.sin(t * 0.21), y: 0.3 + 0.05 * Math.cos(t * 0.17), r: 0.55, c: "120,90,255", a: 0.22 },
    { x: 0.78 + 0.05 * Math.cos(t * 0.19), y: 0.72 + 0.06 * Math.sin(t * 0.23), r: 0.6, c: "255,140,120", a: 0.18 },
    { x: 0.6 + 0.08 * Math.sin(t * 0.13 + 1), y: 0.2 + 0.04 * Math.sin(t * 0.29), r: 0.45, c: "255,110,200", a: 0.12 },
  ];
  return (
    <div style={{ position: "absolute", left: -WIDTH, top: -HEIGHT, width: WIDTH * 3, height: HEIGHT * 3, mixBlendMode: "screen", opacity: strength, pointerEvents: "none" }}>
      {blobs.map((b, i) => (
        <div
          key={i}
          style={{
            position: "absolute",
            left: WIDTH + (b.x - b.r) * WIDTH,
            top: HEIGHT + (b.y - b.r) * WIDTH,
            width: b.r * 2 * WIDTH,
            height: b.r * 2 * WIDTH,
            borderRadius: "50%",
            background: `radial-gradient(closest-side, rgba(${b.c},${b.a}), rgba(${b.c},0))`,
          }}
        />
      ))}
    </div>
  );
};

/** The film's own desktop: the app wallpaper over the frame, with drifting light. */
export const Desktop: React.FC<{ rect?: Rect; dim?: number; aurora?: number }> = ({ rect, dim, aurora = 1 }) => (
  <>
    <Wallpaper rect={rect} dim={dim} />
    {aurora > 0 && <Aurora strength={aurora} />}
  </>
);

/** Full-frame container for screen-space layers. */
export const Screen: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <AbsoluteFill style={style}>{children}</AbsoluteFill>
);
