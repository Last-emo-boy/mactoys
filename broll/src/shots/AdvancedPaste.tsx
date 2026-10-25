// 4f · Advanced Paste: the panel springs up with "Paste as…" (JSON highlighted); the camera leans into
// the list; then a custom action's result (Fix grammar).

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, fit, SceneImg, sceneRect, views, Wallpaper } from "../components/World";
import { clamp, ease, ep, kf, mix, sp, SPRINGS } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";

const S = 0.6;
const W = SCENES.pasteList.win!;
const X = 960 - (W.x + W.w / 2) * S;
const Y = 540 - (W.y + W.h / 2) * S;
const PANEL = { x: X + W.x * S, y: Y + W.y * S, w: W.w * S, h: W.h * S };
const TOP = { x: X + W.x * S, y: Y + W.y * S, w: W.w * S, h: 400 * S };
const LIST = { x: X + 92 * S, y: Y + 300 * S, w: 856 * S, h: 500 * S };

export const AdvancedPaste: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const result = cueFrame(shot, "result");
  const end = shot.frames;
  const pop = sp(f, 0, SPRINGS.pop);
  const x = ep(f, result - 2, result + 8, ease.inOut);
  const v = views(f, [
    [0, fit(PANEL, 1.6, 0.9)],
    [result - 34, fit(LIST, 1.62, 1)],
    [result + 2, fit(LIST, 1.62, 1)],
    [result + 34, fit(TOP, 1.5)],
    [end + 20, fit(TOP, 1.56)],
  ]);
  const rx = kf(f, [[0, 7], [result, 2], [end + 20, -2.5]], ease.inOut);
  const ry = kf(f, [[0, -10], [result, -2], [end + 20, 6]], ease.inOut);
  const win = { transformOrigin: `960px 540px`, transform: `scale(${mix(0.9, 1, pop)}) translateY(${(1 - pop) * 24}px)`, opacity: clamp(pop * 2.4) };
  return (
    <AbsoluteFill>
      <Camera {...v} rx={rx} ry={ry} perspective={2000}>
        <Wallpaper rect={sceneRect("pasteList", X, Y, S)} />
        <div style={{ position: "absolute", inset: 0, ...win }}>
          {x < 1 && <SceneImg name="pasteList" x={X} y={Y} scale={S} clipWin shadow />}
          {x > 0 && <SceneImg name="pasteGrammar" x={X} y={Y} scale={S} clipWin shadow opacity={x} />}
        </div>
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
