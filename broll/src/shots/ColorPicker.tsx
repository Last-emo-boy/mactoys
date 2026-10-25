// 4c · Color Picker: the loupe over a page, a click, and the editor opens out of the loupe.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { MenuBar } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, Flat, SceneImg, WindowFrame } from "../components/World";
import { ease, ep, kf, mix } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const S = 0.78;
const PX = (1920 - SCENES.picker.w * S) / 2;
const PY = (1080 - SCENES.picker.h * S) / 2 + 6;
const L = SCENES.picker.marks!.loupe;
const LOUPE = { x: PX + (L.x + L.w / 2) * S, y: PY + (L.y + L.h / 2) * S, r: (L.w / 2) * S };
const ES = 0.74;
const EW = SCENES.pickerEditor.w * ES,
  EH = SCENES.pickerEditor.h * ES;

export const ColorPicker: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const pick = cueFrame(shot, "pick");
  const end = shot.frames;

  // page camera: lean into the loupe
  const z = ep(f, -10, pick + 4, ease.inOut);
  const zoom = mix(1.0, 1.26, z);
  const cx = mix(960, mix(960, LOUPE.x, 0.62), z);
  const cy = mix(540, mix(540, LOUPE.y, 0.62), z);
  // where the loupe sits on screen at the click
  const sx = (LOUPE.x - cx) * zoom + 960;
  const sy = (LOUPE.y - cy) * zoom + 540;
  const sr = LOUPE.r * zoom;

  const open = ep(f, pick, pick + 24, ease.inOut);
  const R = mix(sr * 0.96, 2300, open);
  const ez = kf(f, [[pick, 1.12], [pick + 30, 1.0], [end + 14, 1.06]], ease.outSoft);
  const ery = kf(f, [[pick, -6], [end + 14, 3]], ease.inOut);

  return (
    <AbsoluteFill>
      <Camera cx={cx} cy={cy} zoom={zoom}>
        <Flat color={SCENES.picker.flat!} />
        <SceneImg name="picker" x={PX} y={PY} scale={S} />
      </Camera>
      {f >= pick && (
        <AbsoluteFill style={{ clipPath: `circle(${R}px at ${sx}px ${sy}px)` }}>
          <Camera zoom={ez} ry={ery}>
            <Desktop />
            <MenuBar />
            <WindowFrame name="pickerEditor" x={960 - EW / 2} y={570 - EH / 2} scale={ES} radius={16} dark />
          </Camera>
          <div
            style={{
              position: "absolute",
              left: sx - R,
              top: sy - R,
              width: R * 2,
              height: R * 2,
              borderRadius: "50%",
              boxShadow: `inset 0 0 0 ${3 + 3 * (1 - open)}px rgba(255,255,255,${0.95 * (1 - open)}), inset 0 0 40px rgba(255,255,255,${0.35 * (1 - open)})`,
            }}
          />
        </AbsoluteFill>
      )}
      <ShotOverlay />
    </AbsoluteFill>
  );
};
