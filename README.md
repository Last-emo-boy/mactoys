<p align="center">
  <img src="docs/media/icon.png" width="128" alt="MacToys icon">
</p>

<h1 align="center">MacToys</h1>

<p align="center">
  <b>PowerToys, reimagined for the Mac.</b><br>
  31 power-user utilities in one native menu-bar app for macOS 26.
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="#install">Install</a> ·
  <a href="#utilities">Utilities</a> ·
  <a href="#command-line">Command line</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <img src="docs/media/poster.png" width="860" alt="MacToys: Command Palette, FancyZones, Color Picker and more">
</p>

MacToys brings every utility of [Microsoft PowerToys](https://github.com/microsoft/PowerToys) 0.102 to
macOS: window layouts with FancyZones, a Command Palette launcher, Color Picker, OCR, ZoomIt,
PowerRename, Keyboard Manager, the mouse utilities, Quick Look previews for developer files and more.
It is written in Swift and SwiftUI, follows macOS conventions (menu bar, Liquid Glass, System
Settings–style pages) and is localized into 11 languages.

MacToys is an independent project and is not affiliated with Microsoft.

## Install

There is no signed release yet. Build it from source:

```bash
git clone https://github.com/Last-emo-boy/mactoys.git
cd mactoys
scripts/run.sh            # builds, signs locally, installs to ~/Applications and launches
```

Requirements: macOS 26 or later, Xcode 27 (Swift 6.4). Apple silicon is required for Power Display's
external-monitor control; everything else also works on Intel Macs built from source.

`scripts/run.sh` signs the app with a self-signed "MacToys Dev" certificate it creates in its own
keychain, so the permissions you grant keep working after each rebuild.

### Permissions

macOS asks once for each capability. MacToys works without any of them; the utilities that need one
show a banner with a **Grant** button.

| Permission | Used by |
|---|---|
| Accessibility | Moving windows, global shortcuts, key remapping |
| Input Monitoring | Quick Accent, mouse utilities |
| Screen Recording | Color Picker, Screen Ruler, Text Extractor, ZoomIt, Always On Top, Crop And Lock |
| Automation | Reading the Finder selection (Peek, PowerRename, New+), switching appearance |
| Microphone (optional) | ZoomIt recording audio and snip dictation |
| Location (optional) | Light Switch sunrise and sunset |
| Full Disk Access (optional) | File Locksmith, to see protected files |

## Utilities

**System Tools**

| Utility | What it does | Default shortcut |
|---|---|---|
| Advanced Paste | Paste clipboard content as plain text, Markdown, JSON, files or through your own AI actions. | ⌃ ⌥ V |
| Awake | Keep your Mac awake on demand, without touching Energy settings. | — |
| Color Picker | Pick a color from anywhere on screen and copy it in the format you need. | ⌃ ⌥ C |
| Command Not Found | Suggests the Homebrew package to install when a zsh command is missing. | — |
| Command Palette | Search apps, files, windows, commands, clipboard history and more from one box. | ⌥ Space |
| Light Switch | Switch between light and dark appearance on a schedule or at sunrise and sunset. | ⌃ ⌥ ⇧ D |
| Power Display | Control brightness, contrast, volume and input of your displays from one flyout. | ⌃ ⌥ B |
| Run | A quick launcher with plugin keywords: = calculator, > shell, // URLs, < windows and more. | ⌃ ⌥ Space |
| Screen Ruler | Measure pixels on screen with edge detection. | ⌃ ⌥ M |
| Shortcut Guide | Hold ⌘ to see every shortcut of the frontmost app, plus macOS and MacToys shortcuts. | Hold ⌘ |
| Text Extractor | Copy text from anywhere on screen with on-device OCR. | ⌃ ⌥ T |
| ZoomIt | Zoom, annotate, time breaks and record the screen for presentations. | ⌃ ⌥ 1 |

**Windowing & Layouts**

| Utility | What it does | Default shortcut |
|---|---|---|
| Always On Top | Pin any window above all others with a shortcut. | ⌃ ⌘ T |
| Crop And Lock | Crop part of a window into a live thumbnail that stays on top. | ⌃ ⌥ ⇧ T |
| FancyZones | Create window layouts and snap windows into zones by dragging with ⇧ held, or with the keyboard. | ⌃ ⌥ &#96; |
| Grab And Move | Hold a modifier and drag anywhere in a window to move it, or right-drag to resize. | Hold ⌃ ⌘ Drag |
| Window Hopper | Cycle through the windows of the focused app with previews. | ⌥ &#96; |
| Workspaces | Launch a set of apps into saved window positions with one click. | ⌃ ⌥ W |

**Input / Output**

| Utility | What it does | Default shortcut |
|---|---|---|
| Keyboard Manager | Remap keys and shortcuts, globally or per app. | — |
| Mouse Utilities | Find, highlight, lock, hide, jump, wrap and crosshair your pointer. | Left ⌃ ×2 |
| Mouse Without Borders | Control several Macs with one keyboard and mouse, and share the clipboard. | ⌃ ⌥ ⇧ F1 |
| Quick Accent | Hold a letter and tap Space or an arrow key to type accented characters. | Hold letter Space / ← → |

**File Management**

| Utility | What it does | Default shortcut |
|---|---|---|
| File Locksmith | See which processes are using a file or folder, and end them. | — |
| Finder Add-ons | Quick Look previews and thumbnails for Markdown, source code, SVG, G-code, STL, QOI and more. | — |
| Image Resizer | Resize one or many images from Finder with presets. | — |
| New+ | Create files and folders from your own templates in Finder. | — |
| Peek | Preview files in a quick, keyboard-driven window without opening an app. | ⌃ ⌥ P |
| PowerRename | Bulk rename files with search and replace, regular expressions, numbering and undo. | — |

**Advanced**

| Utility | What it does | Default shortcut |
|---|---|---|
| Environment Variables | Manage environment variables for zsh and GUI apps, grouped into profiles. | — |
| Hosts File Editor | Edit /etc/hosts with validation, ping checks and automatic backups. | — |
| Plist Preview | Inspect, edit and compare property lists and defaults domains. | — |

Every utility can be turned on or off, has its own Settings page with all of PowerToys' options that
make sense on a Mac, and can be driven by `mactoys://` URLs and the command-line tool.

### Where macOS works differently

- **Always On Top** — macOS doesn't let one app raise another app's window level, so a pinned window
  is kept in front by a live mirror; pointing at it brings the real window forward in place.
- **Crop And Lock** — macOS can't embed another app's window; the interactive crop moves the original
  window under the crop when you click it.
- **Registry Preview** becomes **Plist Preview** (property lists and `defaults` domains), **File
  Explorer add-ons** become **Finder Add-ons** (Quick Look extensions), and **Command Not Found**
  suggests Homebrew formulae in zsh.
- **Power Display** talks DDC/CI through IOAVService on Apple silicon; display rotation has no public
  API and is shown read-only.
- **Mouse Without Borders** connects Macs to each other (encrypted, Bonjour discovery); it doesn't
  interoperate with the Windows version.

## Command line

`mactoys` ships inside the app (`MacToys.app/Contents/Helpers/mactoys`); **Settings › General ›
Command-line tool** links it into `/usr/local/bin`.

```bash
mactoys modules                          # list utilities and whether they are on
mactoys paste json data.csv              # Advanced Paste transforms: plain-text, markdown, json, …
pbpaste | mactoys paste markdown
mactoys resize *.heic --preset Medium    # Image Resizer
mactoys locksmith ~/Projects/build       # which processes use these files
mactoys zones                            # FancyZones geometry of the main display
mactoys awake for 1:30                   # Awake, Light Switch and Power Display have full CLIs
mactoys powerdisplay set -n 1 --brightness 70
mactoys open fancyzones editor           # any mactoys:// action
mactoys help
```

Add `--json` to any command for machine-readable output.

## Languages

English, 简体中文, 繁體中文, 日本語, 한국어, Deutsch, Français, Español, Português (Brasil), Italiano and
Русский. Pick one in **Settings › General › Language** (or System Settings › General › Language &
Region › Applications). Translations live in `Resources/Localization/Localizable.xcstrings`; see
[CONTRIBUTING.md](CONTRIBUTING.md#translations) to improve one or add a language.

## Building and testing

```bash
swift build                                   # all targets
swift test                                    # 650+ unit tests
scripts/bundle.sh                             # build/MacToys.app (CONFIG=release for an optimized build)
build/MacToys.app/Contents/MacOS/MacToys --snapshot /tmp/shots --only fancyzones
                                              # render a utility's Settings page and overlays to PNG
```

The project is a Swift package: `MacToysCore` (settings, shortcuts, event tap, window control,
capture, overlays, permissions, UI kit), one target per utility under `Sources/Modules/`,
`PreviewKit` (renderers shared with the Quick Look extensions), the app, the CLI and three app
extensions. See [CONTRIBUTING.md](CONTRIBUTING.md) for the architecture and conventions.

## Credits

Feature set and behavior follow [Microsoft PowerToys](https://github.com/microsoft/PowerToys) (MIT).
Code derived from it is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE)
