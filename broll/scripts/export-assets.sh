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
