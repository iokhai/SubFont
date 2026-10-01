#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
SUBFONT_BIN_DIR="$(swift build -c release --show-bin-path)"
SUBFONT_APP="$PWD/dist/SubFont.app"
mkdir -p "$SUBFONT_APP/Contents/MacOS" "$SUBFONT_APP/Contents/Resources"
cp "$SUBFONT_BIN_DIR/SubFont" "$SUBFONT_APP/Contents/MacOS/SubFont"
cp Resources/Info.plist "$SUBFONT_APP/Contents/Info.plist"
swift scripts/make-icon.swift "$SUBFONT_APP/Contents/Resources"
codesign --force --sign - "$SUBFONT_APP"
codesign --verify --deep --strict "$SUBFONT_APP"
plutil -lint "$SUBFONT_APP/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$SUBFONT_APP" "$PWD/dist/SubFont.zip"
print "Built $SUBFONT_APP"
