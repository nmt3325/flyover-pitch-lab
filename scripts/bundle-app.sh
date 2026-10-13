#!/bin/bash
set -euo pipefail

# Compile with the runner's selected Xcode, then package an unsigned app.
# The public GitHub Actions job signs ad-hoc; Apple Developer credentials
# are deliberately not needed.

LABEL="${1:-local}"
mkdir -p dist
swift build -c release --product FlyoverPitchLab
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/FlyoverPitchLab.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/FlyoverPitchLab" "$APP/Contents/MacOS/FlyoverPitchLab"
cp Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/FlyoverPitchLab"
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --verbose "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/FlyoverPitchLab-${LABEL}.zip"
ls -lh "dist/FlyoverPitchLab-${LABEL}.zip"
