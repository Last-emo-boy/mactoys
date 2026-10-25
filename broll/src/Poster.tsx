// The poster: a frame of the loop with the film's line under the wordmark.

import React from "react";
import { AbsoluteFill } from "remotion";
import type { AssetIndex } from "./assets";
import type { FilmLang } from "./config";
import { useFonts } from "./fonts";
import { LoopBody } from "./Loop";

export interface PosterProps {
  lang: FilmLang;
  index?: AssetIndex;
  [key: string]: unknown;
}

export const POSTER_FRAME = 96;

export const Poster: React.FC<PosterProps> = ({ lang, index }) => {
  useFonts(lang);
  if (!index) return <AbsoluteFill style={{ background: "#000" }} />;
  return <LoopBody lang={lang} index={index} f={POSTER_FRAME} tagline />;
};
