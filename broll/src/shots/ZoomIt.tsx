// 4e · ZoomIt: the annotated screen, then the camera does what ZoomIt does — zooms in.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, SceneImg, sceneRect, Wallpaper } from "../components/World";
import { ease, kf } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";

const S = 0.6;
const X = (1920 - SCENES.zoomDraw.w * S) / 2;
const Y = (1080 - SCENES.zoomDraw.h * S) / 2 + 10;
const N = SCENES.zoomDraw.marks!.note;
const NOTE = { x: X + (N.x + N.w / 2) * S, y: Y + (N.y + N.h / 2) * S };

export const ZoomIt: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const z = cueFrame(shot, "zoom");
  const end = shot.frames;
  const zoom = kf(f, [[-10, 1.0], [z, 1.04], [z + 26, 1.56], [end + 14, 1.6]], ease.inOut);
  const cx = kf(f, [[-10, 960], [z, 960], [z + 26, NOTE.x - 60], [end + 14, NOTE.x - 40]], ease.inOut);
  const cy = kf(f, [[-10, 540], [z, 530], [z + 26, NOTE.y - 70], [end + 14, NOTE.y - 60]], ease.inOut);
  const rx = kf(f, [[-10, 4], [z, 1], [end, 0]], ease.inOut);
  return (
    <AbsoluteFill>
      <Camera cx={cx} cy={cy} zoom={zoom} rx={rx}>
        <Wallpaper rect={sceneRect("zoomDraw", X, Y, S)} />
        <SceneImg name="zoomDraw" x={X} y={Y} scale={S} />
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
