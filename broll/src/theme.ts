// Look of the film, taken from the design boards (../design/exports) and the app's own Wallpaper.

export const FONT_TEXT = `-apple-system, "SF Pro Text", "SF Pro Display", BlinkMacSystemFont, Inter, "Helvetica Neue", sans-serif`;
export const FONT_DISPLAY = `-apple-system, "SF Pro Display", "SF Pro Text", BlinkMacSystemFont, Inter, "Helvetica Neue", sans-serif`;
export const FONT_ZH = `-apple-system, "PingFang SC", "SF Pro Display", "Noto Sans SC", Inter, sans-serif`;
export const FONT_MONO = `ui-monospace, "SF Mono", SFMono-Regular, Menlo, "JetBrains Mono", monospace`;

export const fontFor = (lang: string, display = true) =>
  lang.startsWith("zh") ? FONT_ZH : display ? FONT_DISPLAY : FONT_TEXT;

/** The app's Wallpaper (SnapshotRenderer.swift): four stops, top-leading to bottom-trailing, sRGB. */
export const WALL_STOPS = ["#17215c", "#3d2b8f", "#994087", "#e08a6b"];

/** Utility tints (MacToysCore ModuleTint, design board 01). */
export const TINTS: Record<string, string> = {
  blue: "#0a84ff",
  indigo: "#5e5ce6",
  purple: "#af52de",
  pink: "#ff2d55",
  red: "#ff3b30",
  orange: "#ff9500",
  yellow: "#f5b800",
  green: "#34c759",
  mint: "#00c7be",
  teal: "#30b0c7",
  cyan: "#32ade6",
  graphite: "#8e8e93",
  brown: "#a2845e",
};

export const ACCENT = "#0a84ff";
