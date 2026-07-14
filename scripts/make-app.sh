#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Claude Usage.app"
BIN_NAME="ClaudeUsage"
NEW_APP="${APP}.new.$$"
OLD_APP="${APP}.old.$$"

cleanup() {
  rm -rf "$NEW_APP"
  if [[ -d "$OLD_APP" && ! -d "$APP" ]]; then mv "$OLD_APP" "$APP"; fi
}
trap cleanup EXIT

echo "Building release binary…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"

echo "Assembling ${APP}…"
rm -rf "$NEW_APP" "$OLD_APP"
mkdir -p "$NEW_APP/Contents/MacOS"
cp scripts/Info.plist "$NEW_APP/Contents/Info.plist"
cp "$BIN_PATH" "$NEW_APP/Contents/MacOS/$BIN_NAME"

IDENTITY="Claude Usage Self-Signed"
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "Signing with stable identity '$IDENTITY'…"
  codesign --force --deep --sign "$IDENTITY" "$NEW_APP"
else
  echo "Ad-hoc signing (run ./scripts/create-signing-cert.sh once for a durable Keychain grant)…"
  codesign --force --deep --sign - "$NEW_APP"
fi

codesign --verify --deep --strict "$NEW_APP"
if [[ -d "$APP" ]]; then mv "$APP" "$OLD_APP"; fi
mv "$NEW_APP" "$APP"
rm -rf "$OLD_APP"

echo "Done: $APP"
echo "Install with:  cp -R \"$APP\" /Applications/  (then launch it once)"
