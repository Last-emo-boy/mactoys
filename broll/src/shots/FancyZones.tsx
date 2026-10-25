// 4b · FancyZones: the layout editor with Priority Grid, then a window dragged over its zones with ⇧ held.

import React from "react";
import { AbsoluteFill } from "remotion";
import { WIDTH } from "../config";
import { useLocalFrame, useShot } from "../context";
import { Cursor } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, SceneImg, Wallpaper } from "../components/World";
import { ease, ep, kf, mix } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";

const Y = -60;
const S_ED = WIDTH / SCENES.fzEditor.w;
const S_DR = WIDTH / SCENES.fzDragging.w;
const EDITOR_DIM = 0.79;

export const FancyZones: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const drag = cueFrame(shot, "drag");
  const end = shot.frames;
  const x = ep(f, drag - 4, drag + 10, ease.inOut);
  const ry = kf(f, [[-10, 9], [drag, 2.5], [end + 12, -3.5]], ease.inOut);
  const rx = kf(f, [[-10, 6], [drag, 2], [end + 12, 1]], ease.inOut);
  const zoom = kf(f, [[-10, 1.1], [drag, 1.06], [end + 12, 1.16]], ease.inOut);
  const cx = kf(f, [[drag, 960], [end + 12, 1000]], ease.inOut);
  const cy = kf(f, [[drag, 540], [end + 12, 470]], ease.inOut);
  const grab = { x: 1300 * S_DR, y: 549 * S_DR + Y };
  return (
    <AbsoluteFill>
      <Camera cx={cx} cy={cy} zoom={zoom} rx={rx} ry={ry} perspective={2200}>
        <Wallpaper rect={{ x: 0, y: Y, w: 1920, h: 1200 }} dim={mix(EDITOR_DIM, 1, x)} />
        <SceneImg name="fzDragging" x={0} y={Y} scale={S_DR} opacity={x} />
        <SceneImg name="fzEditor" x={0} y={Y} scale={S_ED} opacity={1 - x} style={{ transform: `scale(${1 + x * 0.03})`, transformOrigin: "50% 50%" }} />
        {x > 0.5 && <Cursor x={grab.x} y={grab.y} press={0.6} opacity={ep(f, drag + 2, drag + 10)} />}
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
