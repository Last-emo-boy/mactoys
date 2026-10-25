// Geometry of the exported scene images, measured on the 2× PNGs (image pixels).
// `wall`: the scene is drawn on the app's Wallpaper gradient spanning the whole image (so the film can
// extend it seamlessly past the image edges); `dim`: a full-screen overlay darkens it by that factor.

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
  r?: number;
}

export interface SceneGeom {
  file: string;
  w: number;
  h: number;
  wall?: boolean;
  /** Fraction of the wallpaper's brightness left by a dimming overlay (Text Extractor, Find My Mouse). */
  dim?: number;
  /** Background color for scenes drawn on a flat page. */
  flat?: string;
  /** The window or panel inside the image. */
  win?: Rect;
  /** Named points and rects used by camera moves. */
  marks?: Record<string, Rect>;
}

const s = (g: SceneGeom) => g;

export const SCENES = {
  quickaccess: s({ file: "ui/quickaccess.png", w: 760, h: 1120, win: { x: 0, y: 0, w: 760, h: 1120, r: 36 } }),
  palette: s({
    file: "scenes/cmdpal.palette.png",
    w: 1800,
    h: 1280,
    wall: true,
    win: { x: 120, y: 100, w: 1560, h: 1080, r: 40 },
    marks: {
      // the query "time": letter right edges, and the patch of empty glass used to hide untyped letters
      text: { x: 214, y: 134, w: 86, h: 56 },
      caret: { x: 0, y: 140, w: 4, h: 42 },
      result: { x: 136, y: 376, w: 926, h: 92 },
      preview: { x: 1100, y: 330, w: 560, h: 560 },
    },
  }),
  compact: s({
    file: "scenes/cmdpal.compact.png",
    w: 1800,
    h: 520,
    wall: true,
    win: { x: 120, y: 155, w: 1560, h: 210, r: 40 },
    // the placeholder "Search apps, files, commands…"
    marks: { placeholder: { x: 212, y: 192, w: 572, h: 54 } },
  }),
  fzEditor: s({ file: "scenes/fancyzones.editor.png", w: 3200, h: 2000, marks: { panel: { x: 696, y: 576, w: 1808, h: 848 } } }),
  fzDragging: s({ file: "scenes/fancyzones.dragging.png", w: 2880, h: 1800, wall: true, marks: { window: { x: 1000, y: 520, w: 1040, h: 680 } } }),
  picker: s({ file: "scenes/colorpicker.picker.png", w: 1520, h: 940, flat: "#f7f7fa", marks: { loupe: { x: 1035, y: 75, w: 290, h: 290 } } }),
  pickerEditor: s({ file: "scenes/colorpicker.editor.png", w: 1160, h: 840 }),
  textSel: s({
    file: "scenes/textextractor.selection.png",
    w: 2200,
    h: 1280,
    wall: true,
    dim: 0.52,
    marks: { sel: { x: 473, y: 305, w: 878, h: 330 }, bar: { x: 506, y: 664, w: 734, h: 68 } },
  }),
  zoomDraw: s({
    file: "scenes/zoomit.draw.png",
    w: 2000,
    h: 1200,
    wall: true,
    marks: { note: { x: 1270, y: 650, w: 380, h: 310 }, toolbar: { x: 208, y: 32, w: 1584, h: 80 } },
  }),
  pasteList: s({ file: "scenes/advancedpaste.window.png", w: 1040, h: 1280, wall: true, win: { x: 80, y: 80, w: 880, h: 1120, r: 40 } }),
  pasteGrammar: s({ file: "scenes/advancedpaste.result.png", w: 1040, h: 1280, wall: true, win: { x: 80, y: 80, w: 880, h: 1120, r: 40 } }),
  rename: s({
    file: "scenes/powerrename.window.png",
    w: 1960,
    h: 1200,
    // renamed column, six rows of 60 px from y = 168, alternating white / #fafafa
    marks: { renamed: { x: 1290, y: 168, w: 670, h: 60 } },
  }),
  keyboard: s({
    file: "scenes/keyboardmanager.editor.png",
    w: 1520,
    h: 1200,
    marks: {
      row0: { x: 42, y: 398, w: 1436, h: 80, r: 0 },
      row1: { x: 42, y: 716, w: 1436, h: 80, r: 0 },
      row2: { x: 42, y: 878, w: 1436, h: 82, r: 0 },
    },
  }),
  findMouse: s({ file: "scenes/mouseutils.findmymouse.png", w: 1440, h: 920, wall: true, dim: 0.3, marks: { cursor: { x: 720, y: 462, w: 0, h: 0 } } }),
  jump: s({
    file: "scenes/mouseutils.jump.png",
    w: 1440,
    h: 920,
    wall: true,
    win: { x: 160, y: 248, w: 1120, h: 424, r: 40 },
    marks: { thumb: { x: 198, y: 286, w: 554, h: 348 }, cursor: { x: 497, y: 452, w: 0, h: 0 } },
  }),
  peekImage: s({ file: "scenes/peek.image.png", w: 1520, h: 1120, wall: true, win: { x: 32, y: 32, w: 1456, h: 1056, r: 24 } }),
  stl: s({ file: "scenes/finderaddons.stl.png", w: 1720, h: 1320, wall: true, win: { x: 60, y: 60, w: 1600, h: 1200, r: 24 } }),
  gcode: s({ file: "scenes/finderaddons.gcode.png", w: 1720, h: 1320, wall: true, win: { x: 60, y: 60, w: 1600, h: 1200, r: 24 } }),
  awake: s({ file: "scenes/awake.menu.png", w: 840, h: 800, wall: true, win: { x: 229, y: 85, w: 579, h: 500, r: 22 } }),
  display: s({ file: "scenes/powerdisplay.flyout.png", w: 880, h: 1040, wall: true, win: { x: 70, y: 42, w: 741, h: 699, r: 40 } }),
  workspaces: s({ file: "scenes/workspaces.editor.png", w: 1960, h: 1880, marks: { launch: { x: 1790, y: 26, w: 140, h: 54 } } }),
  launching: s({ file: "scenes/workspaces.progress.png", w: 840, h: 800, wall: true, win: { x: 60, y: 65, w: 720, h: 670, r: 40 } }),
};

export type SceneName = keyof typeof SCENES;

/** Letters of the typed query "time" in cmdpal.palette.png: right edge of each prefix. */
export const QUERY_EDGES = [233, 240, 273, 295];
export const QUERY_TEXT_LEFT = 216;
