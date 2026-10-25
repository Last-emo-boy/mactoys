# MacToys product B-roll — production brief

MacToys is an open-source, native macOS 26 port of Microsoft PowerToys 0.102: 31 utilities in one
menu-bar app (Swift/SwiftUI), localized into 11 languages, with a `mactoys` command-line tool. It is
about to be published on GitHub. Build the launch film: a polished, fast, Apple-keynote-grade product
B-roll that shows what MacToys does, made entirely in Remotion + React + TypeScript in this folder
(`~/Playground/mactoys/broll`).

## Deliverables

- `out/MacToys_BRoll_en.mp4` — 1920×1080, 60 fps, H.264 (CRF ≈ 16), AAC 48 kHz stereo, ~75–90 s.
- `out/MacToys_BRoll_zh-Hans.mp4` — the same cut with Simplified Chinese captions and Chinese UI
  (it demonstrates the localization). The language is a composition prop (`lang`), not a fork.
- `out/MacToys_Loop.mp4` — a 6–8 s seamless loop (no audio) for the README hero.
- `out/poster.png` — a 1920×1080 still for the GitHub social preview / README.
- The original soundtrack as `out/audio/score.wav` and the final mix `out/audio/mix.wav`.
- `README.md` in this folder: install, preview, render, how to re-export app assets, where to change copy.

## Source material — the app's own UI, nothing invented

`public/assets/app/<lang>/` is written by the app itself (`scripts/export-assets.sh` regenerates it):

- `manifest.json` — language, the 31 modules (id, localized name and summary, SF Symbol, tint,
  category, shortcut bindings, preview-scene list with sizes), categories, the Settings `sidebar`
  list (headers + items with localized titles), a few UI strings.
- `icons/<module>.png` (512 px, transparent) and `icons/app.png` — module tiles and the app mark.
- `scenes/<module>.<scene>.png` — every overlay and tool window, rendered by the app at 2×, most on a
  wallpaper gradient. Examples: `cmdpal.palette`, `cmdpal.compact`, `cmdpal.actions`, `run.run`,
  `fancyzones.editor`, `fancyzones.dragging`, `colorpicker.picker`, `colorpicker.editor`,
  `screenruler.toolbar`, `zoomit.draw`, `zoomit.break`, `textextractor.selection`,
  `advancedpaste.window`, `powerrename.window`, `keyboardmanager.editor`, `mouseutils.findmymouse`,
  `mouseutils.jump`, `peek.code`, `finderaddons.markdown`, `finderaddons.stl`, `awake.menu`,
  `powerdisplay.flyout`, `workspaces.editor`, `workspaces.progress`, `windowhopper.hud`,
  `quickaccent.toolbar`, `shortcutguide.safari`, `hosts.window`, `envvars.window` … (list the folder).
- `pages/<page>.png` — Settings content columns (930 pt wide, 2×, 1400 pt tall so you can scroll),
  for `home`, `general` and every module id. There is no sidebar in them: draw the Settings window
  chrome and sidebar yourself in React from `manifest.sidebar` + `icons/` (macOS 26 look: translucent
  sidebar, 20 pt icon tiles, selected row in accent tint, traffic lights, rounded 12 pt window).
- `ui/quickaccess.png` (menu bar flyout), `ui/welcome.png` (first-run window).
- The design boards the UI was built from: `../design/exports/*.png` — use them as the style reference
  (colors, glass, typography, wallpaper gradient). App icon: `../Resources/App/AppIcon.icns`
  (render it to PNG with `sips` if you need it bigger than icons/app.png).

Only `en` exists right now. Translations are in progress; when they land, `public/assets/app/zh-Hans/`
(and others) will appear with the same structure. Build everything against `manifest.json` +
paths, so switching `lang` swaps every UI image and every app string. Fall back to `en` per file
when a language folder is missing something. Never show the `eo` pseudo-language.

## Honesty rules

- Every UI pixel on screen comes from the exported images or is chrome you draw to frame them (menu
  bar, window frame, sidebar, desktop, cursor, keycaps). Don't fake features, numbers or UI the app
  doesn't have. Captions describe what each utility actually does (use the manifest summaries as the
  source of truth; shorten, don't embellish).
- Shortcuts shown on keycaps come from `manifest.modules[].shortcuts`.
- Say "inspired by Microsoft PowerToys" (not "by Microsoft") if PowerToys is named; MacToys is not
  affiliated with Microsoft.

## Story (≈ 80 s; adjust timing to the music grid)

1. **Cold open (≈ 5 s)** — a macOS desktop (wallpaper gradient from the design), menu bar with the
   MacToys puzzle-piece item; the cursor clicks it and `ui/quickaccess.png` springs open; cut on the
   beat.
2. **Title (≈ 5 s)** — app icon lands, "MacToys", line: "PowerToys, reimagined for the Mac." /
   "为 Mac 重新打造的 PowerToys。" Then "31 utilities · one menu bar".
3. **The wall (≈ 6 s)** — all 31 module icons fly into a grid grouped by the 5 categories, category
   titles from the manifest; a light sweep; the grid collapses into the next shot.
4. **Feature run (≈ 45 s)** — 10–12 vignettes, 3.5–4.5 s each, each on the desktop with a camera
   move (push-in, parallax tilt, rack focus via blur), the module's keycaps appearing as glass
   keycaps, a one-line caption (lower third: icon + name + summary). Suggested set, in this order:
   Command Palette (`cmdpal.palette`, type "time" with a caret before the palette is revealed),
   FancyZones (`fancyzones.editor` → `fancyzones.dragging`), Color Picker (`colorpicker.picker` →
   `colorpicker.editor`), Text Extractor, ZoomIt draw, Advanced Paste, PowerRename, Keyboard
   Manager, Find My Mouse / Mouse Jump, Peek + Quick Look previews (markdown, STL), Awake + Power
   Display flyouts, Workspaces launch. Vary the transitions (match cut, whip, zoom-through, mask
   wipe); no two adjacent vignettes should move the same way.
5. **Every setting (≈ 6 s)** — the Settings window you composite: the sidebar scrolls through all
   31 entries while the content column flips through `pages/*.png` (fast, rhythmic), ending on Home.
6. **Speaks your language (≈ 5 s)** — the Settings window cycles its language: sidebar titles and the
   page image swap per language (en → 简体中文 → 日本語 → Deutsch → Español …, whatever exists), with
   the language's native name as a large label. If only `en` exists at render time, skip this shot
   automatically (the timeline must adapt).
7. **Terminal (≈ 5 s)** — a terminal window types real commands with their real output:
   `mactoys paste json data.csv` (output: a JSON array of two objects `{"name": "Ada", "role":
   "Engineer"}`, `{"name": "Lin", "role": "Designer"}`), `mactoys zones` (prints "Priority Grid on
   Built-in Retina Display" and an ASCII picture of the zones). Monospaced, macOS Terminal look.
8. **End card (≈ 5 s)** — app icon, "MacToys", "Free and open source · macOS 26", the repository URL
   from `src/config.ts` (`REPO_URL`, currently `github.com/Last-emo-boy/mactoys` — a placeholder the
   owner may change), "MIT License".

## Craft bar

- Every frame is a pure function of the frame number (no state, no randomness without a seed), so
  any frame renders alone and renders parallelize.
- One timeline table (shots in bars of the score) drives picture, captions, sound effects and music.
  Cuts land on bar or beat lines.
- Motion: spring physics and custom easing, motion blur on fast moves (`@remotion/motion-blur` or
  drawn trails), soft shadows, glass highlights, subtle film grain/vignette. Text never jitters at
  60 fps (round transforms, `will-change`). Keep UI images crisp: never upscale beyond 1× of the
  2× PNGs at 1080p (they are 2× already, so scale ≤ 0.5 in CSS px ≈ native).
- Typography: SF Pro via `-apple-system, "SF Pro Display", "SF Pro Text"` (rendering happens on a Mac),
  with Inter from `@remotion/google-fonts` as the fallback for other machines; for Chinese use
  "PingFang SC" with Noto Sans SC fallback. Tight tracking on titles, as Apple does.
- Captions are short (≤ 8 words in English, ≤ 16 characters in Chinese), written by you per shot in
  `src/copy.ts` for `en` and `zh-Hans`; utility names come from the manifest so they match the app.
- **Music**: write and synthesize an original score in TypeScript (offline, deterministic, no
  samples, no network): modern, bright, confident electronic (≈ 112–124 BPM): pads, plucked arp, sub
  bass, punchy kick, hats, a riser into the title and into the end card, a breakdown for the "every
  setting" moment. Plus UI sound design synced to picture events (clicks, keycap taps, whooshes on
  transitions, a soft chime on the end card). Master to about −14 LUFS integrated, ≤ −1 dBTP. Write
  your own small synth/DSP (oscillators, ADSR, filters, reverb, delay, sidechain duck, limiter);
  don't copy code from other projects.
- Pin Remotion and its packages to `4.0.534` (known good on this machine), React 19, TypeScript,
  `pnpm`. Node 24 and ffmpeg are installed.

## Verify

- `pnpm typecheck` clean; a `pnpm check` script that validates the timeline (shots tile the
  duration, every shot's assets exist for `en`).
- Render stills of every shot (`npx remotion still …` or a small stills script that tiles them into
  a contact sheet) and look at them with the Read tool — check crispness, alignment, text overflow,
  safe margins, contrast. Fix and re-render until each shot looks finished.
- Render both films, then sample frames from the MP4s (ffmpeg) into a contact sheet and look at it.
  Check audio levels with ffmpeg's `ebur128` filter.

## Where you may write

Only inside `~/Playground/mactoys/broll/`. Don't edit the Swift app; if you need a different export
(another size, another scene), write it down in your report. `node_modules/`, `out/` and
`public/assets/app/` are gitignored — never commit them. Commit the project sources to the repo
(`git -C ~/Playground/mactoys add broll && git commit`) with no AI attribution in messages.

## Report

What you built (shots, timings, music), how to render, what you'd improve with more time, and any
asset the app should export for a better film.
