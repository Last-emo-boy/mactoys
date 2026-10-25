// Film-wide constants. Everything time-based derives from FPS and BPM so cuts sit on the beat grid.

/** Repository shown on the end card. Placeholder until the project is published. */
export const REPO_URL = "github.com/Last-emo-boy/mactoys";

export const WIDTH = 1920;
export const HEIGHT = 1080;
export const FPS = 60;
export const BPM = 120;
/** Frames per beat (30 at 120 BPM / 60 fps). */
export const BEAT = (FPS * 60) / BPM;
export const BAR = BEAT * 4;
/** The score opens with a two-beat pickup, so bar lines sit at beat 2 + 4k. */
export const PICKUP_BEATS = 2;

export const SAMPLE_RATE = 48000;
export const SAMPLES_PER_FRAME = SAMPLE_RATE / FPS;

/** Film languages with written copy (src/copy.ts). Any exported UI language can appear in the language shot. */
export const FILM_LANGS = ["en", "zh-Hans"] as const;
export type FilmLang = (typeof FILM_LANGS)[number];
