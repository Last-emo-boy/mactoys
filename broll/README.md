# MacToys launch film

The MacToys product film, its loop and poster, made in Remotion + React + TypeScript, with a score
synthesized in TypeScript. Every UI pixel comes from images the app exports of itself.

## Install

```sh
cd broll
pnpm install
pnpm export-assets        # writes public/assets/app/<lang>/ from build/MacToys.app (all languages)
pnpm export-assets en     # or only some languages
```

`export-assets` builds the app first if `build/MacToys.app` is missing, and writes the 1024 px app
icon to `public/assets/app/appicon.png`. `en` is required; any other language is used when its
folder exists (each file falls back to `en`), and the language shot appears only when there is more
than one. `eo` is never shown.

## Preview

```sh
pnpm studio               # Remotion Studio: MacToysFilm (prop lang: "en" | "zh-Hans"), MacToysLoop, MacToysPoster
pnpm audio                # renders the score first so the studio plays it
pnpm stills               # every shot at 20/50/85 % → out/stills/*.png and contact sheets
pnpm stills --lang zh-Hans --shot cmdpal,settings --at 0.1,0.5,0.9
```

## Render

```sh
pnpm render               # check, audio, both films, loop, poster
pnpm render zh-Hans       # one film only
```

Outputs in `out/`: `MacToys_BRoll_en.mp4`, `MacToys_BRoll_zh-Hans.mp4` (1920×1080, 60 fps, H.264
CRF 16, AAC 48 kHz), `MacToys_Loop.mp4` (8 s, seamless, no audio), `poster.png`,
`audio/score.wav` (music) and `audio/mix.wav` (music + effects, −14 LUFS, ≤ −1.8 dBTP).

`pnpm check` validates the timeline (shots tile the film, cuts on the beat grid, no two adjacent
transitions alike), the English assets, the shortcuts and caption lengths. `pnpm typecheck` runs tsc.

## Where things live

| What | Where |
| --- | --- |
| Captions, tagline, end card lines (en, zh-Hans) | `src/copy.ts` |
| Repository URL on the end card | `src/config.ts` (`REPO_URL`) |
| Shots, durations in beats, cues, keycaps, captions, transitions | `src/timeline.ts` |
| One component per shot | `src/shots/` |
| Measured geometry of the exported scene images | `src/scenes.ts` |
| Menu bar, pointer, keycaps, lower thirds, grain | `src/components/Chrome.tsx` |
| Settings window chrome and sidebar | `src/components/SettingsWindow.tsx` |
| Score, instruments, effects, mastering | `src/audio/` |

Utility names, shortcuts, sidebar titles and language names come from each language's
`manifest.json`; captions are shortened from the manifest summaries. Changing a shot's length in
`src/timeline.ts` moves everything after it, music included (`pnpm audio` re-renders the score; the
film refuses a mix made for another timeline).
