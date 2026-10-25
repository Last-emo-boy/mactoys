// 4i · Mouse Utilities: Find My Mouse (double-tap Left ⌃) spotlights the pointer; Mouse Jump (⌃⌥J)
// shows every display — and we jump into one.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, SceneImg, sceneRect, Wallpaper } from "../components/World";
import { clamp, ease, ep, kf, mix, sp, SPRINGS } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";

const S = 0.75;
const X = (1920 - SCENES.findMouse.w * S) / 2;
const Y = (1080 - SCENES.findMouse.h * S) / 2;
const T = SCENES.jump.marks!.thumb;
const THUMB = { x: X + (T.x + T.w / 2) * S, y: Y + (T.y + T.h / 2) * S };
const JC = SCENES.jump.marks!.cursor;
const JUMP_CURSOR = { x: X + JC.x * S, y: Y + JC.y * S };
const JW = SCENES.jump.win!;
const PANEL_C = { x: X + (JW.x + JW.w / 2) * S, y: Y + (JW.y + JW.h / 2) * S };

export const MouseUtils: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const find = cueFrame(shot, "find");
  const jump = cueFrame(shot, "jump");
  const pick = cueFrame(shot, "pickDisplay");
  const end = shot.frames;
  const x = ep(f, jump - 8, jump + 6, ease.inOut);
  const pop = sp(f, jump - 2, SPRINGS.pop);
  const zoom = kf(f, [[-16, 1.28], [find + 30, 1.05], [jump - 8, 1.1], [jump + 10, 1.16], [pick, 1.2], [end + 14, 1.32]], ease.inOut);
  const cx = kf(f, [[pick - 10, 960], [end + 14, THUMB.x]], ease.inOut);
  const cy = kf(f, [[pick - 10, 540], [end + 14, THUMB.y]], ease.inOut);
  const ripple = f >= pick ? clamp((f - pick) / 26) : 0;
  return (
    <AbsoluteFill>
      <Camera cx={cx} cy={cy} zoom={zoom}>
        <Wallpaper rect={sceneRect("findMouse", X, Y, S)} dim={mix(SCENES.findMouse.dim!, 1, x)} />
        {x < 1 && <SceneImg name="findMouse" x={X} y={Y} scale={S} opacity={1 - x} />}
        {x > 0 && (
          <div
            style={{
              position: "absolute",
              inset: 0,
              transformOrigin: `${PANEL_C.x}px ${PANEL_C.y}px`,
              transform: `scale(${mix(0.88, 1, pop)})`,
              opacity: clamp(pop * 2) * x,
            }}
          >
            <SceneImg name="jump" x={X} y={Y} scale={S} clipWin shadow />
          </div>
        )}
        {ripple > 0 && ripple < 1 && (
          <div
            style={{
              position: "absolute",
              left: JUMP_CURSOR.x - 10 - ripple * 40,
              top: JUMP_CURSOR.y - 10 - ripple * 40,
              width: 20 + ripple * 80,
              height: 20 + ripple * 80,
              borderRadius: "50%",
              boxShadow: `0 0 0 2px rgba(255,255,255,${0.8 * (1 - ripple)})`,
            }}
          />
        )}
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
