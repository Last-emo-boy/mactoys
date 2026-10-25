// 3 · All utilities burst out of the app icon into a wall grouped by category; a light sweep; the wall
// collapses into the Command Palette tile, which carries us into the first vignette.

import React from "react";
import { AbsoluteFill, Img } from "remotion";
import { CameraMotionBlur } from "@remotion/motion-blur";
import { HEIGHT, WIDTH } from "../config";
import { useAppFiles, useFilm, useLocalFrame, useShot } from "../context";
import { Camera } from "../components/World";
import { clamp, ease, ep, hash, kf, mix, px, sp } from "../motion";
import { fontFor } from "../theme";
import { cueFrame } from "../timeline";
import { AppIcon, BURST_AT, TitleBackdrop } from "./Title";
import { wallLayout, type WallIcon } from "./wallLayout";

const SWEEP_ANGLE = 0.42; // radians from vertical

/** A tile with a moving specular band; `band` is the band's position along the sweep axis. */
export const Tile: React.FC<{ src: string; size: number; band?: number; x: number; y: number; shadow?: number }> = ({ src, size, band, x, y, shadow = 1 }) => {
  const along = x * Math.cos(SWEEP_ANGLE) + y * Math.sin(SWEEP_ANGLE);
  const d = band === undefined ? 9999 : along - band;
  const glow = Math.exp(-((d / 90) ** 2));
  return (
    <div style={{ position: "relative", width: size, height: size }}>
      <Img src={src} style={{ width: size, height: size, display: "block", filter: `drop-shadow(0 ${10 * shadow}px ${18 * shadow}px rgba(8,4,30,${0.38 * shadow}))` }} />
      {glow > 0.01 && (
        <div
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: size * 0.225,
            background: `linear-gradient(${90 + (SWEEP_ANGLE * 180) / Math.PI}deg, rgba(255,255,255,0) ${50 - 28 - d / 4}%, rgba(255,255,255,${0.55 * glow}) ${50 - d / 4}%, rgba(255,255,255,0) ${50 + 28 - d / 4}%)`,
            mixBlendMode: "overlay",
          }}
        />
      )}
    </div>
  );
};

const Icons: React.FC<{ icons: WallIcon[]; size: number }> = ({ icons, size }) => {
  const f = useLocalFrame();
  const shot = useShot();
  const file = useAppFiles();
  const sweep = cueFrame(shot, "sweep");
  const collapse = cueFrame(shot, "collapse");
  const end = shot.frames;
  const band = mix(-500, 2900, ep(f, sweep, sweep + 54, ease.inOut));
  return (
    <>
      {icons.map((ic) => {
        const seed = hash(ic.order, 7);
        const delay = ic.order * 0.9 + ic.group * 2.2;
        const p = sp(f, delay, { damping: 14, mass: 0.9, stiffness: 115 });
        // a curved flight out of the icon
        const sx = BURST_AT.x,
          sy = BURST_AT.y;
        const mx = (sx + ic.x) / 2 + (ic.y - sy) * (seed - 0.5) * 0.9;
        const my = (sy + ic.y) / 2 - (ic.x - sx) * (seed - 0.5) * 0.5 - 60;
        const u = 1 - p;
        let x = u * u * sx + 2 * u * p * mx + p * p * ic.x;
        let y = u * u * sy + 2 * u * p * my + p * p * ic.y;
        let scale = mix(0.3, 1, p);
        let rot = (1 - p) * (seed - 0.5) * 90;
        let opacity = clamp(p * 4);
        const z = (hash(ic.order, 3) - 0.5) * 90;
        // collapse into the Command Palette tile
        const isHero = ic.id === "cmdpal";
        const c = ep(f, collapse - (isHero ? 0 : hash(ic.order, 11) * 10), end, isHero ? ease.inOut : ease.in);
        if (c > 0) {
          x = mix(x, WIDTH / 2, c);
          y = mix(y, HEIGHT / 2, c);
          scale = isHero ? mix(scale, 3.4, ease.in(c)) : mix(scale, 0.25, c);
          opacity = isHero ? opacity : opacity * (1 - ease.in(c));
          rot = isHero ? rot : rot + c * (seed - 0.5) * 60;
        }
        return (
          <div
            key={ic.id}
            style={{
              position: "absolute",
              left: x - size / 2,
              top: y - size / 2,
              width: size,
              height: size,
              opacity,
              zIndex: isHero ? 10 : 1,
              transform: `translateZ(${z * (1 - c)}px) rotate(${rot}deg) scale(${scale})`,
            }}
          >
            <Tile src={file(`icons/${ic.id}.png`)} size={size} band={band} x={ic.x} y={ic.y} shadow={isHero ? 1 + c : 1} />
          </div>
        );
      })}
    </>
  );
};

export const Wall: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const { manifest, lang } = useFilm();
  const lay = wallLayout(manifest);
  const titlesAt = cueFrame(shot, "titles");
  const collapse = cueFrame(shot, "collapse");
  const end = shot.frames;
  const font = fontFor(lang);
  const out = ep(f, collapse - 6, collapse + 16, ease.in);
  const settle = ep(f, collapse, end, ease.inOut);
  const ry = kf(f, [[0, 0], [70, -6], [collapse, 5]], ease.inOut) * (1 - settle);
  const rx = kf(f, [[0, 0], [70, 7], [collapse, 4]], ease.inOut) * (1 - settle);
  const zoom = kf(f, [[0, 1.05], [80, 1.0], [collapse, 1.05], [end, 1.0]], ease.inOut);
  const blurred = f < 75 || f > collapse - 2;
  const icons = <Icons icons={lay.icons} size={lay.size} />;
  return (
    <AbsoluteFill>
      <TitleBackdrop glow={0.4 + 0.6 * settle} />
      <Camera zoom={zoom} rx={rx} ry={ry} perspective={1800}>
        {lay.groups.map((g, i) => {
          const t = ep(f, titlesAt + i * 4, titlesAt + i * 4 + 22, ease.out);
          return (
            <div
              key={g.title}
              style={{
                position: "absolute",
                left: g.x,
                top: g.y - 40,
                width: g.w + 46,
                height: 40,
                display: "flex",
                alignItems: "flex-end",
                fontFamily: font,
                fontSize: 21,
                lineHeight: 1.12,
                fontWeight: 600,
                letterSpacing: "-0.005em",
                color: "rgba(255,255,255,0.86)",
                opacity: t * (1 - out),
                transform: `translateY(${px((1 - t) * 12)}px)`,
              }}
            >
              {g.title}
            </div>
          );
        })}
        {blurred ? (
          <CameraMotionBlur samples={8} shutterAngle={200}>
            <div style={{ position: "absolute", left: 0, top: 0, width: WIDTH, height: HEIGHT, transformStyle: "preserve-3d" }}>{icons}</div>
          </CameraMotionBlur>
        ) : (
          icons
        )}
      </Camera>
      {/* the app icon handed over from the title bursts open as the tiles fly out of it */}
      {f < 16 && (
        <div
          style={{
            position: "absolute",
            left: BURST_AT.x,
            top: BURST_AT.y,
            transform: `translate(-50%, -50%) scale(${mix(1, 1.4, ep(f, 0, 14, ease.out))})`,
            opacity: 1 - ep(f, 1, 13, ease.standard),
            filter: `brightness(${1 + 0.6 * ep(f, 0, 10)}) drop-shadow(0 30px 60px rgba(10,0,40,0.55))`,
          }}
        >
          <AppIcon size={BURST_AT.size} />
        </div>
      )}
    </AbsoluteFill>
  );
};
