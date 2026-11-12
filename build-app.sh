#!/bin/bash
# Buduje CEIDGWydruk.app (wymaga Xcode lub Command Line Tools na macOS).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=CEIDGWydruk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CEIDGWydruk "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CEIDG Wydruk</string>
  <key>CFBundleIdentifier</key><string>local.ceidg.wydruk</string>
  <key>CFBundleExecutable</key><string>CEIDGWydruk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Gotowe: $APP"
