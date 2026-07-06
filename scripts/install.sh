#!/bin/bash
# TokenMeter install script

set -e

APP_NAME="TokenMeter"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
INSTALL_DIR="/Applications"
PLIST_NAME="com.user.tokenmeter"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo "=== TokenMeter Install ==="
echo

# 1. Build
echo "Building release..."
swift build -c release
echo "Build complete"
echo

# 2. Create .app bundle
echo "Creating $APP_BUNDLE..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -R Resources/* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$PLIST_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo ".app bundle created"
echo

# 3. Install to /Applications
echo "Installing to $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/$APP_BUNDLE" ]; then
    echo "Replacing existing $INSTALL_DIR/$APP_BUNDLE"
    rm -rf "$INSTALL_DIR/$APP_BUNDLE"
fi
cp -R "$APP_BUNDLE" "$INSTALL_DIR/"
echo "Installed to $INSTALL_DIR/$APP_BUNDLE"
echo

# 4. LaunchAgent (auto-start)
echo "Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/$APP_BUNDLE/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "LaunchAgent installed and loaded"
echo

# 5. Cleanup
rm -rf "$APP_BUNDLE"

echo "=== Install Complete ==="
echo
echo "TokenMeter installed to $INSTALL_DIR/$APP_BUNDLE"
echo "Auto-start enabled via LaunchAgent"
echo
echo "To uninstall:"
echo "  launchctl unload ~/Library/LaunchAgents/$PLIST_NAME.plist"
echo "  rm ~/Library/LaunchAgents/$PLIST_NAME.plist"
echo "  rm -rf $INSTALL_DIR/$APP_BUNDLE"
