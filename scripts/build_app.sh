#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "=========================================================="
echo "  Building Internet Downloader.app & Chromium Extension   "
echo "=========================================================="

DIST_DIR="$DIR/dist"
APP_NAME="Internet Downloader.app"
APP_DIR="$DIST_DIR/$APP_NAME"

rm -rf "$DIST_DIR"
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
    <string>1.0.0</string>
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

echo "==> 7. Registering Native Messaging Host to point to the built App bundle..."
HOST_NAME="com.internetdownloader.host"
HOST_PATH="$HELPERS_DIR/internet-downloader-host"
MANIFEST_CONTENT=$(cat <<EOF
{
  "name": "$HOST_NAME",
  "description": "Internet Downloader Native Messaging Host for macOS",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://*/"
  ]
}
EOF
)

TARGET_DIRS=(
    "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
    "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
    "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
    "$HOME/Library/Application Support/Arc/User Data/NativeMessagingHosts"
)

for target in "${TARGET_DIRS[@]}"; do
    if mkdir -p "$target" 2>/dev/null; then
        echo "$MANIFEST_CONTENT" > "$target/$HOST_NAME.json"
        echo "  -> Đã cập nhật Native Messaging Host: $target/$HOST_NAME.json"
    fi
done

echo "=========================================================="
echo "  BUILD & PACKAGING THÀNH CÔNG RỰC RỠ!"
echo "  - macOS App: $APP_DIR"
echo "  - Extension folder: $EXT_DIST_DIR"
echo "  - Extension package: $DIST_DIR/Internet-Downloader-Extension.zip"
echo "=========================================================="
