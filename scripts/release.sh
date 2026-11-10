#!/bin/zsh
# Builds a MacToys release for distribution outside the Mac App Store: signed with a Developer ID,
# notarized by Apple and stapled, packaged as dist/MacToys-<version>.dmg with its SHA-256.
#
# One-time setup:
#   1. Join the Apple Developer Program and create a "Developer ID Application" certificate
#      (Xcode › Settings › Accounts › Manage Certificates, or developer.apple.com › Certificates).
#      It must be in the login keychain together with its private key.
#   2. Store notary credentials in the keychain under the profile name "MacToys":
#        xcrun notarytool store-credentials MacToys --apple-id <you@example.com> --team-id <TEAMID>
#      It asks for an app-specific password (account.apple.com › Sign-In and Security).
#
# Usage: scripts/release.sh [--dry-run]
#   --dry-run       sign with the local "MacToys Dev" identity and skip notarization, to check the
#                   build and the DMG without a certificate (Gatekeeper refuses what it makes)
#   SIGN_IDENTITY   the certificate; default: the one "Developer ID Application" identity found
#   NOTARY_PROFILE  the notarytool keychain profile; default: MacToys
#
# It never publishes anything: the last line prints the command that uploads the DMG.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

DRY_RUN=0
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1 }
step() { echo "\n==> $*" }

NOTARY_PROFILE=${NOTARY_PROFILE:-MacToys}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/App/Info.plist)
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)
APP="$ROOT/build/MacToys.app"
DIST="$ROOT/dist"
NAME="MacToys-$VERSION"
(( DRY_RUN )) && NAME="$NAME-dev"
DMG="$DIST/$NAME.dmg"

# Everything that can fail is checked before the long release build.
if (( ! DRY_RUN )); then
  [[ -z $(git status --porcelain) ]] || fail "uncommitted changes: a release is built from a commit"
  if [[ -z ${SIGN_IDENTITY:-} ]]; then
    ids=(${(f)"$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)"})
    (( ${#ids} > 0 )) || fail "no \"Developer ID Application\" certificate in the keychain (setup: scripts/release.sh --help)"
    (( ${#ids} == 1 )) || fail "several Developer ID certificates; pick one with SIGN_IDENTITY=…:$(printf '\n  %s' $ids)"
    SIGN_IDENTITY=$ids[1]
  fi
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    fail "no notary credentials under the keychain profile \"$NOTARY_PROFILE\" (setup: scripts/release.sh --help)"
fi

step "Building MacToys $VERSION ($BUILD, $COMMIT)${SIGN_IDENTITY:+ for $SIGN_IDENTITY}"
if (( DRY_RUN )); then
  CONFIG=release scripts/bundle.sh
else
  CONFIG=release SIGN_IDENTITY=$SIGN_IDENTITY scripts/bundle.sh
fi

step "Checking signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
for code in "$APP" "$APP/Contents/Helpers/mactoys" "$APP"/Contents/PlugIns/*.appex; do
  info=$(codesign -dvv "$code" 2>&1)
  [[ $info == *"(runtime)"* ]] || fail "${code#$ROOT/}: no hardened runtime"
  if (( ! DRY_RUN )); then
    [[ $info == *$'\nTimestamp='* ]] || fail "${code#$ROOT/}: no secure timestamp"
    [[ $info == *"Authority=Developer ID Application"* ]] || fail "${code#$ROOT/}: not signed with a Developer ID"
  fi
done
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
  fail "the app allows debugging (get-task-allow); notarization would refuse it"
fi

# Uploads $1 to Apple's notary service and waits; prints the service's log when it is refused.
notarize() {
  step "Notarizing ${1:t} (a few minutes)"
  local out state id
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
  state=$(print -r -- "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
  if [[ $state != Accepted ]]; then
    id=$(print -r -- "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || print -r -- "$out" >&2
    fail "notarization of ${1:t}: ${state:-no answer}"
  fi
}

mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"

# The app gets its own ticket, so it opens offline once copied out of the disk image.
if (( ! DRY_RUN )); then
  zip="$DIST/$NAME-app.zip"
  ditto -c -k --keepParent "$APP" "$zip"
  notarize "$zip"
  rm -f "$zip"
  xcrun stapler staple "$APP"
fi

step "Packaging ${DMG:t}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/MacToys.app"
ln -s /Applications "$stage/Applications"
out=$(diskutil image create from --format ULFO --volumeName "MacToys $VERSION" "$stage" "$DMG" 2>&1) ||
  { print -r -- "$out" >&2; fail "couldn't create ${DMG:t}"; }

if (( ! DRY_RUN )); then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  step "Checking with Gatekeeper"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$DIST" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
diskutil image info "$DMG" >/dev/null || fail "${DMG:t} doesn't read back"

step "Done: ${DMG#$ROOT/} ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
cat "$DMG.sha256"
if (( DRY_RUN )); then
  echo "Dry run: signed with the local identity and not notarized, so other Macs refuse it."
else
  echo "Publish: gh release create v$VERSION ${DMG#$ROOT/} ${DMG#$ROOT/}.sha256 --draft --title \"MacToys $VERSION\" --generate-notes"
fi
