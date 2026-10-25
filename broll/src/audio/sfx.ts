// UI sound effects. `t` is the moment the sound lands on the picture (a click, a key, the peak of a
// whoosh); air moves start before it.

import type { Sfx } from "../timeline";
import { Biquad, Bus, midiHz, Rng, Sine, soft, SR, SVF } from "./dsp";

const at = (t: number) => Math.round(t * SR);

/** A short decaying sine partial. */
function partial(bus: Bus, t: number, hz: number, decay: number, gain: number, pan: number, attack = 0.0008, glide = 0) {
  const o = new Sine();
  const n = at(decay * 6);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const e = Math.min(1, s / attack) * Math.exp(-s / decay);
    bus.add(i0 + k, o.next(hz * (1 + glide * Math.exp(-s / 0.03))) * e * gain, pan);
  }
}

/** Filtered noise burst. */
function burst(bus: Bus, t: number, hz: number, q: number, decay: number, gain: number, pan: number, seed: number, mode: "band" | "high" = "band") {
  const rng = new Rng(seed);
  const f = new SVF();
  const n = at(decay * 6);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const e = Math.min(1, s / 0.0005) * Math.exp(-s / decay);
    f.process(rng.bi(), hz, q);
    bus.add(i0 + k, (mode === "band" ? f.band : f.high) * e * gain, pan);
  }
}

/** Air: noise through a band-pass that sweeps lo → peak → lo; the loudest point lands at `t`. */
function air(bus: Bus, t: number, pre: number, post: number, f0: number, f1: number, f2: number, gain: number, pan0: number, pan1: number, seed: number, q = 0.9) {
  const rng = new Rng(seed);
  const f = new SVF();
  const lp = new SVF();
  const n = at(pre + post);
  const i0 = at(t - pre);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const u = s < pre ? s / pre : 1 + (s - pre) / post; // 0..1 rising, 1..2 falling
    const env = u < 1 ? u ** 2.4 : (1 - (u - 1)) ** 1.6;
    const hz = u < 1 ? f0 * (f1 / f0) ** u : f1 * (f2 / f1) ** (u - 1);
    f.process(rng.bi(), hz, q);
    const y = lp.process(f.band, hz * 2.5, 0.7);
    bus.add(i0 + k, y * env * gain, pan0 + (pan1 - pan0) * Math.min(1, u / 2));
  }
}

export interface SfxCall {
  sfx: Sfx;
  t: number;
  gain: number;
  pan: number;
  seed: number;
  /** -1 for leftward transitions, 1 rightward, 0 none. */
  dir: number;
}

/** Renders one effect into `dry` (and some into `wet`, the reverb send). */
export function renderSfx(c: SfxCall, dry: Bus, wet: Bus) {
  const { t, pan, seed } = c;
  const g = c.gain;
  const rng = new Rng(seed);
  switch (c.sfx) {
    case "click":
      burst(dry, t, 3800, 0.9, 0.0018, 0.5 * g, pan, seed, "high");
      partial(dry, t, 2900, 0.007, 0.16 * g, pan);
      partial(dry, t, 900, 0.012, 0.12 * g, pan);
      break;
    case "pop": {
      const o = new Sine();
      const n = at(0.2);
      const i0 = at(t);
      for (let k = 0; k < n; k++) {
        const s = k / SR;
        const hz = 420 + 560 * (1 - Math.exp(-s / 0.022));
        const e = Math.min(1, s / 0.002) * Math.exp(-s / 0.045);
        const v = o.next(hz) * e * 0.26 * g;
        dry.add(i0 + k, v, pan);
        wet.add(i0 + k, v * 0.4, pan);
      }
      burst(dry, t, 2400, 1.2, 0.003, 0.18 * g, pan, seed);
      break;
    }
    case "key":
      partial(dry, t, 1480, 0.035, 0.12 * g, pan);
      partial(dry, t, 2960, 0.018, 0.05 * g, pan);
      partial(dry, t, 190, 0.02, 0.22 * g, pan, 0.001, 0.4);
      burst(dry, t, 5200, 1, 0.0015, 0.22 * g, pan, seed, "high");
      partial(wet, t, 1480, 0.05, 0.06 * g, pan);
      break;
    case "type": {
      const hz = 2600 + rng.next() * 1500;
      burst(dry, t, hz, 1.6, 0.0035, 0.32 * g, pan + rng.bi() * 0.15, seed);
      partial(dry, t, 210 + rng.next() * 50, 0.009, 0.16 * g, pan);
      break;
    }
    case "enter":
      burst(dry, t, 1900, 1.2, 0.006, 0.34 * g, pan, seed);
      partial(dry, t, 150, 0.035, 0.32 * g, pan, 0.001, 0.5);
      break;
    case "tick":
      partial(dry, t, 2500 + rng.next() * 160, 0.009, 0.09 * g, pan + rng.bi() * 0.2);
      partial(dry, t, 5100, 0.004, 0.035 * g, pan);
      burst(dry, t, 6000, 1, 0.0012, 0.08 * g, pan, seed, "high");
      break;
    case "swish":
      air(dry, t, 0.12, 0.2, 900, 3200, 1400, 0.16 * g, pan - 0.2, pan + 0.2, seed, 0.8);
      break;
    case "whoosh":
      air(dry, t, 0.32, 0.36, 260, 1500, 380, 0.42 * g, -0.45 * (c.dir || 1), 0.45 * (c.dir || 1), seed, 0.7);
      air(wet, t, 0.32, 0.36, 260, 1500, 380, 0.15 * g, 0, 0, seed + 1, 0.7);
      break;
    case "whip":
      air(dry, t, 0.16, 0.16, 700, 5200, 1500, 0.38 * g, -0.7 * (c.dir || 1), 0.7 * (c.dir || 1), seed, 1.1);
      break;
    case "zoom": {
      air(dry, t, 0.38, 0.2, 200, 3800, 900, 0.36 * g, 0, 0, seed, 0.9);
      const o = new Sine();
      const n = at(0.5);
      const i0 = at(t - 0.38);
      for (let k = 0; k < n; k++) {
        const s = k / SR;
        const u = Math.min(1, s / 0.38);
        const e = s < 0.38 ? u ** 3 : Math.exp(-(s - 0.38) / 0.04);
        dry.add(i0 + k, o.next(180 * 2 ** (u * 2)) * e * 0.08 * g, 0);
      }
      break;
    }
    case "snap":
      partial(dry, t, 120, 0.05, 0.4 * g, pan, 0.001, 0.6);
      burst(dry, t, 3000, 1, 0.004, 0.25 * g, pan, seed);
      break;
    case "blip":
      partial(dry, t, midiHz(88), 0.05, 0.1 * g, pan, 0.003);
      partial(dry, t + 0.07, midiHz(93), 0.11, 0.1 * g, pan, 0.003);
      partial(wet, t + 0.07, midiHz(93), 0.14, 0.06 * g, pan, 0.003);
      break;
    case "impact": {
      const o = new Sine();
      const lp = new SVF();
      const hp = Biquad.highpass(3000);
      const n = at(2.4);
      const i0 = at(t);
      for (let k = 0; k < n; k++) {
        const s = k / SR;
        const hz = 36 + 80 * Math.exp(-s / 0.05);
        const boom = o.next(hz) * Math.exp(-s / 0.8) * Math.min(1, s / 0.002);
        const noise = rng.bi();
        const body = lp.process(noise, 1500 * Math.exp(-s / 0.25) + 160, 0.7) * Math.exp(-s / 0.3);
        const air = hp.process(noise) * Math.exp(-s / 0.5) * 0.25;
        const v = soft(boom * 1.25 + body * 0.8) * 0.8 * g;
        dry.add(i0 + k, v + air * g, 0);
        wet.add(i0 + k, (body * 0.5 + air) * 0.6 * g, 0);
      }
      break;
    }
    case "shimmer": {
      const notes = [74, 78, 81, 85, 86, 88, 90, 93, 97, 98];
      for (let i = 0; i < 14; i++) {
        const m = notes[Math.floor(rng.next() * notes.length)] + (rng.next() < 0.3 ? 12 : 0);
        const dt = (i / 14) * 0.7 + rng.next() * 0.05;
        const p = rng.bi() * 0.8;
        partial(dry, t + dt, midiHz(m), 0.35, 0.03 * g, p, 0.004);
        partial(wet, t + dt, midiHz(m), 0.5, 0.05 * g, p, 0.004);
      }
      break;
    }
    case "chime": {
      // a struck bell on D: inharmonic partials, long decay
      const f0 = midiHz(74);
      const parts: [number, number, number][] = [
        [0.5, 0.18, 3.2],
        [1, 0.22, 2.6],
        [2.0, 0.09, 1.6],
        [2.76, 0.07, 1.1],
        [3.0, 0.05, 1.3],
        [5.4, 0.03, 0.6],
        [8.93, 0.015, 0.35],
      ];
      for (const [r, a, d] of parts) {
        partial(dry, t, f0 * r, d, a * g, 0, 0.002);
        partial(wet, t, f0 * r, d, a * 0.6 * g, 0, 0.002);
      }
      break;
    }
  }
}
