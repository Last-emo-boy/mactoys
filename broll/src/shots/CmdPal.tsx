// 4a · Command Palette: ⌥ Space, the bar springs open, "time" is typed, the results unfold.

import React from "react";
import { AbsoluteFill } from "remotion";
import { useAppFile, useLocalFrame, useShot } from "../context";
import { MenuBar } from "../components/Chrome";
import { ShotOverlay } from "../components/ShotOverlay";
import { Camera, fit, SceneImg, views } from "../components/World";
import { clamp, ease, kf, mix, sp, SPRINGS } from "../motion";
import { QUERY_EDGES, QUERY_TEXT_LEFT, SCENES } from "../scenes";
import { cueFrame } from "../timeline";
import { Desktop } from "./common";

const S = 0.5;
const P = SCENES.palette;
const WIN = P.win!;
const WIN_TOP = 268; // world y of the window's top edge
const IMG_X = 960 - (WIN.x + WIN.w / 2) * S;
const IMG_Y = WIN_TOP - WIN.y * S;
const COMPACT_H = SCENES.compact.win!.h;

/** A rectangle of an image, painted from elsewhere in the same image (empty glass to hide text). */
const Patch: React.FC<{ src: string; imgW: number; imgH: number; rect: { x: number; y: number; w: number; h: number }; from: { x: number; y: number }; opacity?: number; feather?: number }> = ({
  src,
  imgW,
  imgH,
  rect,
  from,
  opacity = 1,
  feather = 0,
}) => (
  <div
    style={{
      position: "absolute",
      left: rect.x * S,
      top: rect.y * S,
      width: rect.w * S,
      height: rect.h * S,
      opacity,
      backgroundImage: `url(${src})`,
      backgroundSize: `${imgW * S}px ${imgH * S}px`,
      backgroundPosition: `${-from.x * S}px ${-from.y * S}px`,
      WebkitMaskImage: feather ? `linear-gradient(90deg, transparent, #000 ${feather}px, #000 calc(100% - ${feather}px), transparent)` : undefined,
    }}
  />
);

export const CmdPal: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const palette = useAppFile(P.file);
  const compact = useAppFile(SCENES.compact.file);
  const open = cueFrame(shot, "open");
  const typed = [0, 1, 2, 3].filter((i) => f >= cueFrame(shot, `type${i}`)).length;
  const expandAt = cueFrame(shot, "expand");
  const end = shot.frames;

  const pop = sp(f, open, SPRINGS.pop);
  const grow = sp(f, expandAt, { damping: 20, mass: 0.8, stiffness: 150 });
  const clipH = mix(COMPACT_H, WIN.h, grow);

  // the query: hide untyped letters under empty glass from just right of the text
  const text = P.marks!.text;
  const shownRight = typed === 0 ? text.x : QUERY_EDGES[typed - 1] + 1;
  const cover = { x: shownRight, y: text.y, w: text.x + text.w - shownRight, h: text.h };
  const ph = SCENES.compact.marks!.placeholder;
  const dy = SCENES.compact.win!.y - WIN.y; // compact image → palette image rows
  const caretX = typed === 0 ? QUERY_TEXT_LEFT + 2 : QUERY_EDGES[typed - 1] + 4;
  const lastType = typed > 0 ? cueFrame(shot, `type${typed - 1}`) : open;
  const blink = f - lastType < 20 ? 1 : 0.5 + 0.5 * Math.cos(((f - lastType - 20) / 30) * Math.PI * 2);

  // camera: close on the bar while typing, settle as it unfolds, then lean into the answer
  const BARR = { x: 960 - (WIN.w * S) / 2, y: WIN_TOP, w: WIN.w * S, h: COMPACT_H * S };
  const FULL = { ...BARR, h: WIN.h * S };
  const ANSWER = { x: BARR.x + 150, y: WIN_TOP, w: BARR.w - 150, h: FULL.h * 0.78 };
  const typingView = fit(BARR, 1.42, 1, { x: 100, y: 362, w: 1720, h: 200 });
  const v = views(f, [
    [0, typingView],
    [expandAt - 4, { ...typingView, zoom: typingView.zoom * 1.02 }],
    [expandAt + 30, fit(FULL, 1.44)],
    [end + 20, fit(ANSWER, 1.62)],
  ]);
  const ry = kf(f, [[0, -4], [end, 3]], ease.inOut);

  const winOn = f >= open - 1;
  return (
    <AbsoluteFill>
      <Camera {...v} ry={ry}>
        <Desktop />
        <MenuBar />
        {winOn && (
          <div
            style={{
              position: "absolute",
              left: 0,
              top: 0,
              width: 1920,
              height: 1080,
              transformOrigin: `960px ${WIN_TOP}px`,
              transform: `translateY(${(1 - pop) * -16}px) scale(${mix(0.94, 1, pop)})`,
              opacity: clamp(pop * 2.2),
            }}
          >
            <SceneImg name="palette" x={IMG_X} y={IMG_Y} scale={S} clipWin clipHeight={clipH} shadow>
              {/* empty glass over the letters not typed yet */}
              {cover.w > 0 && <Patch src={palette} imgW={P.w} imgH={P.h} rect={cover} from={{ x: cover.x + 92, y: cover.y }} />}
              {/* the placeholder, from the compact export, until the first key */}
              {typed === 0 && (
                <Patch src={compact} imgW={SCENES.compact.w} imgH={SCENES.compact.h} rect={{ ...ph, y: ph.y - dy }} from={{ x: ph.x, y: ph.y }} feather={6} />
              )}
              <div
                style={{
                  position: "absolute",
                  left: caretX * S,
                  top: P.marks!.caret.y * S,
                  width: 2,
                  height: P.marks!.caret.h * S,
                  borderRadius: 1,
                  background: "#3b8cff",
                  opacity: blink,
                }}
              />
              {/* the window edge under the growing bar */}
              <div
                style={{
                  position: "absolute",
                  left: WIN.x * S,
                  top: WIN.y * S,
                  width: WIN.w * S,
                  height: clipH * S,
                  borderRadius: (WIN.r ?? 0) * S,
                  boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.13)",
                }}
              />
            </SceneImg>
          </div>
        )}
      </Camera>
      <ShotOverlay />
    </AbsoluteFill>
  );
};
