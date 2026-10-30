#!/bin/bash
# Builds build/GlassView.app. Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/GlassView.app"
ID="com.glassview.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O Sources/GlassView.swift -o "$APP/Contents/MacOS/GlassView"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GlassView</string>
  <key>CFBundleDisplayName</key><string>GlassView</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>GlassView</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>GlassView shows a see-through copy of an app window.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign with a stable identity so macOS keeps your permissions across rebuilds.
xattr -cr "$APP"
codesign --force --sign - -i "$ID" -r="designated => identifier \"$ID\"" "$APP"

echo "Built $APP"
echo "Run it with:  open $APP"
