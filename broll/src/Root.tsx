import React from "react";
import { Composition, Still, staticFile, type CalculateMetadataFunction } from "remotion";
import { resolveAssets, type AssetIO } from "./assets";
import { FPS, HEIGHT, WIDTH } from "./config";
import { Film, type FilmProps } from "./Film";
import { Loop, LOOP_FRAMES, type LoopProps } from "./Loop";
import { Poster, type PosterProps } from "./Poster";
import { SCENE_FILES } from "./shots";
import { buildTimeline } from "./timeline";

const io: AssetIO = {
  async exists(rel) {
    const r = await fetch(staticFile(rel), { method: "HEAD", cache: "no-store" });
    return r.ok;
  },
  async json(rel) {
    const r = await fetch(staticFile(rel), { cache: "no-store" });
    if (!r.ok) throw new Error(`missing ${rel} — run scripts/export-assets.sh`);
    return r.json();
  },
};

/** Resolves languages and files at render time; the timeline (and so the duration) follows them. */
const filmMetadata: CalculateMetadataFunction<FilmProps> = async ({ props }) => {
  const index = await resolveAssets(io, SCENE_FILES);
  const timeline = buildTimeline(index.langs);
  let audio: string | null = null;
  try {
    const r = await fetch(staticFile("audio/mix.json"), { cache: "no-store" });
    if (r.ok) {
      const meta = (await r.json()) as { frames: number; langs: string[] };
      if (meta.frames === timeline.frames && meta.langs.join() === index.langs.join()) audio = "audio/mix.wav";
      else console.warn("audio/mix.wav was made for another timeline; run `pnpm audio`");
    }
  } catch {
    // no audio yet
  }
  return { durationInFrames: timeline.frames, props: { ...props, index, timeline, audio } };
};

const loopMetadata: CalculateMetadataFunction<LoopProps> = async ({ props }) => ({
  props: { ...props, index: await resolveAssets(io, SCENE_FILES) },
});

export const Root: React.FC = () => (
  <>
    <Composition
      id="MacToysFilm"
      component={Film}
      width={WIDTH}
      height={HEIGHT}
      fps={FPS}
      durationInFrames={FPS * 85}
      defaultProps={{ lang: "en" } as FilmProps}
      calculateMetadata={filmMetadata}
    />
    <Composition
      id="MacToysLoop"
      component={Loop}
      width={WIDTH}
      height={HEIGHT}
      fps={FPS}
      durationInFrames={LOOP_FRAMES}
      defaultProps={{ lang: "en" } as LoopProps}
      calculateMetadata={loopMetadata}
    />
    <Still id="MacToysPoster" component={Poster} width={WIDTH} height={HEIGHT} defaultProps={{ lang: "en" } as PosterProps} calculateMetadata={loopMetadata as unknown as CalculateMetadataFunction<PosterProps>} />
  </>
);
