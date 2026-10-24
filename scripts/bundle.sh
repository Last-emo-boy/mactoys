#!/bin/zsh
# Builds every product and assembles build/MacToys.app (app + CLI + three app extensions),
# signed with the local "MacToys Dev" identity.  CONFIG=release scripts/bundle.sh
set -euo pipefail
CONFIG=${CONFIG:-debug}
ROOT=${0:A:h:h}
cd "$ROOT"

swift build -c "$CONFIG" 2>&1 | grep -E "error|warning: unreachable|Build complete|Compiling.*error" || true
swift build -c "$CONFIG" >/dev/null
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP="$ROOT/build/MacToys.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

cp "$BIN/MacToys" "$APP/Contents/MacOS/MacToys"
cp "$BIN/mactoys-cli" "$APP/Contents/Helpers/mactoys"
cp Resources/App/Info.plist "$APP/Contents/Info.plist"
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
[[ -f Resources/App/AppIcon.icns ]] && cp Resources/App/AppIcon.icns "$APP/Contents/Resources/"
# Plain resource folders (templates, scripts, data) copied verbatim into Contents/Resources.
[[ -d Resources/App/Bundle ]] && cp -R Resources/App/Bundle/ "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

for ext in QuickLook Thumbnails FinderSync; do
  EXE="MacToys$ext"
  X="$APP/Contents/PlugIns/$EXE.appex"
  mkdir -p "$X/Contents/MacOS"
  cp "$BIN/$EXE" "$X/Contents/MacOS/$EXE"
  cp "Resources/Extensions/$ext/Info.plist" "$X/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$X/Contents/Info.plist"
done

"$ROOT/scripts/dev-identity.sh"
KC="$HOME/Library/Keychains/mactoys-dev.keychain-db"
sign() { codesign --force --sign "MacToys Dev" --keychain "$KC" --timestamp=none --options runtime "$@" }
for ext in QuickLook Thumbnails FinderSync; do
  sign --entitlements "Resources/Extensions/$ext/$ext.entitlements" "$APP/Contents/PlugIns/MacToys$ext.appex"
done
sign --identifier com.w33d.mactoys.cli "$APP/Contents/Helpers/mactoys"
sign --entitlements Resources/App/MacToys.entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "Bundled $APP"
