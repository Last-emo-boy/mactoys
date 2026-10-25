// 4h · Keyboard Manager: the remap list; a spotlight walks from a key remap to two shortcut remaps.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { MenuBar } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, fit, views, WindowFrame } from "../components/World";
import { ease, ep, kf, mix, sp } from "../motion";
import { SCENES, type Rect } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const S = 0.62;
const W = SCENES.keyboard.w * S,
  H = SCENES.keyboard.h * S;
const X = 960 - W / 2,
  Y = 566 - H / 2;
const ROWS: Rect[] = ["row0", "row1", "row2"].map((k) => SCENES.keyboard.marks![k]);

export const KeyboardManager: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const end = shot.frames;
  const at = [0, 1, 2].map((i) => cueFrame(shot, `focus${i}`));
  // spotlight rect, springing from row to row
  let r = ROWS[0];
  for (let i = 1; i < 3; i++) {
    const t = sp(f, at[i], { damping: 20, stiffness: 140 });
    r = { x: mix(r.x, ROWS[i].x, t), y: mix(r.y, ROWS[i].y, t), w: mix(r.w, ROWS[i].w, t), h: mix(r.h, ROWS[i].h, t) };
  }
  const on = ep(f, at[0] - 6, at[0] + 10, ease.out);
  const pad = 10;
  const sx = X + (r.x - pad) * S,
    sy = Y + (r.y - pad) * S,
    sw = (r.w + pad * 2) * S,
    sh = (r.h + pad * 2) * S;
  const WINR = { x: X, y: Y, w: W, h: H };
  const around = (i: number) => {
    const row = ROWS[i];
    return fit({ x: X + row.x * S, y: Y + (row.y + row.h / 2) * S - 210, w: row.w * S, h: 420 }, 1.42);
  };
  const v = views(f, [
    [-14, fit(WINR, 1.5, 0.94)],
    [at[0] - 8, fit(WINR, 1.5, 1)],
    [at[0] + 22, around(0)],
    [at[1] - 2, around(0)],
    [at[1] + 24, around(1)],
    [at[2] - 2, around(1)],
    [at[2] + 24, around(2)],
    [end + 14, { ...around(2), zoom: around(2).zoom * 1.04 }],
  ]);
  return (
    <AbsoluteFill>
      <Camera {...v} rx={kf(f, [[-14, -5], [end, 2]])}>
        <Desktop />
        <MenuBar />
        <WindowFrame name="keyboard" x={X} y={Y} scale={S} radius={16} />
        {on > 0 && (
          <div
            style={{
              position: "absolute",
              left: sx,
              top: sy,
              width: sw,
              height: sh,
              borderRadius: 14,
              boxShadow: `0 0 0 4000px rgba(12,10,40,${0.42 * on}), inset 0 0 0 2px rgba(10,132,255,${0.75 * on}), 0 0 30px rgba(10,132,255,${0.35 * on})`,
            }}
          />
        )}
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
