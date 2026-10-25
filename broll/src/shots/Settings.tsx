// 5 · Every setting: the sidebar runs through all utilities on sixteenth notes while the content
// column flips through their exported pages; it lands back on Home.

import React from "react";
import { AbsoluteFill } from "remotion";
import { BEAT } from "../config";
import { useFilm, useLocalFrame, useShot } from "../context";
import { AppCaption, MenuBar } from "../components/Chrome";
import { sidebarScrollFor, SettingsWindow, SW } from "../components/SettingsWindow";
import { Camera } from "../components/World";
import { ease, ep, kf, mix, sp } from "../motion";
import { SETTINGS_FIRST, SETTINGS_HOME, SETTINGS_ITEMS, SETTINGS_STEP } from "../timeline";
import { Desktop } from "./common";

export const WIN_X = 960 - SW.w / 2;
export const WIN_Y = 540 - SW.h / 2;
/** End state shared with the language shot (which continues this one). */
export const SETTINGS_END = { ry: -3, rx: 1.5, zoom: 0.97, pageScroll: 300 };

/** Selected item at local frame f, plus frames since it was selected. */
export function settingsSelection(f: number): { index: number; since: number } {
  const home = SETTINGS_HOME * BEAT;
  if (f >= home) return { index: 0, since: f - home };
  const k = Math.floor((f - SETTINGS_FIRST * BEAT) / (SETTINGS_STEP * BEAT));
  if (k < 0) return { index: 0, since: f + 999 };
  const i = Math.min(SETTINGS_ITEMS, k + 1);
  return { index: i, since: f - (SETTINGS_FIRST + (i - 1) * SETTINGS_STEP) * BEAT };
}

export const Settings: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const { lang, index, copy } = useFilm();
  const sidebar = (index.manifests[lang] ?? index.manifests.en).sidebar;
  const end = shot.frames;
  const home = SETTINGS_HOME * BEAT;
  const { index: sel, since } = settingsSelection(f);

  // sidebar scroll glides between the targets of consecutive steps
  const stepF = SETTINGS_STEP * BEAT;
  const prevSel = settingsSelection(f - stepF).index;
  const glide = ep(since, 0, Math.min(stepF, 7), ease.outSoft);
  let scroll = mix(sidebarScrollFor(sidebar, prevSel), sidebarScrollFor(sidebar, sel), glide);
  if (f >= home) scroll = mix(sidebarScrollFor(sidebar, SETTINGS_ITEMS), 0, sp(f, home - 2, { damping: 22, stiffness: 160 }));
  const pageIn = ep(since, 0, 6, ease.out);
  const pageScroll = kf(f, [[home + 20, 0], [end, SETTINGS_END.pageScroll]], ease.inOut);

  const ry = kf(f, [[-12, 9], [home, 3], [end, SETTINGS_END.ry]], ease.inOut);
  const rx = kf(f, [[-12, 5], [end, SETTINGS_END.rx]], ease.inOut);
  const zoom = kf(f, [[-12, 1.04], [home, 1.06], [end, SETTINGS_END.zoom]], ease.inOut);
  return (
    <AbsoluteFill>
      <Camera zoom={zoom} rx={rx} ry={ry} perspective={2200}>
        <Desktop />
        <MenuBar />
        <div style={{ position: "absolute", left: WIN_X, top: WIN_Y }}>
          <SettingsWindow ui={lang} selected={sel} sidebarScroll={scroll} pageScroll={pageScroll} pageIn={f >= home ? ep(since, 0, 10) : pageIn} />
        </div>
      </Camera>
      <AppCaption line={copy.settings} appear={home + 6} leave={end - 18} />
    </AbsoluteFill>
  );
};
