#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="${PROJECT_DIR}/Build/Codex Usage.app"

cd "$PROJECT_DIR"
# Swift 6.4's new default build system currently fails to initialize for this
# package on macOS; the native backend remains reliable for this small app.
swift build -c release --build-system native

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/release/CodexUsage" "$APP_DIR/Contents/MacOS/CodexUsage"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR" >/dev/null

print "Built: $APP_DIR"
