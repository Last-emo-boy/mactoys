// Validates the timeline, the copy and the exported English assets before rendering.

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { APP_DIR, APP_ICON, filesFor } from "../src/assets";
import { BEAT, FILM_LANGS, FPS, PICKUP_BEATS } from "../src/config";
import { captionLength, COPY } from "../src/copy";
import { SCENE_FILES } from "../src/shots/files";
import { buildTimeline, keyTaps, SHOTS } from "../src/timeline";
import { loadIndex, PUBLIC } from "./nodeAssets";

const errors: string[] = [];
const warnings: string[] = [];
const fail = (m: string) => errors.push(m);

async function main() {
  const index = await loadIndex();
  const en = index.manifests.en;

  // assets
  for (const rel of filesFor(en, SCENE_FILES)) if (!existsSync(path.join(PUBLIC, APP_DIR, "en", rel))) fail(`missing en asset ${rel}`);
  if (!existsSync(path.join(PUBLIC, APP_ICON))) fail(`missing ${APP_ICON}`);
  if (index.langs.includes("eo")) fail("eo must never be shown");

  // the timeline, for one exported language and for several
  for (const langs of [["en"], ["en", "zh-Hans"], index.langs]) {
    const tl = buildTimeline(langs);
    const label = langs.join("+");
    const secs = tl.frames / FPS;
    if (secs < 75 || secs > 90) fail(`${label}: film is ${secs.toFixed(1)} s (want 75–90)`);
    let expect = 0;
    tl.shots.forEach((s, i) => {
      if (s.from !== expect) fail(`${label}: shot ${s.id} starts at ${s.from}, expected ${expect}`);
      expect = s.from + s.frames;
      if (s.from % BEAT !== 0) fail(`${label}: cut into ${s.id} is off the beat grid`);
      for (const c of s.cues) if (c.at < 0 || c.at > s.beats) fail(`${label}: ${s.id} cue at ${c.at} outside the shot`);
      const prev = tl.shots[i - 1];
      if (prev && prev.enter.kind === s.enter.kind && s.enter.kind !== "continue") fail(`${label}: ${prev.id} and ${s.id} enter with the same transition (${s.enter.kind})`);
      if (s.enter.pre > (prev?.frames ?? 0) / 2 && i > 0) fail(`${label}: ${s.id} transition starts before the middle of ${prev.id}`);
      const bar = (s.beat - PICKUP_BEATS) % 4 === 0;
      if (["title", "wall", "settings", "end"].includes(s.id) && !bar) fail(`${label}: ${s.id} should start on a bar line`);
    });
    if (expect !== tl.frames) fail(`${label}: shots cover ${expect} frames of ${tl.frames}`);
  }

  // keys and captions refer to real shortcuts and modules
  for (const s of SHOTS) {
    for (const k of s.keys ?? []) {
      const mod = en.modules.find((m) => m.id === k.module);
      const sc = mod?.shortcuts[k.shortcut];
      if (!sc) fail(`${s.id}: no shortcut ${k.shortcut} for ${k.module}`);
      else if (keyTaps(k, sc.keys.length).some((t) => t.some((b) => b > s.beats))) fail(`${s.id}: a key tap falls after the shot`);
    }
    for (const c of s.captions ?? []) {
      if (!en.modules.some((m) => m.id === c.module)) fail(`${s.id}: caption module ${c.module} not in the manifest`);
      for (const lang of FILM_LANGS) if (!COPY[lang].captions[c.copy]) fail(`${s.id}: no ${lang} caption "${c.copy}"`);
    }
  }

  // copy length rules
  for (const lang of FILM_LANGS) {
    const c = COPY[lang];
    const lines = { ...c.captions, settings: c.settings, languages: c.languages, terminal: c.terminal };
    const max = lang === "en" ? 8 : 16;
    for (const [k, v] of Object.entries(lines)) if (captionLength(lang, v) > max) fail(`${lang} caption ${k} is too long: "${v}"`);
  }

  // audio made for this timeline
  const tl = buildTimeline(index.langs);
  const meta = path.join(PUBLIC, "audio/mix.json");
  if (!existsSync(meta)) warnings.push("no public/audio/mix.json — run pnpm audio");
  else {
    const m = JSON.parse(readFileSync(meta, "utf8")) as { frames: number; langs: string[] };
    if (m.frames !== tl.frames || m.langs.join() !== index.langs.join()) warnings.push("public/audio/mix.wav is for another timeline — run pnpm audio");
  }

  console.log(`languages: ${index.langs.join(", ")} · film ${(tl.frames / FPS).toFixed(2)} s · ${tl.shots.length} shots`);
  for (const w of warnings) console.warn(`warning: ${w}`);
  for (const e of errors) console.error(`error: ${e}`);
  if (errors.length) process.exit(1);
  console.log("ok");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
