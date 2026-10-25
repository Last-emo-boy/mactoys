// Cut effects. Each transition belongs to the incoming shot (`enter`); around its cut both shots are
// on screen and this module styles the outgoing ("out") and incoming ("in") layers.

import React from "react";
import { AbsoluteFill } from "remotion";
import { HEIGHT, WIDTH } from "../config";
import { clamp, ease, ep, mix, prog } from "../motion";
import type { Dir, Transition } from "../timeline";

export interface LayerLook {
  style: React.CSSProperties;
  /** Directional blur (px) for whips: [x, y]. */
  blur?: [number, number];
  /** White overlay opacity (flash, bloom). */
  white?: number;
  z: number;
  /** Ring drawn over an iris edge. */
  ring?: { x: number; y: number; r: number; o: number };
  /** Glint along a wipe edge. */
  glint?: { pos: number; o: number };
}

const vec = (d: Dir | undefined): [number, number] =>
  d === "left" ? [-1, 0] : d === "right" ? [1, 0] : d === "up" ? [0, -1] : d === "down" ? [0, 1] : [-1, 0];

const R = Math.hypot(WIDTH, HEIGHT);
const WIPE_ANGLE = 104;

/** Look of a layer `u` frames from the cut (negative = before) under transition `t`. */
export function look(t: Transition, role: "in" | "out", u: number): LayerLook {
  const { pre, post } = t;
  const base: LayerLook = { style: {}, z: role === "in" ? 2 : 1 };
  switch (t.kind) {
    case "fade": {
      if (role === "in") base.style.opacity = ep(u, 0, post, ease.standard);
      return base;
    }
    case "continue":
    case "pop":
      return base;
    case "flash": {
      if (role === "out") {
        const p = prog(u, -pre, 0);
        base.style.filter = `brightness(${1 + 0.8 * p * p}) saturate(${1 + 0.3 * p})`;
        base.white = 0.62 * p * p * p;
        if (u >= 0) base.style.opacity = 0;
      } else {
        const q = ep(u, 0, post, ease.out);
        base.white = 0.62 * (1 - q) ** 2;
        base.style.transform = `scale(${mix(1.035, 1, q)})`;
        if (u < 0) base.style.opacity = 0;
      }
      return base;
    }
    case "zoom": {
      const [ax, ay] = t.at ?? [WIDTH / 2, HEIGHT / 2];
      const origin = `${ax}px ${ay}px`;
      if (role === "out") {
        const p = prog(u, -pre, post * 0.6);
        const e = ease.inHard(p);
        base.z = 3;
        base.style = { transformOrigin: origin, transform: `scale(${1 + 2.4 * e})`, opacity: 1 - ep(u, -pre * 0.35, post * 0.55, ease.standard), filter: `blur(${14 * e}px)` };
      } else {
        // the incoming shot settles from slightly over-scale, so its edges never show
        const q = ep(u, pre > 0 ? -pre * 0.5 : 0, post, ease.out);
        base.style = { transformOrigin: origin, transform: `scale(${mix(1.22, 1, q)})`, filter: `blur(${(1 - q) * 14}px)`, opacity: clamp(q * 2.2) };
      }
      return base;
    }
    case "whip":
    case "push": {
      const [vx, vy] = vec(t.dir);
      const D = vx !== 0 ? WIDTH : HEIGHT;
      const span = pre + post;
      const p = prog(u, -pre, post);
      const curve = ease.inOut;
      const s = curve(p);
      // speed in px/frame from the curve's slope (numerical)
      const s2 = curve(clamp(p + 1 / span));
      const speed = Math.abs(s2 - s) * D;
      const off = role === "out" ? -s : 1 - s;
      base.style.transform = `translate(${vx * off * D}px, ${vy * off * D}px)`;
      const b = Math.min(t.kind === "whip" ? 90 : 36, speed * (t.kind === "whip" ? 0.55 : 0.3));
      base.blur = [Math.abs(vx) * b, Math.abs(vy) * b];
      return base;
    }
    case "wipe": {
      const p = ep(u, -pre, post, ease.inOut);
      if (role === "in") {
        const soft = 9;
        const edge = mix(-soft, 100 + soft, p);
        const mask = `linear-gradient(${WIPE_ANGLE}deg, #000 ${edge - soft}%, transparent ${edge}%)`;
        base.style = { WebkitMaskImage: mask, maskImage: mask, transform: `translateX(${(1 - p) * 60}px)` };
        base.glint = { pos: edge - soft / 2, o: Math.sin(Math.PI * p) };
      } else {
        base.style = { transform: `translateX(${-p * 90}px) scale(${1 - 0.03 * p})`, filter: `brightness(${1 - 0.25 * p})` };
      }
      return base;
    }
    case "iris": {
      // closes on a point down to a small circle; the next shot opens out of that same circle
      const [ax, ay] = t.at ?? [WIDTH / 2, HEIGHT / 2];
      const [bx, by] = t.to ?? [ax, ay];
      const r0 = 118;
      if (role === "out") {
        const p = ep(u, -pre, 0, ease.inOut);
        const r = mix(R, r0, p);
        base.style = { clipPath: `circle(${r}px at ${ax}px ${ay}px)` };
        base.ring = { x: ax, y: ay, r, o: u < 0 ? Math.min(1, p * 2.5) : 0 };
        if (u >= 0) base.style.opacity = 0;
      } else {
        const q = ep(u, 2, post, ease.inOut);
        const r = mix(r0, R, q);
        base.style = { clipPath: `circle(${r}px at ${bx}px ${by}px)` };
        base.ring = { x: bx, y: by, r, o: u >= 0 ? 1 - q : 0 };
        if (u < 0) base.style.opacity = 0;
      }
      return base;
    }
    case "pull": {
      if (role === "out") {
        const p = ep(u, -pre, post, ease.inOut);
        base.z = 3;
        base.style = { transform: `scale(${mix(1, 0.8, p)})`, opacity: 1 - ep(u, -pre * 0.3, post * 0.8, ease.standard), filter: `blur(${p * 10}px)` };
      } else {
        const q = ep(u, -pre * 0.5, post, ease.out);
        base.style = { transform: `scale(${mix(1.12, 1, q)})`, filter: `blur(${(1 - q) * 10}px)` };
      }
      return base;
    }
    case "bloom": {
      if (role === "out") {
        const p = ep(u, -pre, post, ease.inOut);
        base.z = 3;
        base.style = { opacity: 1 - p, filter: `blur(${p * 18}px) brightness(${1 + p * 0.7})` };
      } else {
        const q = ep(u, -pre * 0.4, post, ease.out);
        base.style = { transform: `scale(${mix(1.05, 1, q)})`, filter: `blur(${(1 - q) * 14}px)` };
        base.white = 0.18 * Math.sin(Math.PI * clamp(q));
      }
      return base;
    }
  }
}

/** Combine two looks (a layer can be entering and leaving at once only in very short shots). */
export function combine(a: LayerLook | null, b: LayerLook | null): LayerLook {
  if (!a) return b ?? { style: {}, z: 1 };
  if (!b) return a;
  const filter = [a.style.filter, b.style.filter].filter(Boolean).join(" ") || undefined;
  const transform = [a.style.transform, b.style.transform].filter(Boolean).join(" ") || undefined;
  const opacity = (a.style.opacity === undefined ? 1 : Number(a.style.opacity)) * (b.style.opacity === undefined ? 1 : Number(b.style.opacity));
  return {
    style: { ...a.style, ...b.style, filter, transform, opacity },
    blur: a.blur && b.blur ? [a.blur[0] + b.blur[0], a.blur[1] + b.blur[1]] : (a.blur ?? b.blur),
    white: Math.max(a.white ?? 0, b.white ?? 0),
    z: Math.max(a.z, b.z),
    ring: b.ring ?? a.ring,
    glint: a.glint ?? b.glint,
  };
}

/** Applies a look to a shot layer. */
export const LookLayer: React.FC<{ look: LayerLook; id: string; children: React.ReactNode }> = ({ look: L, id, children }) => {
  const fid = `whip-${id}`;
  const hasBlur = L.blur && (L.blur[0] > 0.3 || L.blur[1] > 0.3);
  const filter = [hasBlur ? `url(#${fid})` : null, L.style.filter].filter(Boolean).join(" ") || undefined;
  return (
    <AbsoluteFill style={{ zIndex: L.z }}>
      {hasBlur && (
        <svg width="0" height="0" style={{ position: "absolute" }}>
          <filter id={fid} x="-10%" y="-10%" width="120%" height="120%" colorInterpolationFilters="sRGB">
            <feGaussianBlur stdDeviation={`${L.blur![0].toFixed(2)} ${L.blur![1].toFixed(2)}`} edgeMode="duplicate" />
          </filter>
        </svg>
      )}
      <AbsoluteFill style={{ ...L.style, filter, overflow: "hidden" }}>{children}</AbsoluteFill>
      {L.white ? <AbsoluteFill style={{ background: "#fff", opacity: L.white, mixBlendMode: "screen" }} /> : null}
      {L.ring && L.ring.o > 0.01 && (
        <div
          style={{
            position: "absolute",
            left: L.ring.x - L.ring.r,
            top: L.ring.y - L.ring.r,
            width: L.ring.r * 2,
            height: L.ring.r * 2,
            borderRadius: "50%",
            boxShadow: `0 0 0 2px rgba(255,255,255,${0.8 * L.ring.o}), 0 0 40px rgba(255,255,255,${0.45 * L.ring.o})`,
          }}
        />
      )}
      {L.glint && L.glint.o > 0.01 && (
        <AbsoluteFill
          style={{
            background: `linear-gradient(${WIPE_ANGLE}deg, transparent ${L.glint.pos - 2.2}%, rgba(255,255,255,${0.55 * L.glint.o}) ${L.glint.pos}%, transparent ${L.glint.pos + 2.2}%)`,
            mixBlendMode: "screen",
          }}
        />
      )}
    </AbsoluteFill>
  );
};
