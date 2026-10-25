// 4d · Text Extractor: a region of the screen selected for on-device OCR; focus racks in, then "copy".

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, fit, SceneImg, sceneRect, views, Wallpaper } from "../components/World";
import { ease, kf } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";

const S = 0.72;
const X = (1920 - SCENES.textSel.w * S) / 2;
const Y = (1080 - SCENES.textSel.h * S) / 2;
const SEL = SCENES.textSel.marks!.sel;
const at = (p: { x: number; y: number }) => ({ x: X + p.x * S, y: Y + p.y * S });

/** The macOS screenshot crosshair, drawn as chrome. */
const Crosshair: React.FC<{ x: number; y: number }> = ({ x, y }) => (
  <svg width="44" height="44" viewBox="-22 -22 44 44" style={{ position: "absolute", left: x - 22, top: y - 22, overflow: "visible" }}>
    {[
      [0, -16, 0, -4],
      [0, 4, 0, 16],
      [-16, 0, -4, 0],
      [4, 0, 16, 0],
    ].map(([a, b, c, d], i) => (
      <g key={i}>
        <line x1={a} y1={b} x2={c} y2={d} stroke="#000" strokeWidth="3.4" strokeLinecap="round" opacity="0.6" />
        <line x1={a} y1={b} x2={c} y2={d} stroke="#fff" strokeWidth="1.6" strokeLinecap="round" />
      </g>
    ))}
  </svg>
);

export const TextExtractor: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const copy = cueFrame(shot, "copy");
  const end = shot.frames;
  const corner = at({ x: SEL.x + SEL.w, y: SEL.y + SEL.h });
  const blur = kf(f, [[-8, 14], [34, 0]], ease.outSoft);
  const BAR = SCENES.textSel.marks!.bar;
  const region = { x: X + SEL.x * S, y: Y + SEL.y * S, w: SEL.w * S, h: (BAR.y + BAR.h - SEL.y) * S };
  const wide = fit({ x: X, y: Y, w: SCENES.textSel.w * S, h: SCENES.textSel.h * S }, 1.2, 1.12);
  const v = views(f, [
    [-8, { ...wide, zoom: wide.zoom * 1.12 }],
    [40, wide],
    [copy - 10, fit(region, 1.38, 0.8)],
    [end + 12, fit(region, 1.38, 0.86)],
  ]);
  const flash = f >= copy ? Math.exp(-(f - copy) / 9) : 0;
  const tl = at({ x: SEL.x, y: SEL.y });
  return (
    <AbsoluteFill>
      <Camera {...v} blur={blur}>
        <Wallpaper rect={sceneRect("textSel", X, Y, S)} dim={SCENES.textSel.dim} />
        <SceneImg name="textSel" x={X} y={Y} scale={S} />
        {flash > 0.01 && (
          <div
            style={{
              position: "absolute",
              left: tl.x,
              top: tl.y,
              width: SEL.w * S,
              height: SEL.h * S,
              boxShadow: `0 0 ${30 * flash}px rgba(255,255,255,${0.7 * flash}), inset 0 0 0 ${2}px rgba(255,255,255,${flash})`,
              background: `rgba(255,255,255,${0.12 * flash})`,
            }}
          />
        )}
        <Crosshair x={corner.x} y={corner.y} />
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
