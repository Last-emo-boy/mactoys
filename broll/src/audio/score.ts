// The score, composed from the timeline: 120 BPM in D major, a two-beat pickup, then bars of
// Dmaj9 – Aadd9 – Bm11 – Gmaj7♯11. Each shot's music section sets the arrangement; risers land on the
// title and the end card; the Settings shot is a breakdown. Returns the music and the full mix.

import { BEAT, FPS } from "../config";
import { sfxEvents, type KeySpec, type MusicSection, type Sfx, type Timeline } from "../timeline";
import { Biquad, Bus, pingPong, reverb, SR } from "./dsp";
import { arp, bass, bell, clap, crash, hat, impact, kick, pad, riser, shaker, snare } from "./instruments";
import { renderSfx } from "./sfx";

const SPB = BEAT / FPS; // seconds per beat (0.5)
const sec = (beat: number) => beat * SPB;

type ChordName = "D" | "A" | "Bm" | "G";
const PAD: Record<ChordName, number[]> = {
  D: [50, 57, 61, 64, 66],
  A: [52, 57, 59, 61, 64],
  Bm: [54, 57, 59, 62, 64],
  G: [55, 59, 61, 62, 66],
};
const ROOT: Record<ChordName, number> = { D: 38, A: 33, Bm: 35, G: 31 };
const ARP: Record<ChordName, number[]> = {
  D: [73, 74, 76, 78, 81],
  A: [71, 73, 76, 81, 83],
  Bm: [71, 74, 76, 78, 81],
  G: [71, 73, 74, 78, 79],
};
const ARP_STEPS = [0, 2, 1, 3, 2, 4, 3, 1, 0, 2, 4, 2, 1, 3, 4, 3];
/** One bar of lead per chord: [midi, beat, length]. */
const LEAD: Record<ChordName, [number, number, number][]> = {
  D: [[78, 0, 1.5], [76, 1.5, 0.5], [74, 2, 1], [81, 3, 1]],
  A: [[76, 0, 1.5], [73, 1.5, 0.5], [71, 2, 2]],
  Bm: [[74, 0, 1], [78, 1, 1], [76, 2, 1.5], [74, 3.5, 0.5]],
  G: [[71, 0, 1.5], [73, 1.5, 0.5], [74, 2, 1], [76, 3, 1]],
};

/** Chords of each harmonic region, bar by bar (the groove region loops). */
const PROG: Record<string, ChordName[]> = {
  intro: ["D", "G"],
  title: ["D", "A", "Bm"],
  wall: ["G", "D", "A"],
  groove: ["D", "A", "Bm", "G"],
  breakdown: ["G", "Bm", "A"],
  build: ["Bm", "G", "A"],
  terminal: ["D", "Bm", "A"],
  outro: ["D", "D", "D"],
};
const region = (m: MusicSection) => (m === "grooveA" || m === "grooveB" || m === "grooveC" ? "groove" : m);

interface Arrangement {
  pad: number;
  padCut: number;
  arp: number;
  arpCut: number;
  bass: "none" | "long" | "eighths";
  kick: "none" | "bars" | "four";
  hats: 0 | 8 | 16;
  clap: boolean;
  lead: 0 | 1 | 2;
  shaker: boolean;
}
const ARR: Record<MusicSection, Arrangement> = {
  intro: { pad: 0.8, padCut: 1100, arp: 0, arpCut: 500, bass: "none", kick: "none", hats: 0, clap: false, lead: 0, shaker: false },
  title: { pad: 1, padCut: 2400, arp: 0.55, arpCut: 700, bass: "long", kick: "bars", hats: 0, clap: false, lead: 0, shaker: false },
  wall: { pad: 0.9, padCut: 2600, arp: 0.85, arpCut: 900, bass: "eighths", kick: "four", hats: 8, clap: false, lead: 0, shaker: false },
  grooveA: { pad: 0.75, padCut: 2600, arp: 0.9, arpCut: 1100, bass: "eighths", kick: "four", hats: 8, clap: true, lead: 0, shaker: false },
  grooveB: { pad: 0.75, padCut: 2800, arp: 0.8, arpCut: 1200, bass: "eighths", kick: "four", hats: 16, clap: true, lead: 1, shaker: false },
  grooveC: { pad: 0.75, padCut: 3000, arp: 0.8, arpCut: 1300, bass: "eighths", kick: "four", hats: 16, clap: true, lead: 2, shaker: true },
  breakdown: { pad: 1, padCut: 1800, arp: 0.6, arpCut: 520, bass: "none", kick: "none", hats: 0, clap: false, lead: 0, shaker: false },
  build: { pad: 0.85, padCut: 2400, arp: 0.85, arpCut: 900, bass: "eighths", kick: "four", hats: 16, clap: false, lead: 0, shaker: true },
  terminal: { pad: 0.65, padCut: 2200, arp: 0.9, arpCut: 1000, bass: "eighths", kick: "four", hats: 16, clap: true, lead: 0, shaker: true },
  outro: { pad: 1, padCut: 2600, arp: 0, arpCut: 500, bass: "long", kick: "none", hats: 0, clap: false, lead: 0, shaker: false },
};

/** Effect levels against the music (measured around each event; transients sit near the music's RMS). */
const SFX_GAIN: Partial<Record<Sfx, number>> = { key: 2, type: 1.6, tick: 2, whoosh: 1.8, swish: 2.5, whip: 1.4, shimmer: 3, blip: 2, pop: 1.3, zoom: 1.4 };

const BALANCE = { pads: 0.18, arps: 3.2, leads: 0.75, subs: 0.7, kicks: 0.72, drums: 1.35, fx: 0.65 };

export interface ScoreOut {
  score: Bus;
  mix: Bus;
  sfxCount: number;
  /** Pre-fader stems, for balancing (`pnpm audio --stems`). */
  stems: Record<string, Bus>;
}

export function renderScore(tl: Timeline, keyCounts: (k: KeySpec) => number): ScoreOut {
  const n = Math.round((tl.frames / FPS) * SR);
  const shots = tl.shots;
  const sectionAt = (beat: number): MusicSection => {
    for (let i = shots.length - 1; i >= 0; i--) if (beat >= shots[i].beat) return shots[i].music;
    return shots[0].music;
  };
  const shotStart = (id: string) => shots.find((s) => s.id === id)?.beat;
  const regionStart = new Map<string, number>();
  for (const s of shots) {
    const r = region(s.music);
    if (!regionStart.has(r)) regionStart.set(r, s.beat);
  }
  const chordAt = (beat: number): ChordName => {
    const r = region(sectionAt(beat));
    const start = r === "intro" ? 2 : regionStart.get(r)!;
    const prog = PROG[r];
    const j = Math.max(0, Math.floor((beat - start) / 4));
    return r === "groove" ? prog[j % prog.length] : prog[Math.min(j, prog.length - 1)];
  };

  const pads = new Bus(n);
  const arps = new Bus(n);
  const leads = new Bus(n);
  const subs = new Bus(n);
  const kicks = new Bus(n);
  const drums = new Bus(n);
  const fx = new Bus(n);
  const kickTimes: number[] = [];

  const totalBeats = tl.beats;
  const endBeat = shotStart("end") ?? totalBeats;

  // ── pads: one chord per bar (the pickup holds the first chord) ──
  // the pickup and the first bar share one chord; the end card holds one chord to the end
  const bars: number[] = [0];
  for (let b = 6; b < totalBeats; b += 4) if (b <= endBeat || bars[bars.length - 1] < endBeat) bars.push(b);
  bars.forEach((b, i) => {
    const sect = sectionAt(b + 0.01);
    const a = ARR[sect];
    if (a.pad <= 0) return;
    const next = bars[i + 1] ?? totalBeats;
    const chord = chordAt(b + 0.01);
    const isLast = b >= endBeat;
    const len = isLast ? sec(totalBeats - b) - 1.6 : sec(next - b) + 0.12;
    // the intro opens up: the filter rises over the first bars
    const cut = sect === "intro" ? 700 + 500 * (b / 6) : sect === "breakdown" ? a.padCut * (0.7 + 0.3 * ((b - (shotStart("settings") ?? b)) / 12)) : a.padCut;
    PAD[chord].forEach((m, v) => pad(pads, sec(b), len, m, a.pad * (v === 0 ? 0.9 : 0.75), cut, b * 7 + v));
  });

  // ── per-beat parts ──
  for (let q = 0; q < totalBeats * 4; q++) {
    const beat = q / 4;
    const sect = sectionAt(beat);
    const a = ARR[sect];
    const chord = chordAt(beat);
    const inBar = (((beat - 2) % 4) + 4) % 4; // beat position in the bar
    const t = sec(beat);
    const sixteenth = q % 4;
    if (beat >= endBeat) continue; // the end card is the final chord alone

    // arpeggio, sixteenths
    if (a.arp > 0 && beat >= 2) {
      const step = Math.round(inBar * 4) % 16;
      const m = ARP[chord][ARP_STEPS[step]];
      const accent = sixteenth === 0 ? 1 : sixteenth === 2 ? 0.8 : 0.62;
      // title: the arp fades in from its second bar
      const title = shotStart("title");
      const fadeIn = sect === "title" && title !== undefined ? Math.max(0, Math.min(1, (beat - title - 4) / 8)) : 1;
      if (fadeIn > 0) arp(arps, t, m, 0.075 * a.arp * accent * fadeIn, a.arpCut, step % 2 ? 0.35 : -0.35);
    }

    // fills: the last beat of every fourth groove bar, a fuller one every eighth
    const grooveStart = regionStart.get("groove");
    if (region(sect) === "groove" && grooveStart !== undefined && beat >= grooveStart) {
      const barNo = Math.floor((beat - grooveStart) / 4);
      if (barNo % 4 === 3 && inBar >= 3.5) snare(drums, t, 0.1 + 0.08 * (inBar - 3.5) * 2, q + 7);
      if (barNo % 8 === 7 && inBar >= 3 && inBar < 3.5) snare(drums, t, 0.08, q + 9);
    }
    // the groove stops for a breath before the breakdown
    const breakdownAt = shots.find((s) => s.music === "breakdown")?.beat;
    const breath = breakdownAt !== undefined && beat >= breakdownAt - 1 && beat < breakdownAt;

    if (sixteenth === 0 && !breath) {
      // kick
      const k = a.kick === "four" || (a.kick === "bars" && Math.abs(inBar) < 0.01);
      if (k) {
        kick(kicks, t, 0.9);
        kickTimes.push(t);
      }
      // clap on 2 and 4
      if (a.clap && (Math.abs(inBar - 1) < 0.01 || Math.abs(inBar - 3) < 0.01)) clap(drums, t, 0.5, q);
    }
    // hats
    if (a.hats === 8 && sixteenth === 2) hat(drums, t, 0.2, inBar > 3, 0.18, q);
    if (a.hats === 16) hat(drums, t, sixteenth === 2 ? 0.2 : 0.09, sixteenth === 2 && inBar > 3, sixteenth % 2 ? -0.2 : 0.2, q);
    if (a.shaker) shaker(drums, t, sixteenth === 2 ? 0.1 : 0.06, 0.45, q + 99);

    // bass
    if (a.bass === "eighths" && sixteenth % 2 === 0) {
      const lastEighth = inBar >= 3.5;
      const m = ROOT[chord] + (lastEighth ? 7 : 0) + (sect === "terminal" && sixteenth === 2 ? 12 : 0);
      bass(subs, t, SPB * 0.42, m, sixteenth === 2 ? 0.95 : 0.8);
    }
    if (a.bass === "long" && sixteenth === 0 && Math.abs(inBar) < 0.01) bass(subs, t, SPB * 3.8, ROOT[chord], 0.9);

    // lead line
    if (a.lead > 0 && sixteenth === 0 && Math.abs(inBar) < 0.01) {
      for (const [m, at, len] of LEAD[chord]) {
        if (sectionAt(beat + at) !== sect) continue;
        bell(leads, sec(beat + at), m, 0.11, -0.15, Math.min(0.9, sec(len) + 0.3));
        if (a.lead === 2) bell(leads, sec(beat + at), m + 12, 0.045, 0.3, Math.min(0.7, sec(len)));
      }
    }
  }

  // ── build: a snare run into the next section ──
  const build = shots.find((s) => s.music === "build");
  if (build) {
    const end = build.beat + build.beats;
    for (let b = end - 4; b < end; b += 0.5) snare(drums, sec(b), 0.22 + 0.25 * ((b - end + 4) / 4), Math.round(b * 10));
    for (let b = end - 1; b < end; b += 0.25) snare(drums, sec(b), 0.4, Math.round(b * 10) + 1);
  }

  // ── risers, impacts, crashes ──
  const title = shotStart("title");
  if (title !== undefined) {
    riser(fx, sec(title - 3.5), sec(title), 0.3, 11);
    impact(fx, sec(title), 0.6, 12);
    crash(drums, sec(title), 0.28, 13);
  }
  const groove = regionStart.get("groove");
  if (groove !== undefined) {
    riser(fx, sec(groove - 2), sec(groove), 0.18, 21);
    crash(drums, sec(groove), 0.26, 22);
  }
  const settings = shots.find((s) => s.id === "settings");
  if (settings) {
    const after = settings.beat + settings.beats;
    riser(fx, sec(after - 2.5), sec(after), 0.2, 31);
    crash(drums, sec(after), 0.22, 32);
  }
  if (build) crash(drums, sec(build.beat + build.beats), 0.26, 41);
  if (endBeat < totalBeats) {
    riser(fx, sec(endBeat - 4), sec(endBeat), 0.3, 51);
    impact(fx, sec(endBeat), 0.45, 52);
    bass(subs, sec(endBeat), sec(totalBeats - endBeat) - 2, ROOT.D, 0.85);
  }

  // ── music bus: sidechain from the kick, delay on the arp, reverb ──
  const duck = new Float32Array(n).fill(1);
  for (const kt of kickTimes) {
    const i0 = Math.round(kt * SR);
    for (let k = 0; k < SR * 0.4 && i0 + k < n; k++) {
      const s = k / SR;
      const d = 1 - 0.5 * Math.min(1, s / 0.004) * Math.exp(-s / 0.11);
      if (d < duck[i0 + k]) duck[i0 + k] = d;
    }
  }
  pads.scale((i) => 0.55 + 0.45 * duck[i]);
  arps.scale((i) => 0.5 + 0.5 * duck[i]);
  subs.scale((i) => duck[i] ** 1.4);

  // stem balance (measured with `pnpm audio --stems`)
  pads.scale(BALANCE.pads);
  arps.scale(BALANCE.arps);
  leads.scale(BALANCE.leads);
  subs.scale(BALANCE.subs);
  kicks.scale(BALANCE.kicks);
  drums.scale(BALANCE.drums);
  fx.scale(BALANCE.fx);

  const music = new Bus(n);
  pads.mixInto(music, 1);
  arps.mixInto(music, 1);
  leads.mixInto(music, 1);
  subs.mixInto(music, 1);
  kicks.mixInto(music, 1);
  drums.mixInto(music, 1);
  fx.mixInto(music, 1);
  const delay = pingPong(sumBus([arps, leads], [0.8, 1]), Math.round(sec(0.75) * SR), 0.38, 3200);
  delay.mixInto(music, 0.45);
  const send = sumBus([pads, arps, leads, drums, fx], [0.35, 0.4, 0.6, 0.12, 0.5]);
  const verb = reverb(send, { seconds: 2.6, damp: 5200, predelay: 0.025 });
  verb.mixInto(music, 0.55);

  // ── effects bus ──
  const sfxDry = new Bus(n);
  const sfxWet = new Bus(n);
  const events = sfxEvents(tl, keyCounts);
  events.forEach((e, i) => renderSfx({ sfx: e.sfx, t: e.frame / FPS, gain: e.gain * (SFX_GAIN[e.sfx] ?? 1), pan: e.pan, seed: 1000 + i, dir: e.dir }, sfxDry, sfxWet));
  const sfxRev = reverb(sfxWet, { seconds: 1.6, damp: 7000, predelay: 0.012 });

  // ── master: high-pass, a little low-shelf weight, fade at the very end ──
  const finish = (b: Bus) => {
    const hpL = Biquad.highpass(28),
      hpR = Biquad.highpass(28);
    const fadeFrom = n - Math.round(SR * 1.1);
    for (let i = 0; i < n; i++) {
      const f = i < fadeFrom ? 1 : Math.max(0, 1 - (i - fadeFrom) / (n - fadeFrom)) ** 2;
      b.l[i] = hpL.process(b.l[i]) * f;
      b.r[i] = hpR.process(b.r[i]) * f;
    }
    // fade in from the black at the head
    const head = Math.round(SR * 0.04);
    for (let i = 0; i < head; i++) {
      b.l[i] *= i / head;
      b.r[i] *= i / head;
    }
    return b;
  };
  const score = finish(cloneBus(music));
  const mix = new Bus(n);
  music.mixInto(mix, 0.82);
  sfxDry.mixInto(mix, 1);
  sfxRev.mixInto(mix, 0.5);
  finish(mix);
  return { score, mix, sfxCount: events.length, stems: { pads, arps, leads, subs, kicks, drums, fx, delay, verb, sfxDry, sfxRev } };
}

function sumBus(buses: Bus[], gains: number[]): Bus {
  const out = new Bus(buses[0].length);
  buses.forEach((b, i) => b.mixInto(out, gains[i]));
  return out;
}

function cloneBus(b: Bus): Bus {
  const out = new Bus(b.length);
  out.l.set(b.l);
  out.r.set(b.r);
  return out;
}
