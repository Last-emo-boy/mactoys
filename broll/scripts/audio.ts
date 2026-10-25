// Renders the score and the final mix for the timeline the exported assets produce.
//   out/audio/score.wav   music only
//   out/audio/mix.wav     music + UI effects (what the film plays)
//   public/audio/mix.wav  + mix.json, read by the composition (checked against its own timeline)
// Both are normalized to -14 LUFS integrated with true peak at or under -1.8 dBTP.

import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { moduleById } from "../src/assets";
import { integratedLufs, normalize, truePeakDb } from "../src/audio/master";
import { renderScore } from "../src/audio/score";
import { wav24 } from "../src/audio/wav";
import { buildTimeline } from "../src/timeline";
import { loadIndex, PUBLIC, ROOT } from "./nodeAssets";

const TARGET = -14;
const CEILING = -1.8;

async function main() {
  const index = await loadIndex();
  const tl = buildTimeline(index.langs);
  const en = index.manifests.en;
  const t0 = Date.now();
  const { score, mix, sfxCount, stems } = renderScore(tl, (k) => moduleById(en, k.module).shortcuts[k.shortcut]?.keys.length ?? 0);
  console.log(`rendered ${(tl.frames / 60).toFixed(2)} s, ${sfxCount} effects, in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  if (process.argv.includes("--stems"))
    for (const [k, b] of Object.entries(stems)) console.log(`  ${k.padEnd(7)} ${integratedLufs(b).toFixed(1).padStart(6)} LUFS ${truePeakDb(b).toFixed(1).padStart(6)} dBTP`);
  console.log(`pre-master: score ${integratedLufs(score).toFixed(1)} LUFS ${truePeakDb(score).toFixed(1)} dBTP · mix ${integratedLufs(mix).toFixed(1)} LUFS ${truePeakDb(mix).toFixed(1)} dBTP`);
  const s = normalize(score, TARGET, CEILING);
  const m = normalize(mix, TARGET, CEILING);
  console.log(`score ${s.lufs.toFixed(2)} LUFS ${s.tp.toFixed(2)} dBTP · mix ${m.lufs.toFixed(2)} LUFS ${m.tp.toFixed(2)} dBTP`);

  const out = path.join(ROOT, "out/audio");
  const pub = path.join(PUBLIC, "audio");
  mkdirSync(out, { recursive: true });
  mkdirSync(pub, { recursive: true });
  const mixWav = wav24(mix);
  writeFileSync(path.join(out, "score.wav"), wav24(score));
  writeFileSync(path.join(out, "mix.wav"), mixWav);
  writeFileSync(path.join(pub, "mix.wav"), mixWav);
  writeFileSync(path.join(pub, "mix.json"), JSON.stringify({ frames: tl.frames, langs: index.langs }) + "\n");
  console.log(`langs ${index.langs.join(", ")} · ${tl.frames} frames → out/audio/{score,mix}.wav, public/audio/mix.{wav,json}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
