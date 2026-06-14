#!/usr/bin/env bash
# Compile SessionWidget.swift into a standalone SessionWidget.app bundle.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/SessionWidget.app"
BIN="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$BIN"

swiftc -O "$DIR/SessionWidget.swift" -o "$BIN/SessionWidget" -framework Cocoa

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SessionWidget</string>
  <key>CFBundleDisplayName</key><string>Claude Session</string>
  <key>CFBundleIdentifier</key><string>com.claude-session-widget.app</string>
  <key>CFBundleExecutable</key><string>SessionWidget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS lets it run without quarantine nags.
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built: $APP"
