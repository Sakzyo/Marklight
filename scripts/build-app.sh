#!/bin/bash
# Builds build/Marklight.app, ad-hoc signed. Apple Silicon needs at least that.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --package-path App -c release --product Marklight
BIN="$(swift build --package-path App -c release --show-bin-path)/Marklight"

APP=build/Marklight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/Marklight"
cp App/Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/web/* "$APP/Contents/Resources/web/"
codesign --force --sign - "$APP"
echo "$APP"
