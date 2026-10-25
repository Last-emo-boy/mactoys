// 4l · Workspaces: the "Deep work" set of apps and windows; Launch, and the progress panel.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { arc, Cursor, MenuBar } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, SceneImg, WindowFrame } from "../components/World";
import { clamp, ease, ep, kf, mix, sp, SPRINGS } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const S = 0.5;
const W = SCENES.workspaces.w * S,
  H = SCENES.workspaces.h * S;
const X = 960 - W / 2,
  Y = 590 - H / 2;
const LB = SCENES.workspaces.marks!.launch;
const LAUNCH = { x: X + (LB.x + LB.w / 2) * S, y: Y + (LB.y + LB.h / 2) * S };
const PS = 0.62;
const PW = SCENES.launching.win!;

export const Workspaces: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const launch = cueFrame(shot, "launch");
  const progress = cueFrame(shot, "progress");
  const end = shot.frames;
  const travel = ep(f, 20, launch - 3, ease.inOut);
  const [cx0, cy0] = arc([1180, 760], [LAUNCH.x - 6, LAUNCH.y + 4], travel, -0.12);
  const press = f >= launch - 3 ? Math.exp(-Math.max(0, f - launch) / 4) * clamp((f - launch + 3) / 3) : 0;
  const pop = sp(f, progress, SPRINGS.pop);
  const zoom = kf(f, [[-14, 1.12], [24, 1.0], [launch, 1.04], [progress + 24, 1.3], [end + 14, 1.36]], ease.inOut);
  const cx = kf(f, [[24, 960], [launch, 1060], [progress + 24, 960]], ease.inOut);
  const cy = kf(f, [[24, 560], [launch, 470], [progress + 24, 560]], ease.inOut);
  const dim = ep(f, progress, progress + 14);
  return (
    <AbsoluteFill>
      <Camera cx={cx} cy={cy} zoom={zoom}>
        <Desktop />
        <MenuBar />
        <WindowFrame name="workspaces" x={X} y={Y} scale={S} radius={16} trafficLights={{ x: 20, y: 20 }} />
        {dim > 0 && <div style={{ position: "absolute", left: -2000, top: -2000, width: 6000, height: 6000, background: `rgba(10,8,35,${0.28 * dim})` }} />}
        {f >= progress && (
          <div style={{ position: "absolute", inset: 0, transformOrigin: "960px 560px", transform: `scale(${mix(0.86, 1, pop)})`, opacity: clamp(pop * 2.4) }}>
            <SceneImg name="launching" x={960 - (PW.x + PW.w / 2) * PS} y={560 - (PW.y + PW.h / 2) * PS} scale={PS} clipWin shadow />
          </div>
        )}
        <Cursor x={cx0} y={cy0} press={press} opacity={ep(f, 12, 28) * (1 - ep(f, progress + 6, progress + 16))} />
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
