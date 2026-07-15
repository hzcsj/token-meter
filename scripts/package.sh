#!/bin/bash
# Build a TokenMeter app bundle and release archive without installing either.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=app-config.sh
source "$SCRIPT_DIR/app-config.sh"

ARCH_MODE="universal"
OUTPUT_DIR="$ROOT_DIR/dist"

usage() {
    cat <<EOF
Usage: bash scripts/package.sh [--arch universal|native|arm64|x86_64] [--output-dir PATH]

Builds $APP_NAME.app and TokenMeter-v$APP_VERSION-macos-<architecture>.zip.
The script never writes to /Applications and never calls launchctl.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            [[ -n "${2:-}" ]] || { echo "Missing value for --arch" >&2; exit 2; }
            ARCH_MODE="$2"
            shift 2
            ;;
        --output-dir)
            [[ -n "${2:-}" ]] || { echo "Missing value for --output-dir" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$ARCH_MODE" in
    universal|native|arm64|x86_64) ;;
    *)
        echo "Unsupported architecture mode: $ARCH_MODE" >&2
        exit 2
        ;;
esac

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/token-meter-package.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

build_binary() {
    local arch="$1"
    local destination="$2"
    local scratch="$WORK_DIR/build-$arch"
    local binary_dir

    echo "Building $APP_NAME for $arch..."
    swift build \
        --package-path "$ROOT_DIR" \
        --configuration release \
        --arch "$arch" \
        --scratch-path "$scratch"
    binary_dir="$(swift build \
        --package-path "$ROOT_DIR" \
        --configuration release \
        --arch "$arch" \
        --scratch-path "$scratch" \
        --show-bin-path)"
    cp "$binary_dir/$APP_NAME" "$destination"
}

TEMP_APP="$WORK_DIR/$APP_NAME.app"
mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources"

case "$ARCH_MODE" in
    universal)
        build_binary arm64 "$WORK_DIR/$APP_NAME-arm64"
        build_binary x86_64 "$WORK_DIR/$APP_NAME-x86_64"
        lipo -create \
            "$WORK_DIR/$APP_NAME-arm64" \
            "$WORK_DIR/$APP_NAME-x86_64" \
            -output "$TEMP_APP/Contents/MacOS/$APP_NAME"
        ASSET_ARCH="universal"
        ;;
    native)
        NATIVE_ARCH="$(uname -m)"
        case "$NATIVE_ARCH" in
            arm64|x86_64) ;;
            *) echo "Unsupported native architecture: $NATIVE_ARCH" >&2; exit 1 ;;
        esac
        build_binary "$NATIVE_ARCH" "$TEMP_APP/Contents/MacOS/$APP_NAME"
        ASSET_ARCH="$NATIVE_ARCH"
        ;;
    arm64|x86_64)
        build_binary "$ARCH_MODE" "$TEMP_APP/Contents/MacOS/$APP_NAME"
        ASSET_ARCH="$ARCH_MODE"
        ;;
esac

chmod +x "$TEMP_APP/Contents/MacOS/$APP_NAME"
cp -R "$ROOT_DIR/Resources/." "$TEMP_APP/Contents/Resources/"

cat > "$TEMP_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$APP_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$APP_MIN_MACOS_VERSION</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

plutil -lint "$TEMP_APP/Contents/Info.plist" >/dev/null
[[ -f "$TEMP_APP/Contents/Resources/AppIcon.icns" ]]
[[ -f "$TEMP_APP/Contents/Resources/AppIcon.png" ]]

BINARY_ARCHS="$(lipo -archs "$TEMP_APP/Contents/MacOS/$APP_NAME")"
if [[ "$ARCH_MODE" == "universal" ]]; then
    [[ " $BINARY_ARCHS " == *" arm64 "* && " $BINARY_ARCHS " == *" x86_64 "* ]] || {
        echo "Universal binary validation failed: $BINARY_ARCHS" >&2
        exit 1
    }
else
    [[ " $BINARY_ARCHS " == *" $ASSET_ARCH "* ]] || {
        echo "Binary architecture validation failed: $BINARY_ARCHS" >&2
        exit 1
    }
fi

APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
ARCHIVE_NAME="$APP_NAME-v$APP_VERSION-macos-$ASSET_ARCH.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

rm -rf "$APP_PATH"
ditto "$TEMP_APP" "$APP_PATH"
rm -f "$ARCHIVE_PATH"
(
    cd "$OUTPUT_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ARCHIVE_NAME"
)

echo
echo "App bundle: $APP_PATH"
echo "Archive: $ARCHIVE_PATH"
echo "Architectures: $BINARY_ARCHS"
echo "Version: $APP_VERSION ($APP_BUILD_VERSION)"
