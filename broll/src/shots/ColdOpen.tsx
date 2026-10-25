// 1 · A quiet desktop. The pointer finds the MacToys item in the menu bar; Quick Access springs open.

import React from "react";
import { WIDTH } from "../config";
import { useLocalFrame, useShot } from "../context";
import { arc, Cursor, MENU_H, MenuBar, menuItemX } from "../components/Chrome";
import { Camera, SceneImg } from "../components/World";
import { clamp, ease, ep, kf, mix, sp, SPRINGS } from "../motion";
import { SCENES } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const SCALE = 0.5;
export const QA_W = SCENES.quickaccess.w * SCALE;
export const QA_H = SCENES.quickaccess.h * SCALE;
export const qaLeft = () => Math.min(menuItemX("mactoys") - QA_W / 2, WIDTH - 12 - QA_W);
export const QA_TOP = MENU_H + 7;

export const ColdOpen: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const hover = cueFrame(shot, "hover");
  const click = cueFrame(shot, "click");
  const end = shot.frames;
  const ix = menuItemX("mactoys");
  const left = qaLeft();

  // pointer: drifts in, arcs up to the menu bar item
  const travel = ep(f, 32, hover, ease.inOut);
  const [px0, py0] = arc([1010, 690], [ix + 1, 15], travel, -0.16);
  const press = f >= click - 3 ? Math.exp(-Math.max(0, f - click) / 4) * clamp((f - click + 3) / 3) : 0;
  const cursorIn = ep(f, 14, 40, ease.out);

  // the flyout springs from the item
  const open = sp(f, click + 1, SPRINGS.pop);
  const menuHi = Math.max(ep(f, hover - 6, hover + 2), f >= click ? 1 : 0);

  // camera: a breath of push-in, then glide into the flyout
  const z = ep(f, click + 6, end + 10, ease.inOut);
  const cx = mix(kf(f, [[0, 940], [click, 960]]), left + QA_W / 2, z);
  const cy = mix(kf(f, [[0, 560], [click, 540]]), QA_TOP + QA_H / 2 + 8, z);
  const zoom = mix(kf(f, [[0, 1.06], [click, 1.0]], ease.outSoft), 1.5, ease.in(z) * 0.35 + z * 0.65);

  return (
    <Camera cx={cx} cy={cy} zoom={zoom}>
      <Desktop />
      <MenuBar highlight="mactoys" highlightAmount={menuHi} />
      {f >= click && (
        <div
          style={{
            position: "absolute",
            left,
            top: QA_TOP,
            width: QA_W,
            height: QA_H,
            transformOrigin: `${ix - left}px 0px`,
            transform: `translateY(${(1 - open) * -10}px) scale(${mix(0.9, 1, open)})`,
            opacity: clamp(open * 2.5),
          }}
        >
          <SceneImg name="quickaccess" x={0} y={0} scale={SCALE} clipWin shadow />
          <div style={{ position: "absolute", inset: 0, borderRadius: 18, boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.55), inset 0 1px 0 rgba(255,255,255,0.9)" }} />
        </div>
      )}
      <Cursor x={px0} y={py0} press={press} opacity={cursorIn} />
    </Camera>
  );
};
