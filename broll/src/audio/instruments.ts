// The score's instruments. Each renders one note (or hit) additively into a bus at time `t` seconds.

import { adsr, Biquad, Bus, midiHz, Pulse, Rng, Saw, Sine, soft, SR, SVF, TAU } from "./dsp";

const at = (t: number) => Math.round(t * SR);

/** Warm detuned-saw pad voice, low-passed, slow envelope. */
export function pad(bus: Bus, t: number, len: number, midi: number, gain: number, cutoff: number, seed: number) {
  const rng = new Rng(seed);
  const hz = midiHz(midi);
  const det = [-0.11, 0, 0.12];
  const oscs = det.map(() => new Saw(rng.next()));
  const pans = [-0.6, 0, 0.6];
  const lp = [new SVF(), new SVF(), new SVF()];
  const rel = 1.4;
  const n = at(len + rel);
  const i0 = at(t);
  const lfoRate = 0.15 + rng.next() * 0.1;
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const e = adsr(s, len, 0.9, 1.2, 0.8, rel);
    if (e <= 0 && s > len) break;
    const cut = cutoff * (1 + 0.18 * Math.sin(TAU * lfoRate * s + seed));
    for (let v = 0; v < 3; v++) {
      const x = oscs[v].next(hz * 2 ** (det[v] / 12));
      const y = lp[v].process(x, cut, 0.6);
      bus.add(i0 + k, y * e * gain * 0.45, pans[v]);
    }
  }
}

/** Plucky arpeggio note: saw + pulse through an enveloped low-pass. */
export function arp(bus: Bus, t: number, midi: number, gain: number, cutoff: number, pan: number, decay = 0.2) {
  const hz = midiHz(midi);
  const a = new Saw(0.3);
  const b = new Pulse(0.7);
  const lp = new SVF();
  const n = at(decay * 4);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const env = Math.min(1, s / 0.003) * Math.exp(-s / decay);
    const cut = cutoff + 3200 * Math.exp(-s / 0.07);
    const x = 0.6 * a.next(hz) + 0.4 * b.next(hz * 1.002, 0.32);
    bus.add(i0 + k, lp.process(x, cut, 0.9) * env * gain, pan);
  }
}

/** FM bell / mallet for the lead line. */
export function bell(bus: Bus, t: number, midi: number, gain: number, pan: number, decay = 0.9) {
  const hz = midiHz(midi);
  const mod = new Sine();
  const n = at(decay * 4);
  const i0 = at(t);
  let ph = 0;
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const env = Math.min(1, s / 0.004) * Math.exp(-s / decay);
    const idx = 2.2 * Math.exp(-s / 0.18) + 0.25;
    const v = Math.sin(TAU * ph + mod.next(hz * 2) * idx);
    ph += hz / SR;
    if (ph >= 1) ph -= 1;
    bus.add(i0 + k, v * env * gain, pan);
  }
}

/** Sub bass: sine with a touch of second harmonic, saturated. */
export function bass(bus: Bus, t: number, len: number, midi: number, gain: number) {
  const hz = midiHz(midi);
  const o = new Sine();
  const o2 = new Sine();
  const rel = 0.05;
  const n = at(len + rel);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const e = adsr(s, len, 0.004, 0.25, 0.75, rel);
    const x = o.next(hz) + 0.22 * o2.next(hz * 2);
    bus.add(i0 + k, soft(x * 1.4) * 0.72 * e * gain, 0);
  }
}

/** Kick: pitch-swept sine plus a short click. */
export function kick(bus: Bus, t: number, gain: number) {
  const o = new Sine();
  const rng = new Rng(Math.round(t * 1000));
  const hp = Biquad.highpass(1800);
  const n = at(0.5);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const hz = 46 + 120 * Math.exp(-s / 0.028) + 20 * Math.exp(-s / 0.2);
    const body = o.next(hz) * Math.exp(-s / 0.26) * Math.min(1, s / 0.0015);
    const click = hp.process(rng.bi()) * Math.exp(-s / 0.0025) * 0.5;
    bus.add(i0 + k, soft((body + click) * 1.3) * gain, 0);
  }
}

/** Hi-hat from filtered noise. */
export function hat(bus: Bus, t: number, gain: number, open: boolean, pan: number, seed: number) {
  const rng = new Rng(seed);
  const f = new SVF();
  const f2 = new SVF();
  const decay = open ? 0.11 : 0.032;
  const n = at(decay * 6);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const e = Math.min(1, s / 0.0008) * Math.exp(-s / decay);
    f.process(rng.bi(), 7600, 0.7);
    const y = f.high;
    f2.process(y, 11000, 1.4);
    bus.add(i0 + k, (y * 0.6 + f2.band * 0.6) * e * gain, pan);
  }
}

/** Clap: three noise bursts and a short tail through a band-pass. */
export function clap(bus: Bus, t: number, gain: number, seed: number) {
  const rng = new Rng(seed);
  const f = new SVF();
  const n = at(0.4);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    let e = 0;
    for (const o of [0, 0.009, 0.019]) if (s >= o) e += Math.exp(-(s - o) / 0.006) * 0.8;
    if (s >= 0.024) e += Math.exp(-(s - 0.024) / 0.1) * 0.6;
    f.process(rng.bi(), 1500, 1.1);
    bus.add(i0 + k, f.band * e * gain, (rng.next() - 0.5) * 0.2);
  }
}

/** Snare for the build: noise and a tuned body. */
export function snare(bus: Bus, t: number, gain: number, seed: number) {
  const rng = new Rng(seed);
  const o = new Sine();
  const f = new SVF();
  const n = at(0.3);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    f.process(rng.bi(), 2600, 0.8);
    const noise = (f.band + f.high * 0.4) * Math.exp(-s / 0.09);
    const body = o.next(185 + 40 * Math.exp(-s / 0.02)) * Math.exp(-s / 0.05) * 0.7;
    bus.add(i0 + k, (noise + body) * Math.min(1, s / 0.001) * gain, 0);
  }
}

/** Shaker: soft high noise with a rounded attack. */
export function shaker(bus: Bus, t: number, gain: number, pan: number, seed: number) {
  const rng = new Rng(seed);
  const f = new SVF();
  const n = at(0.09);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const e = Math.sin(Math.PI * Math.min(1, s / 0.012)) ** 2 * (s < 0.012 ? 1 : Math.exp(-(s - 0.012) / 0.025));
    f.process(rng.bi(), 6000, 0.9);
    bus.add(i0 + k, f.band * e * gain, pan);
  }
}

/** Crash: bright noise with a long decay. */
export function crash(bus: Bus, t: number, gain: number, seed: number) {
  const rng = new Rng(seed);
  const fl = new SVF();
  const fr = new SVF();
  const n = at(2.8);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const e = Math.min(1, s / 0.002) * (0.6 * Math.exp(-s / 0.9) + 0.4 * Math.exp(-s / 0.12));
    fl.process(rng.bi(), 5200, 0.6);
    fr.process(rng.bi(), 5200, 0.6);
    bus.add2(i0 + k, fl.high * e * gain, fr.high * e * gain);
  }
}

/**
 * Riser that peaks exactly at `t1`: noise through a rising band-pass, plus a rising filtered saw
 * an octave pair, swelling in.
 */
export function riser(bus: Bus, t0: number, t1: number, gain: number, seed: number) {
  const rng = new Rng(seed);
  const f = new SVF();
  const g = new SVF();
  const a = new Saw(0.1);
  const b = new Saw(0.6);
  const len = t1 - t0;
  const n = at(len + 0.06);
  const i0 = at(t0);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const u = Math.min(1, s / len);
    const swell = u ** 2.2 * (s > len ? Math.max(0, 1 - (s - len) / 0.06) : 1);
    const cut = 300 * 2 ** (u * 4.6);
    f.process(rng.bi(), cut, 2.2);
    const hz = midiHz(50 + 24 * u ** 1.5);
    const tone = g.process(0.5 * a.next(hz) + 0.5 * b.next(hz * 1.5), cut * 0.8, 0.8);
    const sp = Math.sin(TAU * 0.9 * s * (1 + u * 3)) * 0.5 * u;
    bus.add(i0 + k, (f.band * 1.4 + tone * 0.35) * swell * gain, sp);
  }
}

/** Downbeat impact: deep drop, noise burst. */
export function impact(bus: Bus, t: number, gain: number, seed: number) {
  const rng = new Rng(seed);
  const o = new Sine();
  const lp = new SVF();
  const n = at(2.2);
  const i0 = at(t);
  for (let k = 0; k < n; k++) {
    const s = k / SR;
    const hz = 38 + 70 * Math.exp(-s / 0.06);
    const boom = o.next(hz) * Math.exp(-s / 0.7) * Math.min(1, s / 0.002);
    const burst = lp.process(rng.bi(), 1800 * Math.exp(-s / 0.3) + 200, 0.7) * Math.exp(-s / 0.22);
    bus.add(i0 + k, soft(boom * 1.2 + burst * 0.9) * gain, 0);
  }
}
