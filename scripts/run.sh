#!/bin/zsh
# Bundles, installs to ~/Applications, registers the extensions and (re)launches MacToys.
# Extra arguments are passed to the app, e.g. scripts/run.sh --settings
set -euo pipefail
ROOT=${0:A:h:h}
"$ROOT/scripts/bundle.sh"
DEST="$HOME/Applications/MacToys.app"
mkdir -p "$HOME/Applications"
pkill -x MacToys 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
ditto "$ROOT/build/MacToys.app" "$DEST"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Only the installed copy may own the URL scheme and the extensions.
for x in "$ROOT"/build/MacToys.app/Contents/PlugIns/*.appex; do pluginkit -r "$x" 2>/dev/null || true; done
$LSR -u "$ROOT/build/MacToys.app" 2>/dev/null || true
$LSR -f "$DEST"
for x in "$DEST"/Contents/PlugIns/*.appex; do pluginkit -a "$x" 2>/dev/null || true; done
open "$DEST" --args "$@"
echo "Launched $DEST"
