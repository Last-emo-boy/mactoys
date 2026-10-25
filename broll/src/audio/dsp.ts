// Small offline DSP kit for the score: oscillators, envelopes, filters, delay, reverb, buses.
// Everything renders into Float32Array buffers at SR; all randomness is seeded.

export const SR = 48000;
export const TAU = Math.PI * 2;

export const midiHz = (m: number) => 440 * 2 ** ((m - 69) / 12);
export const dbGain = (db: number) => 10 ** (db / 20);
export const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Seeded uniform random numbers (mulberry32). */
export class Rng {
  private s: number;
  constructor(seed: number) {
    this.s = seed >>> 0;
  }
  next(): number {
    let t = (this.s += 0x6d2b79f5);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  /** -1 .. 1 */
  bi(): number {
    return this.next() * 2 - 1;
  }
}

/** PolyBLEP residual for band-limited steps. `t` phase 0..1, `dt` phase increment. */
function blep(t: number, dt: number): number {
  if (t < dt) {
    const x = t / dt;
    return x + x - x * x - 1;
  }
  if (t > 1 - dt) {
    const x = (t - 1) / dt;
    return x * x + x + x + 1;
  }
  return 0;
}

/** Band-limited sawtooth. */
export class Saw {
  phase: number;
  constructor(phase = 0) {
    this.phase = phase;
  }
  next(hz: number): number {
    const dt = hz / SR;
    const v = 2 * this.phase - 1 - blep(this.phase, dt);
    this.phase += dt;
    if (this.phase >= 1) this.phase -= 1;
    return v;
  }
}

/** Band-limited pulse with width `pw`. */
export class Pulse {
  phase: number;
  constructor(phase = 0) {
    this.phase = phase;
  }
  next(hz: number, pw = 0.5): number {
    const dt = hz / SR;
    let v = this.phase < pw ? 1 : -1;
    v += blep(this.phase, dt);
    let p2 = this.phase - pw;
    if (p2 < 0) p2 += 1;
    v -= blep(p2, dt);
    this.phase += dt;
    if (this.phase >= 1) this.phase -= 1;
    return v;
  }
}

export class Sine {
  phase: number;
  constructor(phase = 0) {
    this.phase = phase;
  }
  next(hz: number): number {
    const v = Math.sin(TAU * this.phase);
    this.phase += hz / SR;
    if (this.phase >= 1) this.phase -= 1;
    return v;
  }
}

/**
 * Trapezoidal state-variable filter (topology-preserving, stable under fast modulation).
 * Returns low / band / high outputs of the same pass.
 */
export class SVF {
  private ic1 = 0;
  private ic2 = 0;
  low = 0;
  band = 0;
  high = 0;
  process(x: number, cutoff: number, q = 0.707): number {
    const g = Math.tan((Math.PI * clamp(cutoff, 10, SR * 0.45)) / SR);
    const k = 1 / q;
    const a1 = 1 / (1 + g * (g + k));
    const a2 = g * a1;
    const a3 = g * a2;
    const v3 = x - this.ic2;
    const v1 = a1 * this.ic1 + a2 * v3;
    const v2 = this.ic2 + a2 * this.ic1 + a3 * v3;
    this.ic1 = 2 * v1 - this.ic1;
    this.ic2 = 2 * v2 - this.ic2;
    this.low = v2;
    this.band = v1;
    this.high = x - k * v1 - v2;
    return v2;
  }
}

/** Biquad in direct form I, coefficients normalized by a0. */
export class Biquad {
  private x1 = 0;
  private x2 = 0;
  private y1 = 0;
  private y2 = 0;
  constructor(
    private b0: number,
    private b1: number,
    private b2: number,
    private a1: number,
    private a2: number,
  ) {}
  process(x: number): number {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
    this.x2 = this.x1;
    this.x1 = x;
    this.y2 = this.y1;
    this.y1 = y;
    return y;
  }
  /** RBJ cookbook shapes. */
  static highpass(f: number, q = 0.707) {
    const w = (TAU * f) / SR,
      c = Math.cos(w),
      al = Math.sin(w) / (2 * q),
      a0 = 1 + al;
    return new Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, (-2 * c) / a0, (1 - al) / a0);
  }
  static lowpass(f: number, q = 0.707) {
    const w = (TAU * f) / SR,
      c = Math.cos(w),
      al = Math.sin(w) / (2 * q),
      a0 = 1 + al;
    return new Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, (-2 * c) / a0, (1 - al) / a0);
  }
  static peak(f: number, db: number, q = 1) {
    const A = 10 ** (db / 40),
      w = (TAU * f) / SR,
      c = Math.cos(w),
      al = Math.sin(w) / (2 * q),
      a0 = 1 + al / A;
    return new Biquad((1 + al * A) / a0, (-2 * c) / a0, (1 - al * A) / a0, (-2 * c) / a0, (1 - al / A) / a0);
  }
  static lowShelf(f: number, db: number) {
    const A = 10 ** (db / 40),
      w = (TAU * f) / SR,
      c = Math.cos(w),
      s = Math.sin(w),
      al = (s / 2) * Math.SQRT2,
      sq = 2 * Math.sqrt(A) * al,
      a0 = A + 1 + (A - 1) * c + sq;
    return new Biquad(
      (A * (A + 1 - (A - 1) * c + sq)) / a0,
      (2 * A * (A - 1 - (A + 1) * c)) / a0,
      (A * (A + 1 - (A - 1) * c - sq)) / a0,
      (-2 * (A - 1 + (A + 1) * c)) / a0,
      (A + 1 + (A - 1) * c - sq) / a0,
    );
  }
}

/** Attack / decay / sustain / release; `t` seconds since note on, `len` seconds held. */
export function adsr(t: number, len: number, a: number, d: number, s: number, r: number): number {
  if (t < 0) return 0;
  const held = (u: number) => (u < a ? (u / a) ** 1.5 : u < a + d ? 1 - (1 - s) * ((u - a) / d) : s);
  if (t < len) return held(t);
  const at = held(len);
  const u = (t - len) / r;
  return u >= 1 ? 0 : at * (1 - u) ** 2;
}

/** A stereo buffer. */
export class Bus {
  l: Float32Array;
  r: Float32Array;
  constructor(public length: number) {
    this.l = new Float32Array(length);
    this.r = new Float32Array(length);
  }
  /** Equal-power pan, -1 .. 1. */
  add(i: number, v: number, pan = 0) {
    if (i < 0 || i >= this.length) return;
    const p = (clamp(pan, -1, 1) + 1) * (Math.PI / 4);
    this.l[i] += v * Math.cos(p) * Math.SQRT2;
    this.r[i] += v * Math.sin(p) * Math.SQRT2;
  }
  add2(i: number, l: number, r: number) {
    if (i < 0 || i >= this.length) return;
    this.l[i] += l;
    this.r[i] += r;
  }
  mixInto(dst: Bus, gain = 1, from = 0) {
    for (let i = from; i < this.length && i < dst.length; i++) {
      dst.l[i] += this.l[i] * gain;
      dst.r[i] += this.r[i] * gain;
    }
  }
  scale(g: number | ((i: number) => number)) {
    for (let i = 0; i < this.length; i++) {
      const k = typeof g === "number" ? g : g(i);
      this.l[i] *= k;
      this.r[i] *= k;
    }
  }
}

/** Fractional delay line. */
export class DelayLine {
  private buf: Float32Array;
  private w = 0;
  constructor(maxSamples: number) {
    this.buf = new Float32Array(maxSamples + 2);
  }
  write(x: number) {
    this.buf[this.w] = x;
    this.w = (this.w + 1) % this.buf.length;
  }
  read(delay: number): number {
    let p = this.w - 1 - delay;
    while (p < 0) p += this.buf.length;
    const i = Math.floor(p);
    const f = p - i;
    const a = this.buf[i % this.buf.length];
    const b = this.buf[(i + 1) % this.buf.length];
    return a + (b - a) * f;
  }
}

/** Tempo-synced ping-pong delay, wet only. */
export function pingPong(src: Bus, delaySamples: number, feedback: number, tone: number): Bus {
  const out = new Bus(src.length);
  const dl = new DelayLine(delaySamples + 4);
  const dr = new DelayLine(delaySamples + 4);
  const lpL = new SVF();
  const lpR = new SVF();
  for (let i = 0; i < src.length; i++) {
    const yl = dl.read(delaySamples - 1);
    const yr = dr.read(delaySamples - 1);
    const inMono = (src.l[i] + src.r[i]) * 0.5;
    dl.write(lpL.process(inMono + yr * feedback, tone));
    dr.write(lpR.process(yl * feedback, tone));
    out.l[i] = yl;
    out.r[i] = yr;
  }
  return out;
}

/**
 * Feedback-delay-network reverb: 8 lines, Householder mixing, damping in the loop, gently
 * modulated taps so the tail doesn't ring. Wet only.
 */
export function reverb(src: Bus, opts: { seconds: number; damp: number; predelay?: number; width?: number }): Bus {
  const lens = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116].map((n) => Math.round(n * 1.9));
  const lines = lens.map((n) => new DelayLine(n + 64));
  const lps = lens.map(() => new SVF());
  const fb = lens.map((n) => 10 ** ((-3 * n) / (SR * opts.seconds)));
  const pre = new DelayLine(SR);
  const preD = Math.round((opts.predelay ?? 0.02) * SR);
  const hpIn = Biquad.highpass(180);
  const out = new Bus(src.length);
  const y = new Float64Array(8);
  const width = opts.width ?? 1;
  for (let i = 0; i < src.length; i++) {
    pre.write(hpIn.process((src.l[i] + src.r[i]) * 0.5));
    const x = pre.read(preD);
    let sum = 0;
    for (let k = 0; k < 8; k++) {
      const mod = 6 * Math.sin((TAU * i * (0.13 + k * 0.037)) / SR + k);
      y[k] = lines[k].read(lens[k] + mod);
      sum += y[k];
    }
    const h = (2 / 8) * sum;
    for (let k = 0; k < 8; k++) {
      const v = lps[k].process((y[k] - h) * fb[k], opts.damp);
      lines[k].write(v + x * (k % 2 ? 0.35 : -0.35));
    }
    const l = y[0] + y[2] + y[4] + y[6];
    const r = y[1] + y[3] + y[5] + y[7];
    const m = (l + r) * 0.5,
      s = (l - r) * 0.5 * width;
    out.l[i] = (m + s) * 0.5;
    out.r[i] = (m - s) * 0.5;
  }
  return out;
}

/** Soft saturation. */
export const soft = (x: number) => Math.tanh(x);
