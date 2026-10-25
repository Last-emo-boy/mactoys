// Chrome drawn around the app's own UI: menu bar, pointer, glass keycaps, lower third, film finish.

import React from "react";
import { AbsoluteFill, Img, useCurrentFrame } from "remotion";
import { HEIGHT, WIDTH } from "../config";
import { useAppFile, useFilm, useLocalFrame, useModule } from "../context";
import { ease, ep, mix, prog, px, sp, SPRINGS } from "../motion";
import { FONT_DISPLAY, FONT_MONO, FONT_TEXT, fontFor } from "../theme";
import { APPLE, BatteryGlyph, ControlGlyph, CupGlyph, PuzzleGlyph, SearchGlyph, SunGlyph, WifiGlyph } from "./Glyphs";

// ───────────────────────────── menu bar ─────────────────────────────

export const MENU_H = 36;
const CLOCK_RIGHT = WIDTH - 16;
const CLOCK_W = 172;
const ICON_W = 38;
const ITEMS = ["control", "search", "wifi", "battery", "mactoys", "awake", "display"] as const;
export type MenuItem = (typeof ITEMS)[number];

/** Center x of a menu bar status item. */
export function menuItemX(item: MenuItem): number {
  const i = ITEMS.indexOf(item);
  return CLOCK_RIGHT - CLOCK_W - ICON_W / 2 - i * ICON_W;
}

const GLYPHS: Record<MenuItem, React.FC<{ size?: number; color?: string }>> = {
  control: ControlGlyph,
  search: SearchGlyph,
  wifi: WifiGlyph,
  battery: BatteryGlyph,
  mactoys: PuzzleGlyph,
  awake: CupGlyph,
  display: SunGlyph,
};

export const MenuBar: React.FC<{ highlight?: MenuItem; highlightAmount?: number; opacity?: number }> = ({
  highlight,
  highlightAmount = 0,
  opacity = 1,
}) => {
  const { copy, lang } = useFilm();
  const font = fontFor(lang, false);
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: WIDTH, height: MENU_H, opacity, fontFamily: font, color: "#fff" }}>
      <div style={{ position: "absolute", inset: 0, background: "linear-gradient(rgba(5,6,30,0.28), rgba(5,6,30,0.06))" }} />
      <div style={{ position: "absolute", left: 22, top: 0, height: MENU_H, display: "flex", alignItems: "center", gap: 21, fontSize: 14.5, textShadow: "0 1px 2px rgba(0,0,0,0.25)" }}>
        <span style={{ fontFamily: FONT_TEXT, fontSize: 17, marginRight: 4, transform: "translateY(-1px)" }}>{APPLE}</span>
        {copy.menus.map((m, i) => (
          <span key={m} style={{ fontWeight: i === 0 ? 700 : 500, letterSpacing: "-0.01em" }}>
            {m}
          </span>
        ))}
      </div>
      {ITEMS.map((it) => {
        const G = GLYPHS[it];
        const x = menuItemX(it);
        const on = it === highlight ? highlightAmount : 0;
        return (
          <div key={it} style={{ position: "absolute", left: x - ICON_W / 2 + 2, top: 4, width: ICON_W - 4, height: MENU_H - 8 }}>
            <div style={{ position: "absolute", inset: 0, borderRadius: 999, background: `rgba(255,255,255,${0.24 * on})` }} />
            <div style={{ position: "absolute", left: "50%", top: "50%", transform: "translate(-50%,-50%)", filter: "drop-shadow(0 1px 1.5px rgba(0,0,0,0.25))" }}>
              <G size={it === "battery" ? 24 : 18} />
            </div>
          </div>
        );
      })}
      <div
        style={{
          position: "absolute",
          left: CLOCK_RIGHT - CLOCK_W,
          width: CLOCK_W,
          top: 0,
          height: MENU_H,
          display: "flex",
          alignItems: "center",
          justifyContent: "flex-end",
          fontSize: 14.5,
          fontWeight: 500,
          whiteSpace: "pre",
          fontVariantNumeric: "tabular-nums",
          textShadow: "0 1px 2px rgba(0,0,0,0.25)",
        }}
      >
        {copy.clock}
      </div>
    </div>
  );
};

// ───────────────────────────── pointer ─────────────────────────────

/** macOS arrow pointer; (x, y) is the hotspot. `press` 0..1 squashes it for a click. */
export const Cursor: React.FC<{ x: number; y: number; press?: number; opacity?: number; scale?: number }> = ({ x, y, press = 0, opacity = 1, scale = 1.35 }) => (
  <div
    style={{
      position: "absolute",
      left: x,
      top: y,
      width: 0,
      height: 0,
      opacity,
      transform: `scale(${scale * (1 - 0.12 * press)})`,
      transformOrigin: "0 0",
      filter: "drop-shadow(0 3px 4px rgba(0,0,0,0.35))",
    }}
  >
    <svg width="22" height="30" viewBox="-1.5 -1.5 22 30" style={{ position: "absolute", left: -1.5, top: -1.5, overflow: "visible" }}>
      <path d="M0 0 L0 20.5 L4.9 15.9 L8.3 23.6 L11.5 22.2 L8.2 14.7 L14.8 14.7 Z" fill="#000" stroke="#fff" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  </div>
);

/** Position along a gentle arc from a to b (pointer travel). */
export function arc(a: [number, number], b: [number, number], t: number, bow = 0.12): [number, number] {
  const mx = (a[0] + b[0]) / 2,
    my = (a[1] + b[1]) / 2;
  const dx = b[0] - a[0],
    dy = b[1] - a[1];
  const cx = mx - dy * bow,
    cy = my + dx * bow;
  const u = 1 - t;
  return [u * u * a[0] + 2 * u * t * cx + t * t * b[0], u * u * a[1] + 2 * u * t * cy + t * t * b[1]];
}

// ───────────────────────────── glass ─────────────────────────────

export const glass = (tone: "dark" | "light" = "dark", radius = 22): React.CSSProperties => ({
  borderRadius: radius,
  background:
    tone === "dark"
      ? "linear-gradient(160deg, rgba(255,255,255,0.20), rgba(255,255,255,0.07) 45%, rgba(255,255,255,0.10)), rgba(18,14,44,0.44)"
      : "linear-gradient(160deg, rgba(255,255,255,0.72), rgba(255,255,255,0.52))",
  backdropFilter: "blur(26px) saturate(1.7)",
  WebkitBackdropFilter: "blur(26px) saturate(1.7)",
  boxShadow:
    tone === "dark"
      ? "inset 0 1px 0 rgba(255,255,255,0.38), inset 0 0 0 1px rgba(255,255,255,0.16), inset 0 -10px 24px rgba(255,255,255,0.04), 0 18px 50px rgba(5,4,25,0.38)"
      : "inset 0 1px 0 rgba(255,255,255,0.9), inset 0 0 0 1px rgba(255,255,255,0.5), 0 18px 50px rgba(5,4,25,0.3)",
});

// ───────────────────────────── keycaps ─────────────────────────────

const KEY_H = 68;

function keyWidth(label: string): number {
  const n = [...label].length;
  if (n <= 1) return KEY_H;
  if (n <= 3) return KEY_H + 22 * (n - 1);
  return 30 + n * 15;
}

/**
 * Glass keycaps for a manifest shortcut. They rise in from `appear`; `taps[i]` lists the local frames
 * key i is pressed; they leave at `leave`.
 */
export const Keycaps: React.FC<{
  keys: string[];
  appear: number;
  taps: number[][];
  leave?: number;
  right?: number;
  bottom?: number;
}> = ({ keys, appear, taps, leave, right = 96, bottom = 92 }) => {
  const f = useLocalFrame();
  if (f < appear - 1) return null;
  const tapOf = (i: number): number[] => taps[i] ?? [];
  const out = leave !== undefined ? ep(f, leave, leave + 14, ease.in) : 0;
  return (
    <div style={{ position: "absolute", right, bottom, display: "flex", gap: 12, alignItems: "flex-end" }}>
      {keys.map((k, i) => {
        const inA = sp(f, appear + i * 2.5, SPRINGS.pop);
        const presses = tapOf(i).map((t) => (f >= t ? Math.exp(-(f - t) / 5) * Math.min(1, (f - t + 1) / 2) : 0));
        const press = Math.max(0, ...presses);
        const lit = Math.max(0, ...tapOf(i).map((t) => (f >= t ? Math.exp(-(f - t) / 18) : 0)));
        const o = Math.min(1, inA * 1.4) * (1 - out);
        const y = (1 - inA) * 40 + out * 24 + press * 5;
        const w = keyWidth(k);
        const word = [...k].length > 2;
        return (
          <div
            key={`${k}${i}`}
            style={{
              position: "relative",
              width: w,
              height: KEY_H,
              opacity: o,
              transform: `translateY(${y}px) scale(${mix(0.86, 1, inA) * (1 - press * 0.05)})`,
              willChange: "transform",
              ...glass("dark", 17),
              boxShadow: `inset 0 1px 0 rgba(255,255,255,${0.42 + lit * 0.4}), inset 0 0 0 1px rgba(255,255,255,${0.18 + lit * 0.35}), inset 0 -3px 0 rgba(0,0,0,${0.16 - press * 0.1}), 0 ${14 - press * 8}px ${36 - press * 16}px rgba(5,4,25,0.42), 0 0 ${lit * 30}px rgba(140,170,255,${lit * 0.35})`,
              background: `linear-gradient(170deg, rgba(255,255,255,${0.26 + lit * 0.22}), rgba(255,255,255,${0.08 + lit * 0.12}) 55%, rgba(255,255,255,0.12)), rgba(18,14,44,0.4)`,
            }}
          >
            <div
              style={{
                position: "absolute",
                inset: 0,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                color: "#fff",
                fontFamily: FONT_DISPLAY,
                fontSize: word ? 23 : 31,
                fontWeight: word ? 600 : 500,
                letterSpacing: word ? "-0.01em" : 0,
                textShadow: "0 1px 2px rgba(0,0,0,0.25)",
                whiteSpace: "nowrap",
              }}
            >
              {k}
            </div>
          </div>
        );
      })}
    </div>
  );
};

// ───────────────────────────── lower third ─────────────────────────────

/** Icon + utility name (from the manifest) + one line of copy, on a glass plate. Local frames. */
export const LowerThird: React.FC<{ module: string; line: string; appear: number; leave?: number }> = ({ module, line, appear, leave }) => {
  const f = useLocalFrame();
  const { lang } = useFilm();
  const info = useModule(module);
  const icon = useAppFile(`icons/${module}.png`);
  if (f < appear - 1) return null;
  if (leave !== undefined && f > leave + 16) return null;
  const a = sp(f, appear, SPRINGS.soft);
  const t1 = ep(f, appear + 3, appear + 19, ease.out);
  const t2 = ep(f, appear + 7, appear + 25, ease.out);
  const out = leave !== undefined ? ep(f, leave, leave + 14, ease.in) : 0;
  const font = fontFor(lang);
  return (
    <div
      style={{
        position: "absolute",
        left: 96,
        bottom: 88,
        display: "flex",
        alignItems: "center",
        gap: 20,
        padding: "18px 30px 18px 18px",
        opacity: Math.min(1, a * 1.5) * (1 - out),
        transform: `translateY(${px((1 - a) * 26 + out * 16)}px) scale(${mix(0.96, 1, a)})`,
        transformOrigin: "0% 100%",
        willChange: "transform",
        ...glass("dark", 26),
      }}
    >
      <Img src={icon} style={{ width: 64, height: 64, borderRadius: 15, transform: `scale(${mix(0.6, 1, sp(f, appear + 2, SPRINGS.pop))})`, boxShadow: "0 6px 16px rgba(0,0,0,0.25)" }} />
      <div style={{ display: "flex", flexDirection: "column", gap: 4, fontFamily: font, color: "#fff" }}>
        <div style={{ fontSize: 30, fontWeight: 650, letterSpacing: "-0.02em", opacity: t1, transform: `translateY(${px((1 - t1) * 10)}px)`, whiteSpace: "nowrap" }}>{info.name}</div>
        <div style={{ fontSize: 23, fontWeight: 450, letterSpacing: "-0.005em", color: "rgba(255,255,255,0.78)", opacity: t2, transform: `translateY(${px((1 - t2) * 10)}px)`, whiteSpace: "nowrap" }}>
          {line}
        </div>
      </div>
    </div>
  );
};

/** A lower third for the app itself (Settings, the CLI): app mark + optional title + line. Local frames. */
export const AppCaption: React.FC<{ title?: string; line: string; appear: number; leave?: number; mono?: boolean }> = ({ title, line, appear, leave, mono }) => {
  const f = useLocalFrame();
  const { lang } = useFilm();
  const icon = useAppFile("icons/app.png");
  if (f < appear - 1) return null;
  const a = sp(f, appear, SPRINGS.soft);
  const out = leave !== undefined ? ep(f, leave, leave + 14, ease.in) : 0;
  const font = fontFor(lang);
  return (
    <div
      style={{
        position: "absolute",
        left: 96,
        bottom: 88,
        display: "flex",
        alignItems: "center",
        gap: 20,
        padding: "18px 30px 18px 18px",
        opacity: Math.min(1, a * 1.5) * (1 - out),
        transform: `translateY(${px((1 - a) * 26 + out * 16)}px) scale(${mix(0.96, 1, a)})`,
        transformOrigin: "0% 100%",
        willChange: "transform",
        fontFamily: font,
        color: "#fff",
        ...glass("dark", 26),
      }}
    >
      <Img src={icon} style={{ width: 64, height: 64, transform: `scale(${mix(0.6, 1, sp(f, appear + 2, SPRINGS.pop))})` }} />
      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        {title && <div style={{ fontSize: 30, fontWeight: 650, letterSpacing: mono ? 0 : "-0.02em", fontFamily: mono ? FONT_MONO : font }}>{title}</div>}
        <div style={{ fontSize: title ? 23 : 30, fontWeight: title ? 450 : 650, color: title ? "rgba(255,255,255,0.78)" : "#fff", letterSpacing: "-0.01em", whiteSpace: "nowrap" }}>{line}</div>
      </div>
    </div>
  );
};

// ───────────────────────────── finish ─────────────────────────────

/** Seeded film grain + vignette over everything. */
export const Finish: React.FC<{ grain?: number; vignette?: number }> = ({ grain = 0.06, vignette = 0.42 }) => {
  const frame = useCurrentFrame();
  const seed = Math.floor(frame) % 97;
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      <AbsoluteFill style={{ background: `radial-gradient(120% 100% at 50% 45%, rgba(0,0,0,0) 55%, rgba(0,0,0,${vignette}) 100%)` }} />
      <svg width={WIDTH} height={HEIGHT} style={{ position: "absolute", inset: 0, mixBlendMode: "overlay", opacity: grain * 4 }}>
        <filter id="grain" x="0" y="0" width="100%" height="100%">
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed={seed} stitchTiles="stitch" />
          <feColorMatrix type="matrix" values="0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 2.2 -0.6" />
        </filter>
        <rect width={WIDTH} height={HEIGHT} filter="url(#grain)" />
      </svg>
    </AbsoluteFill>
  );
};

/** Fraction helpers re-exported for shots. */
export { prog };
