// The one table that drives the film: picture, captions, sound effects and music all read it.
// Shots are measured in beats (120 BPM, 30 frames each); bar lines sit at beat 2 + 4k because the
// score opens with a two-beat pickup. Every cut lands on a beat line.

import { BEAT, PICKUP_BEATS } from "./config";

export type Sfx =
  | "click" // pointer click
  | "pop" // a panel springs open
  | "key" // glass keycap tap
  | "type" // keystroke while typing
  | "enter" // return key
  | "whoosh" // soft air move
  | "whip" // fast whip pan
  | "zoom" // zoom-through
  | "tick" // settings page flip
  | "swish" // a state change inside a shot
  | "snap" // window drops into a zone
  | "blip" // copy confirmation
  | "impact" // title hit
  | "shimmer" // light sweep
  | "chime"; // end card

export type MusicSection =
  | "intro"
  | "title"
  | "wall"
  | "grooveA"
  | "grooveB"
  | "grooveC"
  | "breakdown"
  | "build"
  | "terminal"
  | "outro";

export type TransitionKind =
  | "fade" // from black
  | "flash" // cut through a bloom
  | "continue" // designed continuity between the two shots (no overlap effect)
  | "zoom" // zoom-through
  | "whip" // whip pan with directional blur
  | "wipe" // soft diagonal mask wipe
  | "iris" // circle closes on a point, opens on the next
  | "push" // both shots slide
  | "pull" // dolly back: outgoing shrinks away, incoming settles from close
  | "pop" // hard cut, the incoming panel springs
  | "bloom"; // dissolve through a soft glow

export type Dir = "left" | "right" | "up" | "down";

export interface Transition {
  kind: TransitionKind;
  dir?: Dir;
  /** Frames the effect starts before the cut / runs after it. */
  pre: number;
  post: number;
  /** Point the effect is centered on, in frame px (zoom, iris). */
  at?: [number, number];
  /** Incoming point for iris. */
  to?: [number, number];
}

export interface Cue {
  /** Beats from the start of the shot. */
  at: number;
  sfx?: Sfx;
  gain?: number;
  /** -1 left .. 1 right */
  pan?: number;
  /** Name a component looks up to time its animation. */
  tag?: string;
}

/** A shortcut from the manifest shown as glass keycaps: module id + index into its shortcuts. */
export interface KeySpec {
  module: string;
  shortcut: number;
  at: number;
  /** Beats between key taps. */
  step?: number;
  /** Tap the first key this many times (Find My Mouse: Left ⌃ twice). */
  repeatFirst?: number;
  /** Explicit taps instead of the default sweep: [key index, beat]. */
  presses?: [number, number][];
  until?: number;
}

/** Lower-third caption: module (name from the manifest) + line from copy.ts. */
export interface CaptionSpec {
  module: string;
  copy: string;
  at: number;
  until?: number;
}

export type ShotId =
  | "cold"
  | "title"
  | "wall"
  | "cmdpal"
  | "fancyzones"
  | "colorpicker"
  | "textextractor"
  | "zoomit"
  | "advancedpaste"
  | "powerrename"
  | "keyboardmanager"
  | "mouseutils"
  | "peek"
  | "awake"
  | "workspaces"
  | "settings"
  | "languages"
  | "terminal"
  | "end";

export interface ShotSpec {
  id: ShotId;
  beats: number;
  music: MusicSection;
  enter: Transition;
  cues: Cue[];
  keys?: KeySpec[];
  captions?: CaptionSpec[];
  /** Scene images (relative to public/assets/app/<lang>/) the shot shows. */
  assets?: string[];
  /** Only included when more than one UI language is exported. */
  needsLanguages?: boolean;
}

const t = (kind: TransitionKind, pre: number, post: number, extra: Partial<Transition> = {}): Transition => ({
  kind,
  pre,
  post,
  ...extra,
});

/** Evenly spaced cues (typing, page flips). */
function run(from: number, count: number, step: number, sfx: Sfx, tag?: string, gain?: number): Cue[] {
  return Array.from({ length: count }, (_, i) => ({ at: from + i * step, sfx, tag: tag ? `${tag}${i}` : undefined, gain }));
}

const TYPE_STEP = 0.125;
export const CMD_PASTE = "mactoys paste json data.csv";
export const CMD_ZONES = "mactoys zones";
export const TERMINAL = { paste: 0.75, pasteEnter: 0.75 + CMD_PASTE.length * TYPE_STEP + 0.25, zones: 5.25, typeStep: TYPE_STEP };
const zonesEnter = TERMINAL.zones + CMD_ZONES.length * TYPE_STEP + 0.25;

export const SETTINGS_STEP = 0.25;
export const SETTINGS_FIRST = 0.5;
export const SETTINGS_ITEMS = 32; // General + 31 utilities
export const SETTINGS_HOME = 9;

export const SHOTS: ShotSpec[] = [
  {
    id: "cold",
    beats: 10,
    music: "intro",
    enter: t("fade", 0, 40),
    cues: [
      { at: 3.5, tag: "hover" },
      { at: 4, sfx: "click", tag: "click", pan: 0.6 },
      { at: 4.05, sfx: "pop", pan: 0.55 },
      { at: 9.25, sfx: "whoosh", gain: 0.8 },
    ],
    assets: ["ui/quickaccess.png"],
  },
  {
    id: "title",
    beats: 12,
    music: "title",
    enter: t("flash", 6, 18),
    cues: [
      { at: 0, sfx: "impact", tag: "land" },
      { at: 0.75, tag: "name" },
      { at: 2, tag: "line" },
      { at: 7.5, tag: "swap" },
      { at: 8, sfx: "shimmer", gain: 0.6, tag: "count" },
      { at: 11.5, sfx: "whoosh", tag: "burst" },
    ],
  },
  {
    id: "wall",
    beats: 12,
    music: "wall",
    enter: t("continue", 0, 0),
    cues: [
      { at: 0, sfx: "swish", gain: 0.7, tag: "fly" },
      { at: 1.5, tag: "titles" },
      { at: 4, sfx: "shimmer", tag: "sweep" },
      { at: 10.5, sfx: "zoom", tag: "collapse" },
    ],
  },
  {
    id: "cmdpal",
    beats: 9,
    music: "grooveA",
    enter: t("zoom", 8, 16, { at: [960, 540] }),
    keys: [{ module: "cmdpal", shortcut: 0, at: 0.5, until: 3.5 }],
    cues: [
      { at: 1, sfx: "pop", tag: "open" },
      ...[2, 2.25, 2.5, 3].map((at, i): Cue => ({ at, sfx: "type", tag: `type${i}` })),
      { at: 3.5, sfx: "swish", tag: "expand" },
    ],
    captions: [{ module: "cmdpal", copy: "cmdpal", at: 1 }],
    assets: ["scenes/cmdpal.compact.png", "scenes/cmdpal.palette.png"],
  },
  {
    id: "fancyzones",
    beats: 9,
    music: "grooveA",
    enter: t("whip", 9, 12, { dir: "left" }),
    keys: [
      { module: "fancyzones", shortcut: 0, at: 0.5, until: 3.75 },
      { module: "fancyzones", shortcut: 1, at: 4.25 },
    ],
    cues: [
      { at: 4, sfx: "swish", tag: "drag" },
    ],
    captions: [{ module: "fancyzones", copy: "fancyzones", at: 1 }],
    assets: ["scenes/fancyzones.editor.png", "scenes/fancyzones.dragging.png"],
  },
  {
    id: "colorpicker",
    beats: 8,
    music: "grooveA",
    enter: t("wipe", 10, 14),
    keys: [{ module: "colorpicker", shortcut: 0, at: 0.5, until: 3.75 }],
    cues: [
      { at: 4, sfx: "click", tag: "pick" },
      { at: 4.1, sfx: "blip" },
    ],
    captions: [{ module: "colorpicker", copy: "colorpicker", at: 1 }],
    assets: ["scenes/colorpicker.picker.png", "scenes/colorpicker.editor.png"],
  },
  {
    id: "textextractor",
    beats: 7,
    music: "grooveA",
    enter: t("whip", 9, 12, { dir: "up" }),
    keys: [{ module: "textextractor", shortcut: 0, at: 0.5 }],
    cues: [{ at: 3.5, sfx: "blip", tag: "copy" }],
    captions: [{ module: "textextractor", copy: "textextractor", at: 1 }],
    assets: ["scenes/textextractor.selection.png"],
  },
  {
    id: "zoomit",
    beats: 7,
    music: "grooveB",
    enter: t("zoom", 10, 14, { at: [810, 470] }),
    keys: [{ module: "zoomit", shortcut: 1, at: 0.5 }],
    cues: [{ at: 3, sfx: "zoom", gain: 0.5, tag: "zoom" }],
    captions: [{ module: "zoomit", copy: "zoomit", at: 1 }],
    assets: ["scenes/zoomit.draw.png"],
  },
  {
    id: "advancedpaste",
    beats: 8,
    music: "grooveB",
    enter: t("pop", 0, 20),
    keys: [{ module: "advancedpaste", shortcut: 0, at: 0.25 }],
    cues: [
      { at: 0, sfx: "pop" },
      { at: 4, sfx: "swish", tag: "result" },
    ],
    captions: [{ module: "advancedpaste", copy: "advancedpaste", at: 1 }],
    assets: ["scenes/advancedpaste.result.png", "scenes/advancedpaste.window.png"],
  },
  {
    id: "powerrename",
    beats: 8,
    music: "grooveB",
    enter: t("whip", 9, 12, { dir: "right" }),
    cues: run(1.25, 5, 0.5, "tick", "row", 0.8),
    captions: [{ module: "powerrename", copy: "powerrename", at: 1 }],
    assets: ["scenes/powerrename.window.png"],
  },
  {
    id: "keyboardmanager",
    beats: 7,
    music: "grooveB",
    enter: t("push", 12, 14, { dir: "up" }),
    cues: [
      { at: 1, sfx: "swish", gain: 0.5, tag: "focus0" },
      { at: 3, sfx: "swish", gain: 0.5, tag: "focus1" },
      { at: 5, sfx: "swish", gain: 0.5, tag: "focus2" },
    ],
    captions: [{ module: "keyboardmanager", copy: "keyboardmanager", at: 1 }],
    assets: ["scenes/keyboardmanager.editor.png"],
  },
  {
    id: "mouseutils",
    beats: 9,
    music: "grooveC",
    enter: t("iris", 12, 16, { at: [960, 540], to: [960, 541] }),
    keys: [
      { module: "mouseutils", shortcut: 0, at: 0.25, repeatFirst: 2, step: 0.25, until: 3.75 },
      { module: "mouseutils", shortcut: 2, at: 4 },
    ],
    cues: [
      { at: 0.75, sfx: "swish", tag: "find" },
      { at: 4.5, sfx: "pop", tag: "jump" },
      { at: 7, sfx: "click", tag: "pickDisplay" },
    ],
    captions: [{ module: "mouseutils", copy: "mouseutils", at: 1 }],
    assets: ["scenes/mouseutils.findmymouse.png", "scenes/mouseutils.jump.png"],
  },
  {
    id: "peek",
    beats: 9,
    music: "grooveC",
    enter: t("zoom", 14, 16, { at: [960, 540] }),
    keys: [
      { module: "peek", shortcut: 0, at: 0.5, until: 2.75 },
      { module: "peek", shortcut: 1, at: 3, presses: [[1, 3], [1, 5.5]] },
    ],
    cues: [
      { at: 3, sfx: "swish", tag: "next1" },
      { at: 5.5, sfx: "swish", tag: "next2" },
    ],
    captions: [
      { module: "peek", copy: "peek", at: 1, until: 3 },
      { module: "finderaddons", copy: "finderaddons", at: 3.25 },
    ],
    assets: ["scenes/peek.image.png", "scenes/finderaddons.stl.png", "scenes/finderaddons.gcode.png"],
  },
  {
    id: "awake",
    beats: 8,
    music: "grooveC",
    enter: t("push", 12, 14, { dir: "down" }),
    keys: [{ module: "powerdisplay", shortcut: 0, at: 4 }],
    cues: [
      { at: 1, sfx: "click", tag: "click", pan: 0.5 },
      { at: 1.05, sfx: "pop", pan: 0.5, tag: "menu" },
      { at: 4.6, sfx: "pop", pan: 0.6, tag: "flyout" },
    ],
    captions: [
      { module: "awake", copy: "awake", at: 1.25, until: 4 },
      { module: "powerdisplay", copy: "powerdisplay", at: 4.25 },
    ],
    assets: ["scenes/awake.menu.png", "scenes/powerdisplay.flyout.png"],
  },
  {
    id: "workspaces",
    beats: 7,
    music: "grooveC",
    enter: t("wipe", 10, 14, { dir: "right" }),
    keys: [{ module: "workspaces", shortcut: 0, at: 0.5 }],
    cues: [
      { at: 3, sfx: "click", tag: "launch" },
      { at: 3.25, sfx: "pop", tag: "progress" },
    ],
    captions: [{ module: "workspaces", copy: "workspaces", at: 1 }],
    assets: ["scenes/workspaces.editor.png", "scenes/workspaces.progress.png"],
  },
  {
    id: "settings",
    beats: 12,
    music: "breakdown",
    enter: t("pull", 12, 18),
    cues: [
      ...run(SETTINGS_FIRST, SETTINGS_ITEMS, SETTINGS_STEP, "tick", "step", 0.7),
      { at: SETTINGS_HOME - 0.5, sfx: "whoosh", gain: 0.6 },
      { at: SETTINGS_HOME, sfx: "tick", tag: "home" },
    ],
  },
  {
    id: "languages",
    beats: 12,
    music: "build",
    enter: t("continue", 0, 0),
    cues: [], // language swaps are scheduled from the language count (see languageCues)
    needsLanguages: true,
  },
  {
    id: "terminal",
    beats: 12,
    music: "terminal",
    enter: t("whip", 9, 12, { dir: "left" }),
    cues: [
      ...run(TERMINAL.paste, CMD_PASTE.length, TYPE_STEP, "type", undefined, 0.55),
      { at: TERMINAL.pasteEnter, sfx: "enter", tag: "pasteOut" },
      ...run(TERMINAL.zones, CMD_ZONES.length, TYPE_STEP, "type", undefined, 0.55),
      { at: zonesEnter, sfx: "enter", tag: "zonesOut" },
    ],
  },
  {
    id: "end",
    beats: 10,
    music: "outro",
    enter: t("bloom", 18, 24),
    cues: [
      { at: 0, sfx: "chime", tag: "card" },
      { at: 0.5, tag: "name" },
      { at: 1.5, tag: "line" },
      { at: 2.5, tag: "url" },
    ],
  },
];

export interface PlacedShot extends ShotSpec {
  index: number;
  /** First frame of the shot (the cut). */
  from: number;
  frames: number;
  /** Beat of the film the shot starts on. */
  beat: number;
}

export interface Timeline {
  shots: PlacedShot[];
  frames: number;
  beats: number;
  langs: string[];
}

/** Order of the language shot: English, then every other exported language. */
export function languageOrder(langs: string[]): string[] {
  return ["en", ...langs.filter((l) => l !== "en")];
}

/** Beats per language: the cycle fits 8 beats on an eighth-note grid, never faster than an eighth. */
export function languageStep(count: number): number {
  return Math.max(0.5, Math.floor((8 / count) * 2) / 2);
}

export function buildTimeline(langs: string[]): Timeline {
  const multi = langs.length > 1;
  const specs = SHOTS.filter((s) => !s.needsLanguages || multi).map((s) => {
    if (s.id !== "languages") return s;
    // The same grid for every film language; after the cycle the window settles on the film language.
    const order = languageOrder(langs);
    const step = languageStep(order.length);
    const cues: Cue[] = order.map((_, i) => ({ at: 1 + i * step, sfx: i === 0 ? undefined : ("tick" as Sfx), tag: `lang${i}`, gain: 0.9 }));
    cues.push({ at: 1 + order.length * step, sfx: "swish", tag: "settle", gain: 0.7 });
    return { ...s, cues };
  });
  let beat = 0;
  const shots = specs.map((s, index) => {
    const placed: PlacedShot = { ...s, index, beat, from: Math.round(beat * BEAT), frames: Math.round(s.beats * BEAT) };
    beat += s.beats;
    return placed;
  });
  return { shots, beats: beat, frames: Math.round(beat * BEAT), langs };
}

/** Frame (relative to the shot) of a tagged cue. */
export function cueFrame(shot: ShotSpec, tag: string): number {
  const c = shot.cues.find((x) => x.tag === tag);
  if (!c) throw new Error(`shot ${shot.id} has no cue "${tag}"`);
  return c.at * BEAT;
}

/** Bar index (after the pickup) a film beat falls in; negative in the pickup. */
export function barOfBeat(beat: number): number {
  return Math.floor((beat - PICKUP_BEATS) / 4);
}

/** Keycap tap times (beats from shot start), one list per key. */
export function keyTaps(k: KeySpec, keyCount: number): number[][] {
  const out: number[][] = Array.from({ length: keyCount }, () => []);
  if (k.presses) {
    for (const [i, at] of k.presses) if (i < keyCount) out[i].push(at);
    return out;
  }
  const step = k.step ?? 0.25;
  const first = k.repeatFirst ?? 1;
  for (let i = 0; i < first; i++) out[0].push(k.at + i * step);
  for (let i = 1; i < keyCount; i++) out[i].push(k.at + (first - 1 + i) * step);
  return out;
}

/** Every sound effect of the film in frames, transitions included. Used by the audio renderer. */
export interface SfxEvent {
  /** The frame the sound lands on (a hit, or the peak of an air move). */
  frame: number;
  sfx: Sfx;
  gain: number;
  pan: number;
  /** Direction of a transition's motion: -1 leftward, 1 rightward, 0 none. */
  dir: number;
}

export function sfxEvents(tl: Timeline, keyCounts: (k: KeySpec) => number): SfxEvent[] {
  const out: SfxEvent[] = [];
  for (const s of tl.shots) {
    for (const c of s.cues) if (c.sfx) out.push({ frame: s.from + c.at * BEAT, sfx: c.sfx, gain: c.gain ?? 1, pan: c.pan ?? 0, dir: 0 });
    for (const k of s.keys ?? []) {
      keyTaps(k, keyCounts(k)).forEach((taps, i) =>
        taps.forEach((at) => out.push({ frame: s.from + at * BEAT, sfx: "key", gain: 0.8, pan: 0.15 + i * 0.08, dir: 0 })),
      );
    }
    const e = s.enter;
    // the air of a transition peaks on the cut; content moving left travels right to left
    const trans: Partial<Record<TransitionKind, Sfx>> = { whip: "whip", zoom: "zoom", push: "whoosh", pull: "whoosh", wipe: "whoosh", iris: "whoosh" };
    const sfx = trans[e.kind];
    if (sfx && s.index > 0) {
      const dir = e.dir === "left" ? -1 : e.dir === "right" ? 1 : 0;
      out.push({ frame: s.from, sfx, gain: 0.9, pan: 0, dir });
    }
  }
  return out.sort((a, b) => a.frame - b.frame);
}
