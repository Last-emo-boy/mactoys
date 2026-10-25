#!/bin/zsh
# Regenerates public/assets/app/<lang>/ from the app itself (icons, pages, scenes, manifest).
#   broll/scripts/export-assets.sh            # every shipped language
#   broll/scripts/export-assets.sh en zh-Hans # just these
set -euo pipefail
BROLL=${0:A:h:h}
ROOT=${BROLL:h}
APP="$ROOT/build/MacToys.app"
[[ -x "$APP/Contents/MacOS/MacToys" ]] || "$ROOT/scripts/bundle.sh"
langs=("$@")
(( ${#langs} )) || langs=($(python3 "$ROOT/scripts/i18n.py" languages))
for lang in $langs; do
  rm -rf "$BROLL/public/assets/app/$lang"
  "$APP/Contents/MacOS/MacToys" --export-assets "$BROLL/public/assets/app" -AppleLanguages "($lang)" | grep -v '^wrote'
done
# The 1024 px app icon for the title and end card (icons/app.png is only 512 px).
sips -s format png "$ROOT/Resources/App/AppIcon.icns" --out "$BROLL/public/assets/app/appicon.png" >/dev/null
