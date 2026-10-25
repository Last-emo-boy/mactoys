// The Settings window, composited: window chrome and the sidebar are drawn here from the manifest's
// `sidebar` list and icons; the content column is the exported page image (pages/<id>.png).

import React from "react";
import { Img } from "remotion";
import { manifestFor, type SidebarEntry } from "../assets";
import { useAppFiles, useFilm } from "../context";
import { fontFor, TINTS } from "../theme";
import { TrafficLights } from "./World";

export const SW = { w: 1200, h: 780, side: 270, content: 930 };
const LIST_TOP = 98;
const ROW = 32;
const HEADER = 36;

export interface SidebarRow {
  entry: SidebarEntry;
  y: number;
  h: number;
  item: number; // index among items, -1 for headers
}

export function sidebarRows(entries: SidebarEntry[]): { rows: SidebarRow[]; height: number } {
  let y = 0;
  let item = 0;
  const rows: SidebarRow[] = entries.map((e) => {
    const h = e.kind === "header" ? HEADER : ROW;
    const r = { entry: e, y, h, item: e.kind === "item" ? item++ : -1 };
    y += h;
    return r;
  });
  return { rows, height: y + 16 };
}

/** Sidebar scroll that keeps item `index` comfortably in view. */
export function sidebarScrollFor(entries: SidebarEntry[], index: number): number {
  const { rows, height } = sidebarRows(entries);
  const r = rows.find((x) => x.item === index);
  const view = SW.h - LIST_TOP;
  const max = Math.max(0, height - view);
  if (!r) return 0;
  return Math.min(max, Math.max(0, r.y - view * 0.42));
}

const HouseGlyph = () => (
  <svg width="13" height="13" viewBox="0 0 20 20">
    <path fill="#fff" d="M10 2.6 1.8 9.5a.8.8 0 0 0 1 1.2l.9-.75V17a1 1 0 0 0 1 1h3.6v-5h3.4v5h3.6a1 1 0 0 0 1-1V9.95l.9.75a.8.8 0 0 0 1-1.2z" />
  </svg>
);
const GearGlyph = () => (
  <svg width="13" height="13" viewBox="0 0 20 20">
    <g fill="#fff">
      {Array.from({ length: 8 }, (_, i) => (
        <rect key={i} x="8.6" y="1.2" width="2.8" height="4" rx="0.9" transform={`rotate(${i * 45} 10 10)`} />
      ))}
      <circle cx="10" cy="10" r="6.1" />
    </g>
    <circle cx="10" cy="10" r="2.4" fill="#8e8e93" />
  </svg>
);

const Tile: React.FC<{ entry: SidebarEntry; src: (rel: string) => string }> = ({ entry, src }) => {
  if (entry.id === "home" || entry.id === "general") {
    return (
      <div style={{ width: 20, height: 20, borderRadius: 5.5, background: `linear-gradient(180deg, #a5a5ab, ${TINTS.graphite})`, display: "flex", alignItems: "center", justifyContent: "center", boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.12)" }}>
        {entry.id === "home" ? <HouseGlyph /> : <GearGlyph />}
      </div>
    );
  }
  return <Img src={src(`icons/${entry.id}.png`)} style={{ width: 20, height: 20, display: "block" }} />;
};

export interface SettingsWindowProps {
  /** UI language of the sidebar and page. */
  ui: string;
  /** Selected item index (0 = Home). */
  selected: number;
  sidebarScroll: number;
  pageScroll?: number;
  /** Fresh page entering: 0..1 (1 = settled). */
  pageIn?: number;
}

export const SettingsWindow: React.FC<SettingsWindowProps> = ({ ui, selected, sidebarScroll, pageScroll = 0, pageIn = 1 }) => {
  const { index } = useFilm();
  const file = useAppFiles();
  const m = manifestFor(index, ui);
  const { rows } = sidebarRows(m.sidebar);
  const font = fontFor(ui, false);
  const sel = rows.find((r) => r.item === selected);
  const pageId = sel?.entry.id ?? "home";
  return (
    <div
      lang={ui}
      style={{
        position: "absolute",
        left: 0,
        top: 0,
        width: SW.w,
        height: SW.h,
        borderRadius: 12,
        fontFamily: font,
        boxShadow: "0 50px 120px rgba(8,4,36,0.55), 0 18px 40px rgba(8,4,36,0.35)",
      }}
    >
      <div style={{ position: "absolute", inset: 0, borderRadius: 12, overflow: "hidden" }}>
        {/* content column: the exported page */}
        <div style={{ position: "absolute", left: SW.side, top: 0, width: SW.content, height: SW.h, overflow: "hidden", background: "#fff" }}>
          <Img
            src={file(`pages/${pageId}.png`, ui)}
            style={{ position: "absolute", left: 0, top: -pageScroll + (1 - pageIn) * 14, width: SW.content, height: 1400, opacity: 0.55 + 0.45 * pageIn }}
          />
        </div>
        {/* translucent sidebar */}
        <div
          style={{
            position: "absolute",
            left: 0,
            top: 0,
            width: SW.side,
            height: SW.h,
            background: "linear-gradient(180deg, rgba(236,234,244,0.80), rgba(232,230,240,0.86))",
            backdropFilter: "blur(40px) saturate(1.8)",
            WebkitBackdropFilter: "blur(40px) saturate(1.8)",
            boxShadow: "inset -1px 0 0 rgba(0,0,0,0.07)",
          }}
        >
          <TrafficLights x={20} y={20} size={13} />
          <div style={{ position: "absolute", left: 14, top: 52, width: SW.side - 28, height: 30, borderRadius: 9, background: "rgba(0,0,0,0.055)", display: "flex", alignItems: "center", gap: 7, paddingLeft: 10, color: "#8a8a8f", fontSize: 13.5 }}>
            <svg width="13" height="13" viewBox="0 0 20 20">
              <circle cx="8.4" cy="8.4" r="5.6" fill="none" stroke="#8a8a8f" strokeWidth="2" />
              <line x1="12.6" y1="12.6" x2="17" y2="17" stroke="#8a8a8f" strokeWidth="2.2" strokeLinecap="round" />
            </svg>
            {m.strings.search ?? "Search"}
          </div>
          <div style={{ position: "absolute", left: 0, top: LIST_TOP, width: SW.side, bottom: 0, overflow: "hidden" }}>
            <div style={{ position: "absolute", left: 0, top: -sidebarScroll, width: SW.side }}>
              {rows.map((r, i) =>
                r.entry.kind === "header" ? (
                  <div
                    key={i}
                    style={{
                      position: "absolute",
                      left: 22,
                      top: r.y,
                      height: r.h,
                      width: SW.side - 40,
                      display: "flex",
                      alignItems: "flex-end",
                      paddingBottom: 7,
                      boxSizing: "border-box",
                      fontSize: 11,
                      fontWeight: 650,
                      letterSpacing: "0.05em",
                      textTransform: "uppercase",
                      color: "#8e8e93",
                      whiteSpace: "nowrap",
                      overflow: "hidden",
                    }}
                  >
                    {r.entry.title}
                  </div>
                ) : (
                  <div key={i} style={{ position: "absolute", left: 10, top: r.y, width: SW.side - 20, height: r.h - 2 }}>
                    {r.item === selected && <div style={{ position: "absolute", inset: 0, borderRadius: 8, background: "rgba(10,132,255,0.15)" }} />}
                    <div style={{ position: "absolute", left: 10, top: 5 }}>
                      <Tile entry={r.entry} src={(rel) => file(rel, ui)} />
                    </div>
                    <div
                      style={{
                        position: "absolute",
                        left: 41,
                        top: 0,
                        right: 8,
                        height: r.h - 2,
                        display: "flex",
                        alignItems: "center",
                        fontSize: 13.5,
                        fontWeight: r.item === selected ? 600 : 450,
                        color: r.item === selected ? "#0a6ad8" : "#1d1d1f",
                        whiteSpace: "nowrap",
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                      }}
                    >
                      {r.entry.title}
                    </div>
                  </div>
                ),
              )}
            </div>
          </div>
        </div>
      </div>
      <div style={{ position: "absolute", inset: 0, borderRadius: 12, boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.7)", pointerEvents: "none" }} />
    </div>
  );
};
