#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP="$PWD/dist/Sound Mash Relay.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/SoundMashRelay" "$APP/Contents/MacOS/SoundMashRelay"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '\nApplication: %s\n' "$APP"
