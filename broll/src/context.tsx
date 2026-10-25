import React, { createContext, useContext } from "react";
import { staticFile, useCurrentFrame } from "remotion";
import { appFile, manifestFor, moduleById, type AssetIndex, type Manifest, type ModuleInfo } from "./assets";
import type { FilmLang } from "./config";
import type { Copy } from "./copy";
import type { PlacedShot, Timeline } from "./timeline";

export interface FilmContextValue {
  lang: FilmLang;
  index: AssetIndex;
  timeline: Timeline;
  manifest: Manifest;
  copy: Copy;
}

export const FilmCtx = createContext<FilmContextValue | null>(null);

export function useFilm(): FilmContextValue {
  const v = useContext(FilmCtx);
  if (!v) throw new Error("FilmCtx missing");
  return v;
}

/** URL of an exported UI file in the film language (or `lang`), falling back to English per file. */
export function useAppFile(rel: string, lang?: string): string {
  const f = useFilm();
  return staticFile(appFile(f.index, lang ?? f.lang, rel));
}

export function useAppFiles(): (rel: string, lang?: string) => string {
  const f = useFilm();
  return (rel, lang) => staticFile(appFile(f.index, lang ?? f.lang, rel));
}

export function useModule(id: string, lang?: string): ModuleInfo {
  const f = useFilm();
  return moduleById(lang ? manifestFor(f.index, lang) : f.manifest, id);
}

interface ShotContextValue {
  shot: PlacedShot;
  /** Frames the shot's Sequence starts before its cut. */
  pre: number;
}

export const ShotCtx = createContext<ShotContextValue | null>(null);

export function useShot(): PlacedShot {
  const v = useContext(ShotCtx);
  if (!v) throw new Error("ShotCtx missing");
  return v.shot;
}

/** Frame relative to the shot's cut: negative during an incoming transition, ≥ frames while it leaves. */
export function useLocalFrame(): number {
  const v = useContext(ShotCtx);
  const frame = useCurrentFrame();
  return frame - (v?.pre ?? 0);
}

export const ShotProvider: React.FC<{ shot: PlacedShot; pre: number; children: React.ReactNode }> = ({ shot, pre, children }) => (
  <ShotCtx.Provider value={{ shot, pre }}>{children}</ShotCtx.Provider>
);
