#!/bin/bash
# Builds "CeX Bar.app" next to this script. Needs Xcode or the Command Line Tools.
#   VERSION=1.2.0 ./build.sh     set the app version (default 1.0)
#   UNIVERSAL=1 ./build.sh       build for both Apple Silicon and Intel
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools first:  xcode-select --install"
  exit 1
fi

APP="CeX Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

VERSION="${VERSION:-1.0}"
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
for arch in $ARCHS; do
  echo "Compiling ($arch)…"
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos13.0" \
    CeXBar.swift -o "$BUILD/CeXBar-$arch"
done
lipo -create "$BUILD"/CeXBar-* -output "$APP/Contents/MacOS/CeXBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.josh.cexbar</string>
  <key>CFBundleName</key><string>CeX Bar</string>
  <key>CFBundleDisplayName</key><string>CeX Bar</string>
  <key>CFBundleExecutable</key><string>CeXBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(ad-hoc signing skipped)"

echo "Built: $(pwd)/$APP"
echo "Move it to /Applications and open it — it lives in the menu bar (bag icon)."
