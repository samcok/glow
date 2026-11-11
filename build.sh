#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
# No XCTest/Swift Testing with the Command Line Tools only: ./build.sh --test runs the in-app self-checks instead.
if [ "${1:-}" = "--test" ]; then GLOW_SELFTEST=1 "$(swift build -c release --show-bin-path)/Glow"; exit $?; fi
APP=build/Glow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Glow" "$APP/Contents/MacOS/Glow"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
  <key>CFBundleExecutable</key><string>Glow</string>
  <key>CFBundleIdentifier</key><string>io.github.samcok.glow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>Glow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSLocalNetworkUsageDescription</key><string>Glow controls your lights through the Hue Bridge on your local network.</string>
  <key>NSBonjourServices</key><array><string>_hue._tcp</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# App icon (generated once)
if [ ! -f build/AppIcon.icns ]; then
  swift tools/make-icon.swift build/icon-1024.png
  SET=build/AppIcon.iconset; rm -rf "$SET"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o build/AppIcon.icns
fi
mkdir -p "$APP/Contents/Resources"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Localization/*.lproj "$APP/Contents/Resources/"
xattr -cr "$APP"
# Ad-hoc signing keeps the default cdhash requirement: macOS asks once per update for Keychain access. A Developer ID would remove that prompt.
codesign --force --options runtime --entitlements Glow.entitlements --sign - "$APP"
rm -f build/Glow.zip
ditto -c -k --keepParent "$APP" build/Glow.zip
echo "OK: build/Glow.zip"
if [ "${1:-}" = "--install" ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Glow.app
  cp -R "$APP" ~/Applications/Glow.app
  echo "Installed: ~/Applications/Glow.app"
fi
