#!/bin/zsh
# Creates a self-signed "MacToys Dev" code-signing identity in a dedicated keychain, so
# local builds keep the same designated requirement and macOS privacy grants
# (Accessibility, Screen Recording, …) survive rebuilds. No GUI prompts: the keychain
# has its own password and its key partition list allows codesign.
set -euo pipefail
KC="$HOME/Library/Keychains/mactoys-dev.keychain-db"
PASS="mactoys-dev"
NAME="MacToys Dev"
OPENSSL=/opt/homebrew/bin/openssl
[[ -x $OPENSSL ]] || OPENSSL=/usr/bin/openssl

if [[ -f $KC ]] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  security unlock-keychain -p "$PASS" "$KC"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout $tmp/key.pem -out $tmp/cert.pem \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
$OPENSSL pkcs12 -export -legacy -inkey $tmp/key.pem -in $tmp/cert.pem -name "$NAME" \
  -out $tmp/id.p12 -passout pass:$PASS 2>/dev/null || \
$OPENSSL pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -name "$NAME" -out $tmp/id.p12 -passout pass:$PASS

[[ -f $KC ]] || security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import $tmp/id.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
echo "Created $NAME in $KC"
