// 7 · From the command line: the bundled `mactoys` tool, typed into a Terminal window drawn here.
// The commands and their output are verbatim from MacToys.app/Contents/Helpers/mactoys
// (`paste json` on a two-row CSV, then `zones` on the built-in display).

import React from "react";
import { AbsoluteFill } from "remotion";
import { BEAT } from "../config";
import { useFilm, useLocalFrame, useShot } from "../context";
import { AppCaption, MenuBar } from "../components/Chrome";
import { Camera, TrafficLights } from "../components/World";
import { clamp, ease, kf } from "../motion";
import { FONT_MONO, FONT_TEXT } from "../theme";
import { CMD_PASTE, CMD_ZONES, cueFrame, TERMINAL } from "../timeline";
import { Desktop } from "./common";

export const PASTE_OUT = `[
  {
    "name": "Ada",
    "role": "Engineer"
  },
  {
    "name": "Lin",
    "role": "Designer"
  }
]`.split("\n");

export const ZONES_OUT = [
  "Priority Grid on Built-in Retina Display",
  ...Array.from({ length: 5 }, () => "11111111333333333333333344444444"),
  ...Array.from({ length: 5 }, () => "22222222333333333333333355555555"),
  "  1: x 12 y 45 · 420 × 501",
  "  2: x 12 y 558 · 420 × 500",
  "  3: x 444 y 45 · 840 × 1013",
  "  4: x 1296 y 45 · 420 × 501",
  "  5: x 1296 y 558 · 420 × 500",
];

const WIN = { w: 1180, h: 720, x: 960 - 590, y: 90 };
const BAR = 52;
const PAD = 26;
const FONT = 26;
const LINE = 36;
const VISIBLE = Math.floor((WIN.h - BAR - PAD * 2) / LINE);
const PROMPT = "~ %";

type Line = { text: string; prompt?: boolean; at: number };

export const Terminal: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const { copy } = useFilm();
  const end = shot.frames;
  const step = TERMINAL.typeStep * BEAT;
  const pasteAt = TERMINAL.paste * BEAT;
  const zonesAt = TERMINAL.zones * BEAT;
  const pasteOut = cueFrame(shot, "pasteOut");
  const zonesOut = cueFrame(shot, "zonesOut");

  // typed characters: one per type cue
  const typed = (cmd: string, from: number) => cmd.slice(0, clamp(Math.floor((f - from) / step) + 1, 0, cmd.length));
  const lines: Line[] = [{ text: typed(CMD_PASTE, pasteAt), prompt: true, at: -999 }];
  PASTE_OUT.forEach((t, i) => lines.push({ text: t, at: pasteOut + 2 + i * 0.7 }));
  lines.push({ text: f >= zonesAt - 20 ? typed(CMD_ZONES, zonesAt) : "", prompt: true, at: pasteOut + 10 });
  ZONES_OUT.forEach((t, i) => lines.push({ text: t, at: zonesOut + 2 + i * 0.7 }));
  lines.push({ text: "", prompt: true, at: zonesOut + 2 + ZONES_OUT.length * 0.7 + 2 });
  const shown = lines.filter((l) => f >= l.at);
  const last = shown.length - 1;

  // the view follows the last line once the window is full (eased, a beat at a time)
  const scrollLines = (n: number) => Math.max(0, n - VISIBLE);
  const pasteEnd = 1 + PASTE_OUT.length + 1;
  const zonesEnd = pasteEnd + ZONES_OUT.length + 1;
  const scroll = kf(f, [[pasteOut, 0], [pasteOut + 14, scrollLines(pasteEnd)], [zonesOut, scrollLines(pasteEnd)], [zonesOut + 22, scrollLines(zonesEnd)]], ease.outSoft) * LINE;

  // block cursor: solid while typing, blinking on the beat when idle
  const typing = (f >= pasteAt - 2 && f < pasteOut) || (f >= zonesAt - 2 && f < zonesOut);
  const blink = typing || Math.floor(f / (BEAT / 2)) % 2 === 0;

  const zoom = kf(f, [[-12, 1.0], [end + 14, 1.06]], ease.inOut);
  const ry = kf(f, [[-12, -7], [end + 14, -2.5]], ease.inOut);
  const rx = kf(f, [[-12, 4], [end + 14, 1.5]], ease.inOut);
  const cy = kf(f, [[-12, 500], [end + 14, 490]], ease.inOut);
  return (
    <AbsoluteFill>
      <Camera zoom={zoom} rx={rx} ry={ry} cy={cy} perspective={2000}>
        <Desktop dim={0.8} />
        <MenuBar />
        <div
          style={{
            position: "absolute",
            left: WIN.x,
            top: WIN.y,
            width: WIN.w,
            height: WIN.h,
            borderRadius: 20,
            overflow: "hidden",
            background: "rgba(24,22,34,0.86)",
            backdropFilter: "blur(30px) saturate(1.5)",
            WebkitBackdropFilter: "blur(30px) saturate(1.5)",
            boxShadow: "0 50px 120px rgba(6,4,26,0.6), 0 16px 40px rgba(6,4,26,0.4), inset 0 0 0 1px rgba(255,255,255,0.12)",
          }}
        >
          <div style={{ position: "absolute", left: 0, top: 0, right: 0, height: BAR, borderBottom: "1px solid rgba(255,255,255,0.07)", background: "rgba(255,255,255,0.035)" }}>
            <TrafficLights x={20} y={20} size={13} />
            <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", fontFamily: FONT_TEXT, fontSize: 15, fontWeight: 600, color: "rgba(255,255,255,0.55)" }}>
              ~ — zsh
            </div>
          </div>
          <div style={{ position: "absolute", left: PAD + 4, top: BAR + PAD, right: PAD, bottom: PAD, overflow: "hidden" }}>
            <div style={{ position: "absolute", left: 0, top: -scroll, fontFamily: FONT_MONO, fontSize: FONT, lineHeight: `${LINE}px`, whiteSpace: "pre", color: "rgba(236,236,245,0.92)" }}>
              {shown.map((l, i) => (
                <div key={i} style={{ height: LINE }}>
                  {l.prompt && <span style={{ color: "#8fe3a8", fontWeight: 600 }}>{PROMPT} </span>}
                  <span style={{ color: l.prompt ? "#ffffff" : undefined }}>{l.text}</span>
                  {i === last && l.prompt && blink && (
                    <span style={{ display: "inline-block", width: FONT * 0.6, height: LINE - 6, transform: "translateY(5px)", background: "rgba(255,255,255,0.85)", marginLeft: l.text ? 1 : 0 }} />
                  )}
                </div>
              ))}
            </div>
          </div>
        </div>
      </Camera>
      <AppCaption title="mactoys" mono line={copy.terminal} appear={BEAT * 1.5} leave={end - 18} />
    </AbsoluteFill>
  );
};
