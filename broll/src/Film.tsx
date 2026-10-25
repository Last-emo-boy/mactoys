import React from "react";
import { AbsoluteFill, Audio, Sequence, staticFile, useCurrentFrame } from "remotion";
import { manifestFor, type AssetIndex } from "./assets";
import { Finish } from "./components/Chrome";
import { combine, look, LookLayer } from "./components/Transitions";
import type { FilmLang } from "./config";
import { FilmCtx, ShotProvider, type FilmContextValue } from "./context";
import { COPY } from "./copy";
import { SHOT_COMPONENTS } from "./shots";
import { useFonts } from "./fonts";
import type { PlacedShot, Timeline } from "./timeline";

export interface FilmProps {
  lang: FilmLang;
  index?: AssetIndex;
  timeline?: Timeline;
  audio?: string | null;
  [key: string]: unknown;
}

const ShotLayer: React.FC<{ shot: PlacedShot; next?: PlacedShot; pre: number }> = ({ shot, next, pre }) => {
  const frame = useCurrentFrame() - pre; // frames from this shot's cut
  const Comp = SHOT_COMPONENTS[shot.id];
  const enter = frame < shot.enter.post + 1 ? look(shot.enter, "in", frame) : null;
  const exit = next && frame > shot.frames - next.enter.pre - 1 ? look(next.enter, "out", frame - shot.frames) : null;
  const L = combine(enter, exit);
  return (
    <LookLayer look={L} id={shot.id}>
      <ShotProvider shot={shot} pre={pre}>
        <Comp />
      </ShotProvider>
    </LookLayer>
  );
};

export const Film: React.FC<FilmProps> = ({ lang, index, timeline, audio }) => {
  useFonts(lang);
  if (!index || !timeline) return <AbsoluteFill style={{ background: "#000" }} />;
  const ctx: FilmContextValue = { lang, index, timeline, manifest: manifestFor(index, lang), copy: COPY[lang] };
  const shots = timeline.shots;
  return (
    <FilmCtx.Provider value={ctx}>
      <AbsoluteFill style={{ background: "#05040f" }} lang={lang}>
        {shots.map((s, i) => {
          const next = shots[i + 1];
          const pre = s.index === 0 ? 0 : s.enter.pre;
          const tail = next ? next.enter.post : 0;
          return (
            <Sequence key={s.id} from={s.from - pre} durationInFrames={s.frames + pre + tail} layout="none" name={s.id}>
              <ShotLayer shot={s} next={next} pre={pre} />
            </Sequence>
          );
        })}
        <Finish />
        {audio ? <Audio src={staticFile(audio)} /> : null}
      </AbsoluteFill>
    </FilmCtx.Provider>
  );
};
