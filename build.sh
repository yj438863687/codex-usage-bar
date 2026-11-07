#!/bin/zsh
set -e

DIR="${0:A:h}"
APP="$DIR/dist/Codex 用量条.app"
BIN="$APP/Contents/MacOS/CodexUsageBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

swiftc -O "$DIR/main.swift" -o "$BIN" \
    -framework AppKit -framework SwiftUI

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built: $APP"
