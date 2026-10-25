// A seamless 8 s loop (no audio): rows of every utility icon drifting past the wordmark. Every motion
// is periodic in LOOP_FRAMES, so frame LOOP_FRAMES equals frame 0. The poster is one frame of it.

import React from "react";
import { AbsoluteFill, Img, staticFile, useCurrentFrame } from "remotion";
import { APP_ICON, manifestFor, type AssetIndex } from "./assets";
import { glass } from "./components/Chrome";
import { Wallpaper } from "./components/World";
import { HEIGHT, WIDTH, type FilmLang } from "./config";
import { FilmCtx, useAppFiles, useFilm, type FilmContextValue } from "./context";
import { COPY } from "./copy";
import { useFonts } from "./fonts";
import { ease, ep, mix } from "./motion";
import { Tile } from "./shots/Wall";
import { fontFor } from "./theme";
import { buildTimeline } from "./timeline";

export const LOOP_FRAMES = 480;

export interface LoopProps {
  lang: FilmLang;
  index?: AssetIndex;
  [key: string]: unknown;
}

const SIZE = 118;
const PITCH = 158;
const PER_ROW = 16; // a row repeats every PER_ROW icons; it travels one repeat per loop
const ROWS = [
  { y: 92, dir: 1, offset: 0, depth: 0.82 },
  { y: 268, dir: -1, offset: 9, depth: 0.92 },
  { y: 454, dir: 1, offset: 19, depth: 1 },
  { y: 640, dir: -1, offset: 4, depth: 0.92 },
  { y: 818, dir: 1, offset: 14, depth: 0.82 },
  { y: 990, dir: -1, offset: 25, depth: 0.74 },
];

const TAU = Math.PI * 2;

/** Light drifting on closed orbits, so it returns to where it started every loop. */
const LoopAurora: React.FC<{ f: number }> = ({ f }) => {
  const a = (f / LOOP_FRAMES) * TAU;
  const blobs = [
    { x: 0.3 + 0.07 * Math.sin(a), y: 0.32 + 0.05 * Math.cos(a), r: 0.55, c: "120,90,255", o: 0.24 },
    { x: 0.76 + 0.06 * Math.cos(a), y: 0.7 + 0.06 * Math.sin(a), r: 0.6, c: "255,140,120", o: 0.2 },
    { x: 0.58 + 0.08 * Math.sin(2 * a + 1), y: 0.22 + 0.04 * Math.sin(a + 2), r: 0.45, c: "255,110,200", o: 0.14 },
  ];
  return (
    <AbsoluteFill style={{ mixBlendMode: "screen" }}>
      {blobs.map((b, i) => (
        <div
          key={i}
          style={{
            position: "absolute",
            left: (b.x - b.r) * WIDTH,
            top: (b.y - b.r) * WIDTH,
            width: b.r * 2 * WIDTH,
            height: b.r * 2 * WIDTH,
            borderRadius: "50%",
            background: `radial-gradient(closest-side, rgba(${b.c},${b.o}), rgba(${b.c},0))`,
          }}
        />
      ))}
    </AbsoluteFill>
  );
};

const Rows: React.FC<{ f: number }> = ({ f }) => {
  const { manifest } = useFilm();
  const file = useAppFiles();
  const ids = manifest.modules.map((m) => m.id);
  const t = f / LOOP_FRAMES;
  // one light sweep per loop, off-screen at both ends
  const band = mix(-700, 3200, ep(f, 150, 330, ease.inOut));
  return (
    <>
      {ROWS.map((row, r) => {
        const span = PER_ROW * PITCH;
        const shift = row.dir * t * span;
        const n = Math.ceil(WIDTH / (PITCH * row.depth)) + PER_ROW + 2;
        return (
          <div key={r} style={{ position: "absolute", left: WIDTH / 2, top: row.y, transform: `scale(${row.depth})`, opacity: mix(0.5, 1, (row.depth - 0.74) / 0.26) }}>
            {Array.from({ length: n }, (_, k) => {
              const i = k - Math.floor(n / 2);
              const x = i * PITCH + (((shift % span) + span) % span) - span / 2;
              const id = ids[(row.offset + (((i % PER_ROW) + PER_ROW) % PER_ROW)) % ids.length];
              return (
                <div key={k} style={{ position: "absolute", left: x - SIZE / 2, top: -SIZE / 2 }}>
                  <Tile src={file(`icons/${id}.png`)} size={SIZE} band={band} x={x * row.depth + WIDTH / 2} y={row.y} shadow={row.depth} />
                </div>
              );
            })}
          </div>
        );
      })}
    </>
  );
};

/** The wordmark plate. `tagline` adds the film's line under it (the poster). */
export const Wordmark: React.FC<{ f: number; tagline?: boolean }> = ({ f, tagline }) => {
  const { lang, copy } = useFilm();
  const breathe = Math.sin((f / LOOP_FRAMES) * TAU);
  const box = (150 * 1024) / 824;
  return (
    <div
      style={{
        position: "absolute",
        left: WIDTH / 2,
        top: HEIGHT / 2,
        transform: `translate(-50%, -50%) scale(${1 + 0.008 * breathe})`,
        display: "flex",
        alignItems: "center",
        gap: 34,
        padding: tagline ? "40px 64px 40px 44px" : "34px 64px 34px 40px",
        ...glass("dark", 48),
        background: "linear-gradient(160deg, rgba(40,26,90,0.55), rgba(30,16,60,0.42))",
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.35), inset 0 0 0 1px rgba(255,255,255,0.16), 0 40px 120px rgba(5,2,25,0.55)",
      }}
    >
      <Img src={staticFile(APP_ICON)} style={{ width: box, height: box, margin: -(box - 150) / 2, filter: "drop-shadow(0 18px 30px rgba(8,0,40,0.5))" }} />
      <div style={{ fontFamily: fontFor(lang), color: "#fff" }}>
        <div style={{ fontSize: 128, fontWeight: 700, letterSpacing: "-0.045em", lineHeight: "140px" }}>MacToys</div>
        {tagline && (
          <div
            style={{
              fontSize: 40,
              fontWeight: 560,
              letterSpacing: "-0.015em",
              marginTop: 2,
              background: "linear-gradient(90deg, #d8ccff, #ffd6ec 50%, #ffcfb4)",
              WebkitBackgroundClip: "text",
              backgroundClip: "text",
              color: "transparent",
              paddingBottom: 4,
            }}
          >
            {copy.tagline}
          </div>
        )}
      </div>
    </div>
  );
};

export const LoopScene: React.FC<{ f: number; tagline?: boolean }> = ({ f, tagline }) => (
  <AbsoluteFill style={{ background: "#0b0a24", overflow: "hidden" }}>
    <Wallpaper dim={0.42} />
    <LoopAurora f={f} />
    <div style={{ position: "absolute", inset: 0, transform: "rotate(-9deg) scale(1.16)", transformOrigin: "50% 50%" }}>
      <Rows f={f} />
    </div>
    <AbsoluteFill style={{ background: "radial-gradient(46% 40% at 50% 50%, rgba(10,6,40,0.62), rgba(10,6,40,0.18) 70%, rgba(10,6,40,0) 100%)" }} />
    <Wordmark f={f} tagline={tagline} />
    <AbsoluteFill style={{ background: "radial-gradient(120% 100% at 50% 45%, rgba(0,0,0,0) 55%, rgba(0,0,0,0.42) 100%)" }} />
  </AbsoluteFill>
);

export function useLoopContext(lang: FilmLang, index: AssetIndex): FilmContextValue {
  return React.useMemo(() => ({ lang, index, timeline: buildTimeline(index.langs), manifest: manifestFor(index, lang), copy: COPY[lang] }), [lang, index]);
}

export const Loop: React.FC<LoopProps> = ({ lang, index }) => {
  useFonts(lang);
  const frame = useCurrentFrame();
  if (!index) return <AbsoluteFill style={{ background: "#000" }} />;
  return <LoopBody lang={lang} index={index} f={frame} />;
};

const LoopBody: React.FC<{ lang: FilmLang; index: AssetIndex; f: number; tagline?: boolean }> = ({ lang, index, f, tagline }) => {
  const ctx = useLoopContext(lang, index);
  return (
    <FilmCtx.Provider value={ctx}>
      <div lang={lang} style={{ position: "absolute", inset: 0 }}>
        <LoopScene f={f} tagline={tagline} />
      </div>
    </FilmCtx.Provider>
  );
};

export { LoopBody };
