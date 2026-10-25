// 6 · Speaks your language: the Settings window from the last shot slides aside and its UI runs through
// every exported language while a wheel of their native names rolls beside it; it settles on the film
// language. Only in the timeline when more than one UI language is exported.

import React from "react";
import { AbsoluteFill } from "remotion";
import { manifestFor } from "../assets";
import { BEAT, HEIGHT } from "../config";
import { useFilm, useLocalFrame, useShot } from "../context";
import { AppCaption, MenuBar } from "../components/Chrome";
import { SettingsWindow } from "../components/SettingsWindow";
import { Camera } from "../components/World";
import { clamp, ease, ep, kf, mix, px, sp } from "../motion";
import { fontFor } from "../theme";
import { cueFrame, languageOrder } from "../timeline";
import { Desktop } from "./common";
import { SETTINGS_END, WIN_X, WIN_Y } from "./Settings";

const ROW = 100;
const WHEEL_X = 150;
const WHEEL_Y = 500;
const WHEEL_W = 600;

export const Languages: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const { lang, index, copy } = useFilm();
  const order = languageOrder(index.langs);
  const end = shot.frames;
  const at = order.map((_, i) => cueFrame(shot, `lang${i}`));
  const settle = cueFrame(shot, "settle");
  const target = Math.max(0, order.indexOf(lang));

  // which UI language the window shows, and the wheel position (springs from one name to the next)
  let ui = 0;
  for (let i = 0; i < order.length; i++) if (f >= at[i]) ui = i;
  if (f >= settle) ui = target;
  const roll = { damping: 20, stiffness: 190, mass: 0.6 };
  let c = 0;
  for (let i = 1; i < order.length; i++) c += sp(f, at[i] - 2, roll);
  c += (target - (order.length - 1)) * sp(f, settle - 3, { damping: 24, stiffness: 120 });
  const uiLang = order[ui];

  // the window slides right and turns toward the wheel
  const slide = ep(f, -6, at[0] + 20, ease.inOut);
  const dx = mix(0, 330, slide);
  const zoom = kf(f, [[0, SETTINGS_END.zoom], [at[0] + 20, 0.9], [end + 14, 0.93]], ease.inOut);
  const ry = kf(f, [[0, SETTINGS_END.ry], [at[0] + 20, -11], [end + 14, -8]], ease.inOut);
  const rx = kf(f, [[0, SETTINGS_END.rx], [end + 14, 3]], ease.inOut);
  const pageScroll = kf(f, [[0, SETTINGS_END.pageScroll], [end, 220]], ease.inOut);
  const flip = Math.max(0, ...at.slice(1).map((t) => (f >= t ? Math.exp(-(f - t) / 5) : 0)), f >= settle ? Math.exp(-(f - settle) / 6) : 0);

  const wheelIn = ep(f, at[0] - 10, at[0] + 18, ease.out);
  const wheelOut = ep(f, end - 4, end + 12, ease.in);
  return (
    <AbsoluteFill>
      <Camera zoom={zoom} rx={rx} ry={ry} perspective={2200}>
        <Desktop />
        <MenuBar />
        <div style={{ position: "absolute", left: WIN_X + dx, top: WIN_Y, filter: flip > 0.02 ? `brightness(${1 + 0.06 * flip})` : undefined }}>
          <SettingsWindow ui={uiLang} selected={0} sidebarScroll={0} pageScroll={pageScroll} pageIn={1 - 0.5 * flip} />
        </div>
      </Camera>
      {/* a soft shade under the wheel */}
      <AbsoluteFill style={{ background: `linear-gradient(90deg, rgba(8,6,32,${0.42 * wheelIn}) 0%, rgba(8,6,32,${0.2 * wheelIn}) 34%, rgba(8,6,32,0) 52%)` }} />
      <div
        style={{
          position: "absolute",
          left: WHEEL_X,
          top: 0,
          width: WHEEL_W,
          height: HEIGHT,
          opacity: wheelIn * (1 - wheelOut),
          transform: `translateX(${px((1 - wheelIn) * -40)}px)`,
          maskImage: `linear-gradient(180deg, transparent ${WHEEL_Y - ROW * 3.2}px, #000 ${WHEEL_Y - ROW * 1.4}px, #000 ${WHEEL_Y + ROW * 1.4}px, transparent ${WHEEL_Y + ROW * 3.2}px)`,
          WebkitMaskImage: `linear-gradient(180deg, transparent ${WHEEL_Y - ROW * 3.2}px, #000 ${WHEEL_Y - ROW * 1.4}px, #000 ${WHEEL_Y + ROW * 1.4}px, transparent ${WHEEL_Y + ROW * 3.2}px)`,
        }}
      >
        {order.map((l, i) => {
          const d = i - c;
          if (Math.abs(d) > 3.6) return null;
          const name = manifestFor(index, l).languageName;
          const near = clamp(1 - Math.abs(d));
          const size = Math.min(mix(46, 88, near), (WHEEL_W / Math.max(4, [...name].length)) * 1.75);
          return (
            <div
              key={l}
              lang={l}
              style={{
                position: "absolute",
                left: 0,
                top: WHEEL_Y + d * ROW - ROW / 2,
                height: ROW,
                width: WHEEL_W,
                display: "flex",
                alignItems: "center",
                fontFamily: fontFor(l),
                fontSize: size,
                fontWeight: near > 0.5 ? 700 : 600,
                letterSpacing: "-0.03em",
                whiteSpace: "nowrap",
                color: `rgba(255,255,255,${mix(0.34, 1, near)})`,
                transform: `perspective(900px) rotateX(${clamp(-d, -3, 3) * 14}deg)`,
                transformOrigin: "0% 50%",
                textShadow: near > 0.5 ? "0 4px 30px rgba(20,0,60,0.35)" : undefined,
              }}
            >
              {name}
            </div>
          );
        })}
      </div>
      <AppCaption line={copy.languages} appear={settle - BEAT * 0.5} leave={end - 18} />
    </AbsoluteFill>
  );
};
