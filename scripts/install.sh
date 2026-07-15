#!/bin/bash
# TokenMeter source install script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=app-config.sh
source "$SCRIPT_DIR/app-config.sh"

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
LAUNCH_AGENT_DIR="${LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
PLIST_DST="$LAUNCH_AGENT_DIR/$APP_BUNDLE_ID.plist"
LEGACY_BUNDLE_ID="com.user.tokenmeter"
LEGACY_PLIST_DST="$LAUNCH_AGENT_DIR/$LEGACY_BUNDLE_ID.plist"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
USER_ID="${USER_ID:-$(id -u)}"
PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/token-meter-install.XXXXXX")"

launch_agent_is_disabled() {
    [[ "$DISABLED_SERVICES" == *"\"$1\" => disabled"* \
        || "$DISABLED_SERVICES" == *"\"$1\" => true"* ]]
}

cleanup() {
    rm -rf "$PACKAGE_DIR"
}
trap cleanup EXIT

echo "=== TokenMeter Install ==="
echo

echo "Building native release app..."
bash "$SCRIPT_DIR/package.sh" --arch native --output-dir "$PACKAGE_DIR"
echo

SOURCE_APP="$PACKAGE_DIR/$APP_NAME.app"
DESTINATION_APP="$INSTALL_DIR/$APP_NAME.app"

echo "Installing to $DESTINATION_APP..."
mkdir -p "$INSTALL_DIR"
if [[ -d "$DESTINATION_APP" ]]; then
    echo "Replacing existing $DESTINATION_APP"
    rm -rf "$DESTINATION_APP"
fi
ditto "$SOURCE_APP" "$DESTINATION_APP"
echo "Installed to $DESTINATION_APP"
echo

if [[ "${SKIP_LAUNCH_AGENT:-0}" == "1" ]]; then
    echo "Skipping LaunchAgent setup (SKIP_LAUNCH_AGENT=1)"
else
    echo "Installing LaunchAgent..."
    mkdir -p "$LAUNCH_AGENT_DIR"

    if ! DISABLED_SERVICES="$("$LAUNCHCTL_BIN" print-disabled "gui/$USER_ID" 2>/dev/null)"; then
        echo "Unable to read launchd login-start state; stopping to preserve the existing choice" >&2
        exit 1
    fi

    AUTO_START_DISABLED=0
    if launch_agent_is_disabled "$APP_BUNDLE_ID"; then
        AUTO_START_DISABLED=1
    elif [[ ! -f "$PLIST_DST" ]] && launch_agent_is_disabled "$LEGACY_BUNDLE_ID"; then
        AUTO_START_DISABLED=1
    fi

    # Stop and remove the legacy service so upgrades cannot launch two copies.
    "$LAUNCHCTL_BIN" disable "gui/$USER_ID/$LEGACY_BUNDLE_ID"
    "$LAUNCHCTL_BIN" remove "$LEGACY_BUNDLE_ID" 2>/dev/null || true
    if [[ -f "$LEGACY_PLIST_DST" ]]; then
        "$LAUNCHCTL_BIN" unload "$LEGACY_PLIST_DST" 2>/dev/null || true
        rm -f "$LEGACY_PLIST_DST"
        echo "Removed legacy LaunchAgent $LEGACY_BUNDLE_ID"
    fi

    if [[ "$AUTO_START_DISABLED" != "1" ]]; then
        "$LAUNCHCTL_BIN" remove "$APP_BUNDLE_ID" 2>/dev/null || true
        if [[ -f "$PLIST_DST" ]]; then
            "$LAUNCHCTL_BIN" unload "$PLIST_DST" 2>/dev/null || true
        fi
    fi

    cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$APP_BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DESTINATION_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

    plutil -lint "$PLIST_DST" >/dev/null
    if [[ "$AUTO_START_DISABLED" == "1" ]]; then
        # Keep the app's explicit launchd override and do not unload its current process.
        "$LAUNCHCTL_BIN" disable "gui/$USER_ID/$APP_BUNDLE_ID"
        echo "LaunchAgent updated; preserved disabled login-start setting"
    else
        "$LAUNCHCTL_BIN" enable "gui/$USER_ID/$APP_BUNDLE_ID"
        "$LAUNCHCTL_BIN" load "$PLIST_DST"
        echo "LaunchAgent installed and loaded"
    fi
fi

echo
echo "=== Install Complete ==="
echo "TokenMeter installed to $DESTINATION_APP"
if [[ "${SKIP_LAUNCH_AGENT:-0}" != "1" ]]; then
    if [[ "$AUTO_START_DISABLED" == "1" ]]; then
        echo "Preserved disabled login-start setting for $APP_BUNDLE_ID"
    else
        echo "Auto-start enabled via LaunchAgent $APP_BUNDLE_ID"
    fi
fi
echo
echo "To uninstall:"
echo "  launchctl unload ~/Library/LaunchAgents/$APP_BUNDLE_ID.plist"
echo "  rm ~/Library/LaunchAgents/$APP_BUNDLE_ID.plist"
echo "  rm -rf $DESTINATION_APP"
