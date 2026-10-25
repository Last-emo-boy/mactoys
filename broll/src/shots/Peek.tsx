// 4j · Peek, then the Quick Look previews of Finder Add-ons: → steps through a photo, an STL, G-code.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { MenuBar } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, SceneImg } from "../components/World";
import { clamp, kf, sp } from "../motion";
import { SCENES, type SceneName } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const CARDS: { name: SceneName; scale: number }[] = [
  { name: "peekImage", scale: 0.56 },
  { name: "stl", scale: 0.51 },
  { name: "gcode", scale: 0.51 },
];
const GAP = 960;

export const Peek: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const end = shot.frames;
  const c = sp(f, cueFrame(shot, "next1"), { damping: 19, stiffness: 120 }) + sp(f, cueFrame(shot, "next2"), { damping: 19, stiffness: 120 });
  const zoom = kf(f, [[-14, 1.22], [end + 14, 1.3]]);
  const cy = 570 - (467 - 540) / zoom;
  return (
    <AbsoluteFill>
      <Camera zoom={zoom} cy={cy}>
        <Desktop />
        <MenuBar />
        {/* a flat layer: the turning cards get their own perspective instead of cutting into the desktop */}
        <div style={{ position: "absolute", inset: 0 }}>
        {CARDS.map((card, k) => {
          const d = k - c;
          if (Math.abs(d) > 1.6) return null;
          const g = SCENES[card.name];
          const w = g.win!;
          const s = card.scale;
          const x = 960 + d * GAP - (w.x + w.w / 2) * s;
          const y = 570 - (w.y + w.h / 2) * s;
          const ad = Math.min(1, Math.abs(d));
          return (
            <div
              key={card.name}
              style={{
                position: "absolute",
                inset: 0,
                transformOrigin: `${960 + d * GAP}px 570px`,
                transform: `perspective(1700px) rotateY(${clamp(-d, -1, 1) * 16}deg) scale(${1 - 0.14 * ad})`,
                opacity: 1 - 0.35 * ad,
                filter: ad > 0.02 ? `brightness(${1 - 0.25 * ad})` : undefined,
                zIndex: 10 - Math.round(Math.abs(d) * 2),
              }}
            >
              <SceneImg name={card.name} x={x} y={y} scale={s} clipWin shadow />
            </div>
          );
        })}
        </div>
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
