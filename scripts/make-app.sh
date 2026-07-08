#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Claude Usage.app"
BIN_NAME="ClaudeUsage"

echo "Building release binary…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"

IDENTITY="Claude Usage Self-Signed"
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "Signing with stable identity '$IDENTITY'…"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "Ad-hoc signing (run ./scripts/create-signing-cert.sh once for a durable Keychain grant)…"
  codesign --force --deep --sign - "$APP"
fi

echo "Done: $APP"
echo "Install with:  cp -R \"$APP\" /Applications/  (then launch it once)"
