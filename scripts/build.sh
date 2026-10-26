#!/bin/zsh
# Builds the bridge app bundle and the helper tools into ./build
# Usage: scripts/build.sh
set -euo pipefail
ROOT=${0:A:h:h}
BUILD="$ROOT/build"
APP="$BUILD/fifine-bridge.app"

command -v swiftc >/dev/null || { echo "swiftc not found - install the Xcode Command Line Tools: xcode-select --install"; exit 1; }

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$BUILD/tools"
echo "==> building fifine-bridge (direct USB driver + BlackHole output)"
swiftc -O "$ROOT/src/bridge/main.swift" "$ROOT/src/bridge/usbmic.swift" "$ROOT/src/bridge/detector.swift" \
       -o "$APP/Contents/MacOS/fifine-bridge"
cp "$ROOT/src/bridge/Info.plist" "$APP/Contents/Info.plist"
# Ad-hoc signature (no Apple developer account needed). macOS asks for microphone permission
# once per build because the bridge attaches to BlackHole, which can also record.
codesign --force --sign - "$APP"

echo "==> building tools"
swiftc -O "$ROOT/tools/usbreset.swift" -o "$BUILD/tools/usbreset"
swiftc -O "$ROOT/tools/descdump.swift" -o "$BUILD/tools/descdump"

echo "==> done: $APP"
