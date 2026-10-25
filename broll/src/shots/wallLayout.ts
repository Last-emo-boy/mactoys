// The wall: every utility icon, grouped by the manifest's categories (sidebar order), three rows high.

import type { Manifest } from "../assets";
import { HEIGHT, WIDTH } from "../config";

export interface WallIcon {
  id: string;
  x: number; // center
  y: number;
  group: number;
  order: number;
}
export interface WallGroup {
  title: string;
  x: number;
  y: number;
  w: number;
}
export interface WallLayout {
  icons: WallIcon[];
  groups: WallGroup[];
  size: number;
}

export function wallLayout(m: Manifest, size = 112, gap = 22, groupGap = 62, cy = HEIGHT / 2 + 34): WallLayout {
  const groups: { title: string; ids: string[] }[] = [];
  for (const e of m.sidebar) {
    if (e.kind === "header") groups.push({ title: e.title, ids: [] });
    else if (groups.length && e.id) groups[groups.length - 1].ids.push(e.id);
  }
  const rows = 3;
  const pitch = size + gap;
  const cols = groups.map((g) => Math.ceil(g.ids.length / rows));
  const total = cols.reduce((a, c) => a + c * pitch - gap, 0) + groupGap * (groups.length - 1);
  let x = (WIDTH - total) / 2;
  const top = cy - (rows * pitch - gap) / 2;
  const icons: WallIcon[] = [];
  const out: WallGroup[] = [];
  let order = 0;
  groups.forEach((g, gi) => {
    const c = cols[gi];
    const r = Math.ceil(g.ids.length / c);
    const y0 = top + ((rows - r) * pitch) / 2;
    g.ids.forEach((id, i) => {
      const col = i % c,
        row = Math.floor(i / c);
      icons.push({ id, x: x + col * pitch + size / 2, y: y0 + row * pitch + size / 2, group: gi, order: order++ });
    });
    out.push({ title: g.title, x, y: top - 22, w: c * pitch - gap });
    x += c * pitch - gap + groupGap;
  });
  return { icons, groups: out, size };
}
