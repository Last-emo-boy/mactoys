// 4g · PowerRename: a regex and enumeration; the preview column fills row by row.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { MenuBar } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, fit, views, WindowFrame } from "../components/World";
import { ease, ep, kf } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const S = 0.6;
const W = SCENES.rename.w * S,
  H = SCENES.rename.h * S;
const X = 960 - W / 2,
  Y = 560 - H / 2;
const COL = SCENES.rename.marks!.renamed;

export const PowerRename: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const end = shot.frames;
  const rowAt = (i: number) => (i < 5 ? cueFrame(shot, `row${i}`) : cueFrame(shot, "row4") + 8);
  const WINR = { x: X, y: Y, w: W, h: H };
  const ROWS = { x: X + 640 * S, y: Y + 96 * S, w: 1320 * S, h: 470 * S };
  const v = views(f, [
    [-12, fit(WINR, 1.6, 0.94)],
    [rowAt(0) - 10, fit(WINR, 1.6, 1)],
    [rowAt(5) + 24, fit(ROWS, 1.5)],
    [end + 12, fit(ROWS, 1.56)],
  ]);
  return (
    <AbsoluteFill>
      <Camera {...v} ry={kf(f, [[-12, 4], [end, -2]])} rx={kf(f, [[-12, 3], [end, 0]])}>
        <Desktop />
        <MenuBar />
        <WindowFrame name="rename" x={X} y={Y} scale={S} radius={16}>
          {/* the preview column before each row's rename is computed (row backgrounds from the export) */}
          {Array.from({ length: 6 }, (_, i) => {
            const p = ep(f, rowAt(i), rowAt(i) + 12, ease.out);
            if (p >= 1) return null;
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  left: (COL.x + COL.w * p) * S,
                  top: (COL.y + i * COL.h) * S,
                  width: COL.w * (1 - p) * S,
                  height: COL.h * S,
                  background: i % 2 === 0 ? "#ffffff" : "#fafafa",
                }}
              />
            );
          })}
        </WindowFrame>
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
