// The film's asset discovery, read from public/ on disk (the compositions use fetch instead).

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { resolveAssets, type AssetIO, type AssetIndex } from "../src/assets";
import { SCENE_FILES } from "../src/shots/files";

export const ROOT = path.resolve(import.meta.dirname, "..");
export const PUBLIC = path.join(ROOT, "public");

const io: AssetIO = {
  async exists(rel) {
    return existsSync(path.join(PUBLIC, rel));
  },
  async json(rel) {
    const p = path.join(PUBLIC, rel);
    if (!existsSync(p)) throw new Error(`missing public/${rel} — run pnpm export-assets`);
    return JSON.parse(readFileSync(p, "utf8"));
  },
};

export const loadIndex = (): Promise<AssetIndex> => resolveAssets(io, SCENE_FILES);
