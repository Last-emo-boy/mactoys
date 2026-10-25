// 2 · The app icon lands, the name and the line; then "31 utilities · one menu bar".

import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { APP_ICON } from "../assets";
import { BEAT, HEIGHT, WIDTH } from "../config";
import { useFilm, useLocalFrame, useShot } from "../context";
import { clamp, ease, ep, kf, mix, px, sp, SPRINGS } from "../motion";
import { fontFor } from "../theme";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

/** Where the title leaves the icon for the wall's burst. */
export const BURST_AT = { x: WIDTH / 2, y: 470, size: 150 };

/** The 1024 px app icon has its tile inset (824 px); sizes here are of the visible tile. */
export const AppIcon: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => {
  const box = (size * 1024) / 824;
  return <Img src={staticFile(APP_ICON)} style={{ width: box, height: box, margin: -(box - size) / 2, display: "block", ...style }} />;
};

export const TitleBackdrop: React.FC<{ glow?: number; dim?: number }> = ({ glow = 1, dim = 0.32 }) => (
  <>
    <Desktop dim={dim} aurora={0.9} />
    <AbsoluteFill
      style={{
        background: `radial-gradient(42% 46% at 50% 44%, rgba(170,80,220,${0.34 * glow}), rgba(255,90,120,${0.12 * glow}) 48%, rgba(0,0,0,0) 72%)`,
      }}
    />
  </>
);

/** Words revealed one after another with a blur-in. */
export const Reveal: React.FC<{ text: string; f: number; at: number; step?: number; style?: React.CSSProperties; wordStyle?: React.CSSProperties; lang: string }> = ({
  text,
  f,
  at,
  step = 3,
  style,
  wordStyle,
  lang,
}) => {
  const cjk = lang.startsWith("zh");
  const parts = cjk ? [...text] : text.split(/(\s+)/);
  let k = 0;
  return (
    <span style={{ display: "inline-block", whiteSpace: "pre", ...style }}>
      {parts.map((w, i) => {
        if (/^\s+$/.test(w)) return <span key={i}>{w}</span>;
        const t = ep(f, at + k * step, at + k * step + 18, ease.out);
        k++;
        return (
          <span key={i} style={{ display: "inline-block", ...wordStyle, opacity: t, filter: `blur(${(1 - t) * 8}px)`, transform: `translateY(${px((1 - t) * 14)}px)` }}>
            {w}
          </span>
        );
      })}
    </span>
  );
};

export const Title: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const { copy, lang, manifest } = useFilm();
  const font = fontFor(lang);
  const nameAt = cueFrame(shot, "name");
  const lineAt = cueFrame(shot, "line");
  const swap = cueFrame(shot, "swap");
  const countAt = cueFrame(shot, "count");
  const burst = cueFrame(shot, "burst");
  const end = shot.frames;

  // icon: falls in and lands on the downbeat, then rises to make room, then gathers for the burst
  const land = sp(f, -6, SPRINGS.land);
  const iconY = kf(f, [[swap - 4, 352], [swap + 26, 330], [burst - 18, 330], [end, BURST_AT.y]], ease.inOut) - (1 - land) * 160;
  const iconSize = kf(f, [[swap - 4, 290], [swap + 26, 220], [burst - 18, 220], [end - 6, BURST_AT.size + 18], [end, BURST_AT.size]], ease.inOut);
  const iconScale = mix(0.55, 1, land);
  const ring = clamp((f - 2) / 46);

  // name and line
  const nameT = ep(f, nameAt, nameAt + 26, ease.out);
  const out1 = ep(f, swap - 4, swap + 12, ease.in);
  const countT = ep(f, countAt - 2, countAt + 22, ease.out);
  const out2 = ep(f, burst - 10, end - 2, ease.in);
  const n = manifest.modules.length;
  const shown = Math.round(mix(1, n, ease.out(clamp((f - countAt) / (BEAT * 1.4)))));

  return (
    <AbsoluteFill>
      <TitleBackdrop glow={1 - out2 * 0.6} />
      {/* landing ring */}
      {ring > 0 && ring < 1 && (
        <div
          style={{
            position: "absolute",
            left: WIDTH / 2 - 160 - ring * 420,
            top: 352 - 160 - ring * 420,
            width: 320 + ring * 840,
            height: 320 + ring * 840,
            borderRadius: "50%",
            boxShadow: `0 0 0 ${2 + 6 * (1 - ring)}px rgba(255,255,255,${0.32 * (1 - ring) ** 2}), 0 0 80px rgba(255,140,200,${0.3 * (1 - ring)})`,
          }}
        />
      )}
      <div
        style={{
          position: "absolute",
          left: WIDTH / 2,
          top: iconY,
          transform: `translate(-50%, -50%) scale(${iconScale})`,
          opacity: clamp(land * 3),
          filter: `drop-shadow(0 ${30 * land}px ${60}px rgba(10,0,40,0.55))`,
        }}
      >
        <AppIcon size={iconSize} />
      </div>
      {/* MacToys + the line */}
      <div style={{ position: "absolute", left: 0, width: WIDTH, top: 560, textAlign: "center", fontFamily: font, color: "#fff", opacity: 1 - out1, transform: `translateY(${px(-out1 * 40)}px)` }}>
        <div style={{ overflow: "hidden", height: 170, display: "flex", justifyContent: "center" }}>
          <div
            style={{
              fontSize: 148,
              fontWeight: 700,
              letterSpacing: "-0.045em",
              lineHeight: "170px",
              transform: `translateY(${px((1 - nameT) * 150)}px)`,
              filter: `blur(${(1 - nameT) * 6}px)`,
            }}
          >
            MacToys
          </div>
        </div>
        <div style={{ marginTop: 6, fontSize: 50, fontWeight: 560, letterSpacing: "-0.02em" }}>
          <Reveal
            text={copy.tagline}
            f={f}
            at={lineAt}
            lang={lang}
            step={lang.startsWith("zh") ? 1.6 : 3.5}
            wordStyle={{
              background: "linear-gradient(90deg, #ddd2ff, #ffd9ee 55%, #ffd3bb)",
              WebkitBackgroundClip: "text",
              backgroundClip: "text",
              color: "transparent",
              paddingBottom: 6,
            }}
          />
        </div>
      </div>
      {/* 31 utilities · one menu bar */}
      <div
        style={{
          position: "absolute",
          left: 0,
          width: WIDTH,
          top: 610,
          display: "flex",
          justifyContent: "center",
          alignItems: "baseline",
          gap: 22,
          fontFamily: font,
          color: "#fff",
          opacity: countT * (1 - out2),
          transform: `translateY(${px((1 - countT) * 30 + out2 * 30)}px) scale(${1 - out2 * 0.04})`,
          filter: `blur(${(1 - countT) * 8 + out2 * 6}px)`,
        }}
      >
        <span
          style={{
            fontSize: 150,
            fontWeight: 700,
            letterSpacing: "-0.05em",
            fontVariantNumeric: "tabular-nums",
            background: "linear-gradient(180deg, #ffffff, #e9d9ff)",
            WebkitBackgroundClip: "text",
            color: "transparent",
            minWidth: 170,
            textAlign: "right",
          }}
        >
          {shown}
        </span>
        <span style={{ fontSize: 54, fontWeight: 600, letterSpacing: "-0.02em", color: "rgba(255,255,255,0.92)" }}>{copy.countUnit}</span>
      </div>
      <div style={{ position: "absolute", inset: 0, height: HEIGHT, pointerEvents: "none" }} />
    </AbsoluteFill>
  );
};
