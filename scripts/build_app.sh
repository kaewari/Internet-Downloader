#!/bin/bash
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "=========================================================="
echo "  Building Internet Downloader.app & Chromium Extension   "
echo "=========================================================="

APP_NAME="Internet Downloader.app"
VERSION_FILE="$DIR/VERSION"
APPVERSION_SWIFT="$DIR/Sources/DownloaderCore/AppVersion.swift"
EXTENSION_MANIFEST="$DIR/Extension/manifest.json"

die() { echo "ERROR: $*" >&2; exit 1; }

# Read `public static let <name> = "<value>"` from AppVersion.swift.
swift_string_literal() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    sed -n -E "s/.*static let ${name}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -n 1
}

json_top_level_string() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$file" "$key" 2>/dev/null || true
}

# --- 0. Version gate: VERSION and AppVersion.swift must agree before building ---
[ -f "$VERSION_FILE" ] || die "Missing repo-root VERSION file (single source of the app version)."
APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$APP_VERSION" ] || die "VERSION is empty; expected a value such as 1.2.0."
case "$APP_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "VERSION '$APP_VERSION' is not MAJOR.MINOR.PATCH." ;;
esac

[ -f "$APPVERSION_SWIFT" ] || die "Missing $APPVERSION_SWIFT (AppVersion is the single source for app/extension versions)."
SWIFT_APP_VERSION="$(swift_string_literal "$APPVERSION_SWIFT" appVersion)"
SWIFT_EXTENSION_VERSION="$(swift_string_literal "$APPVERSION_SWIFT" extensionVersion)"
[ -n "$SWIFT_APP_VERSION" ] || die "Cannot read AppVersion.appVersion from $APPVERSION_SWIFT."
[ -n "$SWIFT_EXTENSION_VERSION" ] || die "Cannot read AppVersion.extensionVersion from $APPVERSION_SWIFT."
[ "$APP_VERSION" = "$SWIFT_APP_VERSION" ] || die "VERSION ($APP_VERSION) != AppVersion.appVersion ($SWIFT_APP_VERSION); update both or run scripts/check_versions.sh."

MANIFEST_VERSION="$(json_top_level_string "$EXTENSION_MANIFEST" version)"
[ -n "$MANIFEST_VERSION" ] || die "Cannot read version from $EXTENSION_MANIFEST."
[ "$MANIFEST_VERSION" = "$SWIFT_EXTENSION_VERSION" ] || die "Extension/manifest.json version ($MANIFEST_VERSION) != AppVersion.extensionVersion ($SWIFT_EXTENSION_VERSION); update both or run scripts/check_versions.sh."

echo "==> Versions: app $APP_VERSION (VERSION = AppVersion.appVersion), extension $MANIFEST_VERSION (manifest = AppVersion.extensionVersion)"

DIST_DIR="${IDM_BUILD_DIR:-$DIR/.runtime/release-staging/$(date +%Y%m%d-%H%M%S)}"
APP_DIR="$DIST_DIR/$APP_NAME"

if [ -e "$DIST_DIR" ]; then echo "Staging already exists: $DIST_DIR"; exit 1; fi
mkdir -p "$DIST_DIR"

echo "==> 1. Compiling Swift products in RELEASE mode..."
swift build -c release --product InternetDownloader
swift build -c release --product internet-downloader-host

# Find compiled binaries
BIN_DIR="$DIR/.build/release"
if [ ! -f "$BIN_DIR/InternetDownloader" ]; then
    BIN_DIR="$DIR/.build/arm64-apple-macosx/release"
fi

if [ ! -f "$BIN_DIR/InternetDownloader" ]; then
    echo "ERROR: Could not locate compiled InternetDownloader binary"
    exit 1
fi

echo "  -> Found binaries in: $BIN_DIR"

echo "==> 2. Creating macOS App Bundle structure..."
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR"
mkdir -p "$HELPERS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BIN_DIR/InternetDownloader" "$MACOS_DIR/InternetDownloader"
cp "$BIN_DIR/internet-downloader-host" "$HELPERS_DIR/internet-downloader-host"
chmod +x "$MACOS_DIR/InternetDownloader"
chmod +x "$HELPERS_DIR/internet-downloader-host"

echo "==> 3. Generating AppIcon.icns..."
ICONSET_DIR="/tmp/InternetDownloader.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

python3 - <<EOF
from PIL import Image, ImageDraw

def render_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = max(1, size // 16)
    # Background rounded rect / circle
    draw.ellipse([margin, margin, size - margin, size - margin], fill=(10, 132, 255, 255))

    c = size // 2
    w = max(1, size // 8)

    # Arrow stem
    draw.rectangle([c - w//2, size // 4, c + w//2, size * 5 // 8], fill=(255, 255, 255, 255))
    # Arrow head
    draw.polygon([
        (size // 4, size * 5 // 8),
        (size * 3 // 4, size * 5 // 8),
        (c, size * 13 // 16)
    ], fill=(255, 255, 255, 255))

    return img

sizes = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for s, name in sizes:
    render_icon(s).save("$ICONSET_DIR/" + name)
EOF

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "==> 4. Generating Info.plist..."
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>InternetDownloader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.hoangson.InternetDownloader</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Internet Downloader</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> 5. Signing macOS App bundle (Ad-hoc codesign)..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> 6. Packaging Chromium Extension..."
EXT_DIST_DIR="$DIST_DIR/Extension"
cp -r "$DIR/Extension" "$EXT_DIST_DIR"

# Package extension zip
cd "$DIST_DIR"
zip -q -r "Internet-Downloader-Extension.zip" "Extension"
cd "$DIR"

echo "==> 7. Verify staged bundle; installation is a separate idle-only step."
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"
STAGED_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$CONTENTS_DIR/Info.plist")"
[ "$STAGED_VERSION" = "$APP_VERSION" ] || { echo "ERROR: staged CFBundleShortVersionString ($STAGED_VERSION) != VERSION ($APP_VERSION)"; exit 1; }
STAGED_EXT_VERSION="$(json_top_level_string "$EXT_DIST_DIR/manifest.json" version)"
[ "$STAGED_EXT_VERSION" = "$MANIFEST_VERSION" ] || { echo "ERROR: staged Extension manifest version ($STAGED_EXT_VERSION) != $MANIFEST_VERSION"; exit 1; }
echo "=========================================================="
echo "  BUILD & PACKAGING THÀNH CÔNG RỰC RỠ!"
echo "  - App version: $APP_VERSION  |  Extension version: $MANIFEST_VERSION"
echo "  - macOS App: $APP_DIR"
echo "  - Extension folder: $EXT_DIST_DIR"
echo "  - Extension package: $DIST_DIR/Internet-Downloader-Extension.zip"
echo "  - Next: quit the app, then python3 scripts/install_release.py --stage \"$DIST_DIR\""
echo "=========================================================="
