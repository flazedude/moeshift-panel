#!/bin/bash
# Builds MoEShift.app from app/*.swift using only the Command Line Tools.
#   ./build.sh            -> ./MoEShift.app
#   OUT=/Applications ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT="${OUT:-$PWD}"
APP="$OUT/MoEShift.app"
BIN="$APP/Contents/MacOS/MoEShift"

command -v swiftc >/dev/null || { echo "swiftc not found; install the Xcode Command Line Tools."; exit 1; }

echo "==> compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$BIN" app/main.swift app/Settings.swift

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MoEShift</string>
  <key>CFBundleDisplayName</key><string>MoEShift</string>
  <key>CFBundleIdentifier</key><string>local.moeshift.controlpanel</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>MoEShift</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Icon: derive every size from the single 1024px source, then pack an .icns.
if [ -f docs/icon.png ] && command -v iconutil >/dev/null && command -v sips >/dev/null; then
  echo "==> icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" docs/icon.png --out "$ICONSET/$2.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
    && echo "    icon embedded" || echo "    icon skipped (iconutil failed)"
else
  echo "==> icon skipped (docs/icon.png missing)"
fi

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && echo "==> ad-hoc signed" || echo "==> unsigned (fine for local use)"

echo
echo "Built $APP"
echo "Run:  open \"$APP\""
