// The desktop world: the app's wallpaper gradient (extendable past any scene image), the camera,
// and placement of the exported UI images.

import React from "react";
import { AbsoluteFill, Img } from "remotion";
import { HEIGHT, WIDTH } from "../config";
import { useAppFile } from "../context";
import { SCENES, type Rect, type SceneName } from "../scenes";
import { WALL_STOPS } from "../theme";
import { ease, mix, prog } from "../motion";

/** A document-unique id usable in url(#…). */
export const useSvgId = (prefix = "g") => prefix + React.useId().replace(/[^a-zA-Z0-9]/g, "");

/**
 * The Wallpaper gradient laid out over `rect` (world px) — top-left to bottom-right corner, isolines
 * perpendicular to the diagonal, like SwiftUI's LinearGradient — and padded far beyond it, so a scene
 * image placed at `rect` blends into it without a seam. `dim` darkens it like a full-screen overlay.
 */
export const Wallpaper: React.FC<{ rect?: Rect; dim?: number; extent?: number }> = ({
  rect = { x: 0, y: 0, w: WIDTH, h: HEIGHT },
  dim,
  extent = 2,
}) => {
  const id = useSvgId("wall");
  const X = -WIDTH * extent,
    Y = -HEIGHT * extent,
    W = WIDTH * (2 * extent + 1),
    H = HEIGHT * (2 * extent + 1);
  return (
    <svg
      width={W}
      height={H}
      viewBox={`${X} ${Y} ${W} ${H}`}
      style={{ position: "absolute", left: X, top: Y, display: "block" }}
    >
      <defs>
        <linearGradient id={id} gradientUnits="userSpaceOnUse" x1={rect.x} y1={rect.y} x2={rect.x + rect.w} y2={rect.y + rect.h}>
          {WALL_STOPS.map((c, i) => (
            <stop key={c} offset={i / (WALL_STOPS.length - 1)} stopColor={c} />
          ))}
        </linearGradient>
      </defs>
      <rect x={X} y={Y} width={W} height={H} fill={`url(#${id})`} />
      {dim !== undefined && <rect x={X} y={Y} width={W} height={H} fill="#000" opacity={1 - dim} />}
    </svg>
  );
};

/** A flat world color reaching past the frame (for scenes drawn on a page). */
export const Flat: React.FC<{ color: string }> = ({ color }) => (
  <div style={{ position: "absolute", left: -WIDTH * 2, top: -HEIGHT * 2, width: WIDTH * 5, height: HEIGHT * 5, background: color }} />
);

export interface CameraProps {
  /** World point shown at the frame center. */
  cx?: number;
  cy?: number;
  zoom?: number;
  /** Degrees. */
  rx?: number;
  ry?: number;
  rz?: number;
  blur?: number;
  perspective?: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}

/** Looks at world point (cx, cy) with `zoom`; tilt in 3D for parallax. */
export const Camera: React.FC<CameraProps> = ({ cx = WIDTH / 2, cy = HEIGHT / 2, zoom = 1, rx = 0, ry = 0, rz = 0, blur = 0, perspective = 2400, children, style }) => (
  <AbsoluteFill style={{ perspective, perspectiveOrigin: "50% 50%", overflow: "hidden", ...style }}>
    <div
      style={{
        position: "absolute",
        left: 0,
        top: 0,
        width: WIDTH,
        height: HEIGHT,
        transformOrigin: "0 0",
        transform: `translate(${WIDTH / 2}px, ${HEIGHT / 2}px) rotateX(${rx}deg) rotateY(${ry}deg) rotateZ(${rz}deg) scale(${zoom}) translate(${-cx}px, ${-cy}px)`,
        transformStyle: "preserve-3d",
        filter: blur > 0.05 ? `blur(${blur}px)` : undefined,
      }}
    >
      {children}
    </div>
  </AbsoluteFill>
);

/** Screen area kept clear of the lower thirds and keycaps (frame px). */
export const SAFE: Rect = { x: 100, y: 64, w: 1720, h: 806 };

export interface View {
  cx: number;
  cy: number;
  zoom: number;
}

/** The camera view that fits world rect `r` into screen box `box` (times `fill`), zoom capped at `max`. */
export function fit(r: Rect, max = Infinity, fill = 1, box: Rect = SAFE): View {
  const zoom = Math.min(max, Math.min(box.w / r.w, box.h / r.h) * fill);
  const bx = box.x + box.w / 2,
    by = box.y + box.h / 2;
  return { zoom, cx: r.x + r.w / 2 - (bx - WIDTH / 2) / zoom, cy: r.y + r.h / 2 - (by - HEIGHT / 2) / zoom };
}

/** Camera view through [frame, view] keys, eased between each pair. */
export function views(f: number, keys: [number, View][], curve: (x: number) => number = ease.inOut): View {
  if (f <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [f1, b] = keys[i];
    const [f0, a] = keys[i - 1];
    if (f <= f1) {
      const t = curve(prog(f, f0, f1));
      return { cx: mix(a.cx, b.cx, t), cy: mix(a.cy, b.cy, t), zoom: mix(a.zoom, b.zoom, t) };
    }
  }
  return keys[keys.length - 1][1];
}

/** World rect covered by a scene image placed at (x, y) with `scale` (display px per image px). */
export function sceneRect(name: SceneName, x: number, y: number, scale: number): Rect {
  const g = SCENES[name];
  return { x, y, w: g.w * scale, h: g.h * scale };
}

/** Where an image-space point of a scene lands in the world. */
export function scenePoint(name: SceneName, x: number, y: number, scale: number, p: { x: number; y: number }) {
  void name;
  return { x: x + p.x * scale, y: y + p.y * scale };
}

export interface SceneImgProps {
  name: SceneName;
  x: number;
  y: number;
  scale: number;
  /** Show only the scene's window (rounded), optionally with its height animated (image px). */
  clipWin?: boolean;
  clipHeight?: number;
  shadow?: boolean;
  opacity?: number;
  lang?: string;
  style?: React.CSSProperties;
  children?: React.ReactNode;
}

/** An exported scene image in world coordinates. Children are positioned in display px of the image. */
export const SceneImg: React.FC<SceneImgProps> = ({ name, x, y, scale, clipWin, clipHeight, shadow, opacity = 1, lang, style, children }) => {
  const g = SCENES[name];
  const src = useAppFile(g.file, lang);
  const w = g.w * scale,
    h = g.h * scale;
  let clip: string | undefined;
  let shadowBox: React.ReactNode = null;
  if (clipWin && g.win) {
    const r = g.win;
    const ch = clipHeight ?? r.h;
    const top = r.y * scale,
      left = r.x * scale,
      right = w - (r.x + r.w) * scale,
      bottom = h - (r.y + ch) * scale;
    clip = `inset(${top}px ${right}px ${bottom}px ${left}px round ${(r.r ?? 0) * scale}px)`;
    if (shadow)
      shadowBox = (
        <div
          style={{
            position: "absolute",
            left,
            top,
            width: r.w * scale,
            height: ch * scale,
            borderRadius: (r.r ?? 0) * scale,
            boxShadow: "0 30px 80px rgba(8,6,30,0.45), 0 10px 24px rgba(8,6,30,0.30), 0 0 0 0.5px rgba(255,255,255,0.12)",
          }}
        />
      );
  }
  return (
    <div style={{ position: "absolute", left: x, top: y, width: w, height: h, opacity, ...style }}>
      {shadowBox}
      <Img src={src} style={{ position: "absolute", left: 0, top: 0, width: w, height: h, clipPath: clip }} />
      {children}
    </div>
  );
};

/** Frame for exported window content that has no frame of its own: rounded corners, hairline, shadow. */
export const WindowFrame: React.FC<{
  name: SceneName;
  x: number;
  y: number;
  scale: number;
  radius?: number;
  trafficLights?: { x: number; y: number };
  opacity?: number;
  dark?: boolean;
  children?: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ name, x, y, scale, radius = 12, trafficLights, opacity = 1, dark, children, style }) => {
  const g = SCENES[name];
  const src = useAppFile(g.file);
  const w = g.w * scale,
    h = g.h * scale;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width: w,
        height: h,
        borderRadius: radius,
        opacity,
        boxShadow: "0 40px 100px rgba(10,6,40,0.50), 0 14px 34px rgba(10,6,40,0.32)",
        ...style,
      }}
    >
      <div style={{ position: "absolute", inset: 0, borderRadius: radius, overflow: "hidden" }}>
        <Img src={src} style={{ width: w, height: h, display: "block" }} />
        {trafficLights && <TrafficLights x={trafficLights.x} y={trafficLights.y} size={12} />}
        {children}
      </div>
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: radius,
          boxShadow: dark ? "inset 0 0 0 1px rgba(255,255,255,0.14)" : "inset 0 0 0 0.5px rgba(0,0,0,0.22), inset 0 1px 0 rgba(255,255,255,0.6)",
          pointerEvents: "none",
        }}
      />
    </div>
  );
};

export const TrafficLights: React.FC<{ x: number; y: number; size?: number; gap?: number }> = ({ x, y, size = 12, gap = 8 }) => (
  <div style={{ position: "absolute", left: x, top: y, display: "flex", gap }}>
    {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
      <div key={c} style={{ width: size, height: size, borderRadius: size, background: c, boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.18)" }} />
    ))}
  </div>
);
