// Renders stills of the film for review, and a contact sheet.
//   pnpm stills                         every shot at 20/50/85 % → out/stills/, sheet.png
//   pnpm stills --lang zh-Hans --shot cmdpal,wall --at 0.1,0.5,0.9
//   pnpm stills --frames 120,480        film frames
//   pnpm stills --comp MacToysLoop --frames 0,240
//   pnpm stills --public /tmp/pub --shot languages   another public folder
//   pnpm stills --cuts                  each transition: halfway in, the cut, halfway out

import { execFileSync } from "node:child_process";
import { mkdirSync, rmSync, symlinkSync } from "node:fs";
import path from "node:path";
import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";
import type { Timeline } from "../src/timeline";

const ROOT = path.resolve(import.meta.dirname, "..");
const arg = (name: string, fallback?: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
};

const lang = arg("lang", "en")!;
const comp = arg("comp", "MacToysFilm")!;
const outDir = path.join(ROOT, arg("out", "out/stills")!);
const scale = Number(arg("scale", "0.5"));

async function main() {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  // --public <dir> renders against another public folder (e.g. a scratch copy with more languages)
  const publicDir = path.resolve(arg("public", path.join(ROOT, "public"))!);
  const serveUrl = await bundle({ entryPoint: path.join(ROOT, "src/index.ts"), publicDir });
  const inputProps = { lang };
  const composition = await selectComposition({ serveUrl, id: comp, inputProps });
  const jobs: { frame: number; name: string }[] = [];
  const frames = arg("frames");
  if (process.argv.includes("--cuts")) {
    // around every cut: halfway into the transition, the cut, halfway out
    const tl = (composition.props as { timeline: Timeline }).timeline;
    for (const s of tl.shots.slice(1)) {
      for (const [k, d] of [["a", -Math.ceil(s.enter.pre / 2)], ["b", 0], ["c", Math.ceil(s.enter.post / 2)]] as const)
        jobs.push({ frame: s.from + d, name: `${String(s.index).padStart(2, "0")}-${s.id}-${k}` });
    }
  } else if (frames) {
    for (const f of frames.split(",")) jobs.push({ frame: Number(f), name: `f${f.padStart(5, "0")}` });
  } else {
    const tl = (composition.props as { timeline: Timeline }).timeline;
    const only = arg("shot")?.split(",");
    const at = (arg("at", "0.2,0.5,0.85") as string).split(",").map(Number);
    for (const s of tl.shots) {
      if (only && !only.includes(s.id)) continue;
      for (const a of at) {
        const frame = Math.min(tl.frames - 1, Math.round(s.from + a * s.frames));
        jobs.push({ frame, name: `${String(s.index).padStart(2, "0")}-${s.id}-${String(frame).padStart(5, "0")}` });
      }
    }
  }
  const files: string[] = [];
  for (const j of jobs) {
    const output = path.join(outDir, `${j.name}.png`);
    await renderStill({ composition, serveUrl, output, frame: j.frame, inputProps, scale, imageFormat: "png" });
    files.push(output);
    console.log(output);
  }
  // contact sheets (4 × 3, or 3 × 4 for cuts so each row is one transition), in render order
  const cols = process.argv.includes("--cuts") ? 3 : 4;
  for (let k = 0; k * 12 < files.length; k++) {
    const chunk = files.slice(k * 12, k * 12 + 12);
    const tmp = path.join(outDir, `.sheet${k}`);
    mkdirSync(tmp, { recursive: true });
    chunk.forEach((f, i) => symlinkSync(f, path.join(tmp, `${String(i).padStart(3, "0")}.png`)));
    const sheet = path.join(outDir, `sheet-${k + 1}.jpg`);
    const rows = Math.ceil(chunk.length / cols);
    execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", path.join(tmp, "%03d.png"), "-vf", `scale=640:-1,tile=${cols}x${rows}:padding=6:color=black`, "-frames:v", "1", "-q:v", "3", sheet]);
    rmSync(tmp, { recursive: true, force: true });
    console.log(sheet);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
