#!/bin/bash
# Builds the Mac version of Kaleido TV and installs it in /Applications.
# Needs Xcode (free from the Mac App Store). No Apple ID needed: the app is signed to run on this Mac only.
set -euo pipefail
cd "$(dirname "$0")"

# Use the full Xcode even if the command-line tools are the selected developer directory.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "Building Kaleido TV for Mac (about a minute the first time)…"
xcodebuild -project KaleidoTV.xcodeproj -scheme KaleidoTV -destination 'generic/platform=macOS' \
    -configuration Release -derivedDataPath build -quiet build

APP="build/Build/Products/Release/Kaleido TV.app"
if pgrep -xq "Kaleido TV"; then
    echo "Closing the running copy of Kaleido TV…"
    osascript -e 'quit app "Kaleido TV"' || true
    sleep 1
fi
rm -rf "/Applications/Kaleido TV.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Kaleido TV.app"
open "/Applications/Kaleido TV.app"
