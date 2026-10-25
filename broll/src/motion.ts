// Easing and spring helpers. Everything is a pure function of the frame.

import { spring, type SpringConfig } from "remotion";
import { BEAT, FPS } from "./config";

export const clamp = (v: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
export const mix = (a: number, b: number, t: number) => a + (b - a) * t;
export const beats = (n: number) => n * BEAT;

/** Progress of `f` through [a, b], clamped to 0..1. */
export const prog = (f: number, a: number, b: number) => (b === a ? (f >= b ? 1 : 0) : clamp((f - a) / (b - a)));

/** CSS-style cubic bezier easing (x1, y1, x2, y2), solved by Newton iterations. */
export function bezier(x1: number, y1: number, x2: number, y2: number) {
  const cx = 3 * x1,
    bx = 3 * (x2 - x1) - cx,
    ax = 1 - cx - bx;
  const cy = 3 * y1,
    by = 3 * (y2 - y1) - cy,
    ay = 1 - cy - by;
  const sx = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sy = (t: number) => ((ay * t + by) * t + cy) * t;
  const dx = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x: number) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const e = sx(t) - x;
      const d = dx(t);
      if (Math.abs(e) < 1e-6 || Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    return sy(clamp(t));
  };
}

/** Apple-like curves. */
export const ease = {
  inOut: bezier(0.65, 0, 0.35, 1),
  out: bezier(0.16, 1, 0.3, 1), // expo-ish out
  outSoft: bezier(0.22, 1, 0.36, 1),
  in: bezier(0.55, 0, 0.9, 0.35),
  inHard: bezier(0.7, 0, 0.84, 0),
  standard: bezier(0.4, 0, 0.2, 1),
};

/** Eased progress through [a, b]. */
export const ep = (f: number, a: number, b: number, curve = ease.inOut) => curve(prog(f, a, b));

export const SPRINGS = {
  pop: { damping: 13, mass: 0.7, stiffness: 170 } as Partial<SpringConfig>,
  soft: { damping: 22, mass: 1, stiffness: 120 } as Partial<SpringConfig>,
  firm: { damping: 18, mass: 0.6, stiffness: 220 } as Partial<SpringConfig>,
  land: { damping: 11, mass: 1.1, stiffness: 140 } as Partial<SpringConfig>,
};

/** Spring that starts at frame `start` (0 before it). */
export function sp(f: number, start: number, config: Partial<SpringConfig> = SPRINGS.soft, durationInFrames?: number) {
  if (f < start) return 0;
  return spring({ frame: f - start, fps: FPS, config, durationInFrames });
}

/** Round to device pixels so static text never shimmers. */
export const px = (v: number) => Math.round(v * 2) / 2;

/** Deterministic pseudo-random in [0, 1) from integer seeds. */
export function hash(...n: number[]) {
  let h = 2166136261;
  for (const v of n) {
    h ^= Math.floor(v * 1000003) >>> 0;
    h = Math.imul(h, 16777619);
    h ^= h >>> 13;
  }
  return ((h >>> 0) % 100000) / 100000;
}

/** Piecewise interpolation through [frame, value] keys, eased between each pair. */
export function kf(f: number, keys: [number, number][], curve: (x: number) => number = ease.inOut): number {
  if (f <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [f1, v1] = keys[i];
    const [f0, v0] = keys[i - 1];
    if (f <= f1) return mix(v0, v1, curve(prog(f, f0, f1)));
  }
  return keys[keys.length - 1][1];
}
