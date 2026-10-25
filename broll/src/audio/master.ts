// Loudness (ITU-R BS.1770 / EBU R128 integrated), true peak (4× oversampled), a look-ahead
// brickwall limiter, and normalization to a loudness target under a true-peak ceiling.

import { Biquad, Bus, SR } from "./dsp";

/** Integrated loudness in LUFS (K-weighting, 400 ms blocks with 75 % overlap, absolute + relative gates). */
export function integratedLufs(b: Bus): number {
  // K-weighting at 48 kHz: the standard's pre-filter (high shelf) and RLB high-pass.
  const kw = () => [new Biquad(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585), new Biquad(1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)];
  const [l1, l2] = kw();
  const [r1, r2] = kw();
  const hop = Math.round(SR * 0.1);
  const nHops = Math.floor(b.length / hop);
  const hopPow = new Float64Array(nHops);
  for (let h = 0; h < nHops; h++) {
    let acc = 0;
    for (let i = h * hop; i < (h + 1) * hop; i++) {
      const l = l2.process(l1.process(b.l[i]));
      const r = r2.process(r1.process(b.r[i]));
      acc += l * l + r * r;
    }
    hopPow[h] = acc / hop;
  }
  const blocks: number[] = [];
  for (let h = 0; h + 4 <= nHops; h++) blocks.push((hopPow[h] + hopPow[h + 1] + hopPow[h + 2] + hopPow[h + 3]) / 4);
  const lufs = (p: number) => -0.691 + 10 * Math.log10(p);
  const abs = blocks.filter((p) => lufs(p) > -70);
  if (!abs.length) return -Infinity;
  const mean = (a: number[]) => a.reduce((x, y) => x + y, 0) / a.length;
  const rel = lufs(mean(abs)) - 10;
  const gated = abs.filter((p) => lufs(p) > rel);
  return lufs(mean(gated));
}

// 4× interpolation filter: windowed sinc, 12 taps per phase.
const TAPS = 12;
const PHASES = 4;
const FIR: Float64Array[] = Array.from({ length: PHASES }, (_, ph) => {
  const out = new Float64Array(TAPS);
  for (let k = 0; k < TAPS; k++) {
    const x = k - TAPS / 2 + 1 - ph / PHASES;
    const sinc = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
    const w = 0.5 + 0.5 * Math.cos((Math.PI * x) / (TAPS / 2 + 0.5));
    out[k] = sinc * w;
  }
  const s = out.reduce((a, v) => a + v, 0);
  for (let k = 0; k < TAPS; k++) out[k] /= s;
  return out;
});

/** Peak of the 4× oversampled signal around each sample (max over both channels). */
function truePeakTrace(b: Bus): Float32Array {
  const tp = new Float32Array(b.length);
  for (const ch of [b.l, b.r]) {
    for (let i = 0; i < ch.length; i++) {
      let m = Math.abs(ch[i]);
      for (let ph = 1; ph < PHASES; ph++) {
        const f = FIR[ph];
        let acc = 0;
        for (let k = 0; k < TAPS; k++) {
          const j = i + k - TAPS / 2 + 1;
          if (j >= 0 && j < ch.length) acc += f[k] * ch[j];
        }
        m = Math.max(m, Math.abs(acc));
      }
      if (m > tp[i]) tp[i] = m;
    }
  }
  return tp;
}

export function truePeakDb(b: Bus): number {
  const tp = truePeakTrace(b);
  let m = 0;
  for (let i = 0; i < tp.length; i++) if (tp[i] > m) m = tp[i];
  return 20 * Math.log10(m || 1e-12);
}

/**
 * Brickwall limiter on the true-peak trace: gain = moving average over the look-ahead window of the
 * forward minimum of the required gain (so every peak is fully reduced when it arrives), then a
 * smooth release.
 */
export function limit(b: Bus, ceilingDb: number, lookahead = 0.0025, release = 0.12): void {
  const ceil = 10 ** (ceilingDb / 20);
  const tp = truePeakTrace(b);
  const n = b.length;
  const L = Math.max(2, Math.round(lookahead * SR));
  const need = new Float32Array(n);
  for (let i = 0; i < n; i++) need[i] = tp[i] > ceil ? ceil / tp[i] : 1;
  // forward minimum over [i, i + L) with a monotonic deque
  const fwd = new Float32Array(n);
  const dq = new Int32Array(n + L);
  let head = 0,
    tail = 0;
  for (let i = n - 1; i >= 0; i--) {
    while (tail > head && need[dq[tail - 1]] >= need[i]) tail--;
    dq[tail++] = i;
    while (dq[head] >= i + L) head++;
    fwd[i] = need[dq[head]];
  }
  // average of the last L forward minima
  const avg = new Float32Array(n);
  let acc = 0;
  for (let i = 0; i < n; i++) {
    acc += fwd[i];
    if (i >= L) acc -= fwd[i - L];
    avg[i] = acc / Math.min(i + 1, L);
  }
  const rel = Math.exp(-1 / (release * SR));
  let g = 1;
  for (let i = 0; i < n; i++) {
    g = Math.min(avg[i], 1 - (1 - g) * rel);
    b.l[i] *= g;
    b.r[i] *= g;
  }
}

/** Gain to `targetLufs`, limit to `ceilingDb` true peak; repeats to settle the loudness lost to limiting. */
export function normalize(b: Bus, targetLufs: number, ceilingDb: number): { lufs: number; tp: number } {
  const src = { l: b.l.slice(), r: b.r.slice() };
  let gainDb = targetLufs - integratedLufs(b);
  for (let pass = 0; pass < 4; pass++) {
    const g = 10 ** (gainDb / 20);
    for (let i = 0; i < b.length; i++) {
      b.l[i] = src.l[i] * g;
      b.r[i] = src.r[i] * g;
    }
    limit(b, ceilingDb);
    const got = integratedLufs(b);
    if (Math.abs(got - targetLufs) < 0.05) break;
    gainDb += targetLufs - got;
  }
  return { lufs: integratedLufs(b), tp: truePeakDb(b) };
}
