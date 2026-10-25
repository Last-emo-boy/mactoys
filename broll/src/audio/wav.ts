// 24-bit PCM WAV writer.

import type { Bus } from "./dsp";
import { SR } from "./dsp";

export function wav24(b: Bus): Uint8Array {
  const n = b.length;
  const data = n * 2 * 3;
  const out = new Uint8Array(44 + data);
  const v = new DataView(out.buffer);
  const str = (o: number, s: string) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF");
  v.setUint32(4, 36 + data, true);
  str(8, "WAVE");
  str(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true); // PCM
  v.setUint16(22, 2, true);
  v.setUint32(24, SR, true);
  v.setUint32(28, SR * 6, true);
  v.setUint16(32, 6, true);
  v.setUint16(34, 24, true);
  str(36, "data");
  v.setUint32(40, data, true);
  let o = 44;
  // TPDF dither at 24-bit is far below audibility; plain rounding keeps the file deterministic.
  for (let i = 0; i < n; i++) {
    for (const ch of [b.l, b.r]) {
      const s = Math.max(-8388608, Math.min(8388607, Math.round(ch[i] * 8388607)));
      v.setUint8(o++, s & 0xff);
      v.setUint8(o++, (s >> 8) & 0xff);
      v.setUint8(o++, (s >> 16) & 0xff);
    }
  }
  return out;
}
