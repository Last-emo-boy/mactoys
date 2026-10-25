# Contributing to MacToys

Thanks for helping. Bug reports, fixes, new PowerToys parity work and translations are all welcome.

## Build and run

```bash
swift build && swift test        # build every target, run the unit tests
scripts/run.sh                   # bundle, sign locally, install to ~/Applications, launch
scripts/run.sh --debug           # same, plus mactoys://app/debug-state and debug-screenshot dumps
```

`scripts/run.sh` replaces `~/Applications/MacToys.app`. To stop MacToys quickly (for example if a
remap misbehaves): `pkill MacToys`.

## Layout

| Path | What |
|---|---|
| `Sources/MacToysCore` | Shared toolkit: `Persisted` settings, `HotkeyCenter`, `InputTap` (one prioritized event tap), `WindowRef` (Accessibility windows), `ScreenCapture`/`LiveCapture`, `OverlayPanel`/`FloatingPanel`/`HUD`, `PermissionCenter`, `ClipboardHistory`, the Settings UI kit (`SettingsPage`, `RowLabel`, `ShortcutRow`…) |
| `Sources/Modules/<Name>` | One target per utility; each module is a `ToyModule` (`start()`/`stop()`, `settingsView()`, `quickActions`, `shortcutBindings`, `handle(AppCommand)`, `previewScenes`) |
| `Sources/PreviewKit` | Markdown, code highlighting, SVG, G-code, STL, QOI, CSV, SQLite renderers (Peek, Finder Add-ons, Quick Look) |
| `Sources/MacToys` | The app: menu bar, Settings window, Home, General, Welcome |
| `Sources/MacToysCLI` | The `mactoys` command-line tool |
| `Sources/Extensions` | Quick Look preview/thumbnail and Finder Sync extensions (wrapped into `.appex` by `scripts/bundle.sh`) |
| `Resources/` | Info.plists, entitlements, app icon, String Catalogs |
| `design/` | The Pencil design file and its PNG exports |
| `broll/` | The Remotion product film |

## Conventions

- `start()` installs everything a module needs and `stop()` removes all of it; both are idempotent.
- Missing permissions never crash or spin: degrade quietly; the Settings banner explains.
- Pure logic (parsers, geometry, transforms) lives in plain types with unit tests (swift-testing).
- Every overlay and window has a `previewScene` with sample data. Check UI without permissions:
  `build/MacToys.app/Contents/MacOS/MacToys --snapshot /tmp/shots --only <module-id>`.
- Tests run in the machine's locale: pass an explicit `Locale(identifier: "en_US")` when you assert
  formatted output.

## Translations

User-facing text is localized through String Catalogs (`Resources/Localization/*.xcstrings`, editable
in Xcode). Every target compiles with `-emit-localized-strings`, so string literals passed to
`LocalizedStringKey`, `LocalizedStringResource` or `String.LocalizationValue` are extracted
automatically.

```bash
python3 scripts/i18n.py sync                 # rebuild, then merge new keys into the catalog
python3 scripts/i18n.py status               # progress per language
python3 scripts/i18n.py export fr /tmp/fr.json         # untranslated strings as JSON
python3 scripts/i18n.py import fr /tmp/fr.json         # merge translations (placeholders are checked)
python3 scripts/i18n-lint.py                 # find literal titles that would show untranslated
PSEUDO=1 scripts/bundle.sh                   # adds a pseudo-language that ⟦brackets⟧ every localized string
build/MacToys.app/Contents/MacOS/MacToys --snapshot /tmp/eo --only fancyzones -AppleLanguages "(eo)"
```

Writing localizable code:

- SwiftUI literals (`Text("…")`, `Button("…")`, `Toggle("…")`, `Section("…")`) just work.
- Other UI strings: `String(localized: "…", comment: "…")` where the literal is written. Interpolate
  inside one key (`"\(n) files"`); never concatenate sentence pieces.
- `RowLabel("Title", subtitle: path)` shows both strings verbatim — use
  `RowLabel("Title", verbatimSubtitle: path)` or `RowLabel(title: Text("…"), subtitle: Text(verbatim: …))`.
- Runtime data (names, paths, sample data) goes through `Text(verbatim:)`.
- Numbers, dates, durations and sizes use locale-aware formatters.

To add a language, add its code to `LANGUAGES` in `scripts/i18n.py`, export, translate, import.

## Commits and pull requests

Keep changes focused, match the surrounding style, and include tests for logic changes. Run
`swift build`, `swift test` and, for UI changes, a snapshot of the affected pages.
