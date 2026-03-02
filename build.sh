#!/bin/bash
set -e
mkdir -p .build
swiftc Sources/main.swift \
  -o .build/ClaudeUsageMeter \
  -framework Cocoa \
  -framework Security \
  -swift-version 6
echo "Built: .build/ClaudeUsageMeter"

# Create .app bundle
APP=".build/ClaudeUsageMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/ClaudeUsageMeter "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.claude.usage-meter</string>
    <key>CFBundleName</key>
    <string>ClaudeUsageMeter</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageMeter</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
PLIST

echo "App bundle: $APP"
echo "Install: cp -R $APP /Applications/"
