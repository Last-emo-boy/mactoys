// 4k · Up to the menu bar: Awake's menu from its cup, then Power Display's flyout with ⌃⌥B.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useLocalFrame, useShot } from "../context";
import { arc, Cursor, MENU_H, MenuBar, menuItemX } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, SceneImg } from "../components/World";
import { clamp, ease, ep, kf, mix, sp, SPRINGS } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const S = 0.62;
const TOP = MENU_H + 5;
const cupX = menuItemX("awake");
const sunX = menuItemX("display");
const AW = SCENES.awake.win!;
const DW = SCENES.display.win!;
const AWAKE_LEFT = cupX - 26;
const DISPLAY_LEFT = sunX - 250;

export const Awake: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const click = cueFrame(shot, "click");
  const flyout = cueFrame(shot, "flyout");
  const end = shot.frames;

  const menu = sp(f, click + 1, SPRINGS.pop);
  const close = ep(f, flyout - 10, flyout - 2, ease.in);
  const fly = sp(f, flyout, SPRINGS.pop);

  const travel = ep(f, -14, click - 3, ease.inOut);
  const [px0, py0] = arc([1220, 560], [cupX + 1, 16], travel, 0.14);
  const press = f >= click - 3 ? Math.exp(-Math.max(0, f - click) / 4) * clamp((f - click + 3) / 3) : 0;
  const away = ep(f, flyout - 30, flyout, ease.inOut);
  const pointer = { x: mix(px0, cupX - 140, away), y: mix(py0, 330, away) };

  const zoom = kf(f, [[-14, 1.0], [click + 10, 1.32], [flyout - 6, 1.36], [end + 14, 1.4]], ease.inOut);
  const cx = kf(f, [[-14, 1140], [click + 10, AWAKE_LEFT + 150], [flyout - 6, AWAKE_LEFT + 60], [flyout + 20, DISPLAY_LEFT + 230], [end + 14, DISPLAY_LEFT + 240]], ease.inOut);
  const cy = kf(f, [[-14, 470], [click + 10, 300], [flyout + 20, TOP + 230], [end + 14, TOP + 236]], ease.inOut);

  return (
    <AbsoluteFill>
      <Camera cx={cx} cy={cy} zoom={zoom}>
        <Desktop />
        <MenuBar highlight={f < flyout - 6 ? "awake" : "display"} highlightAmount={f < flyout - 6 ? ep(f, click - 2, click + 2) * (1 - close) : ep(f, flyout - 4, flyout)} />
        {f >= click && close < 1 && (
          <div style={{ position: "absolute", inset: 0, transformOrigin: `${cupX}px ${TOP}px`, transform: `scale(${mix(0.92, 1, menu)})`, opacity: clamp(menu * 3) * (1 - close) }}>
            <SceneImg name="awake" x={AWAKE_LEFT - AW.x * S} y={TOP - AW.y * S} scale={S} clipWin shadow />
          </div>
        )}
        {f >= flyout && (
          <div style={{ position: "absolute", inset: 0, transformOrigin: `${sunX}px ${TOP}px`, transform: `translateY(${(1 - fly) * -10}px) scale(${mix(0.9, 1, fly)})`, opacity: clamp(fly * 2.5) }}>
            <SceneImg name="display" x={DISPLAY_LEFT - DW.x * S} y={TOP - DW.y * S} scale={S} clipWin shadow />
          </div>
        )}
        <Cursor x={pointer.x} y={pointer.y} press={press} />
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
