#!/bin/sh
# Build SimControlPanel.app — a minimal swiftc build wrapped in an ad-hoc-signed .app bundle.
# A bundle (not a bare binary) is required so MultipeerConnectivity gets a stable identity for
# the Local Network permission prompt and so the SwiftUI window activates as a normal app.
#
# Usage:  ./tools/SimControlPanel/build.sh   then   open tools/SimControlPanel/SimControlPanel.app
set -e
cd "$(dirname "$0")"

APP="SimControlPanel.app"
BIN="/tmp/SimControlPanel.bin"

echo "[build] swiftc -O SimControlPanel.swift"
# -parse-as-library is required for @main to be the entry point (file is not named main.swift).
# autolink resolves SwiftUI / AppKit / Network / MultipeerConnectivity from the imports.
swiftc -O -parse-as-library -target arm64-apple-macos14.0 SimControlPanel.swift -o "$BIN"

echo "[build] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SimControlPanel"
cp Info.plist "$APP/Contents/Info.plist"
rm -f "$BIN"

echo "[build] ad-hoc codesign"
codesign --force --sign - "$APP"

echo "[build] done → open $(pwd)/$APP"
