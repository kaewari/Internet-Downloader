#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
echo "==> Building internet-downloader-host..."
swift build -c release --product internet-downloader-host

BINARY_PATH="$DIR/.build/release/internet-downloader-host"
if [ ! -f "$BINARY_PATH" ]; then
    BINARY_PATH="$DIR/.build/arm64-apple-macosx/release/internet-downloader-host"
fi

if [ ! -f "$BINARY_PATH" ]; then
    # Fallback to debug build
    swift build --product internet-downloader-host
    BINARY_PATH="$DIR/.build/debug/internet-downloader-host"
fi

chmod +x "$BINARY_PATH"
echo "==> Binary ready at: $BINARY_PATH"

HOST_NAME="com.internetdownloader.host"
MANIFEST_CONTENT=$(cat <<EOF
{
  "name": "$HOST_NAME",
  "description": "Internet Downloader Native Messaging Host for macOS",
  "path": "$BINARY_PATH",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://nljinpcahdihnlhidjdacnhlchlpblnk/"
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
        echo "  -> Đã cài đặt Native Messaging Host vào: $target/$HOST_NAME.json"
    fi
done

echo "==> Cài đặt Native Messaging Host hoàn tất thành công!"
echo "==> Bước tiếp theo: Mở trình duyệt Chrome/Edge/Brave -> chrome://extensions -> Bật Developer mode -> Load unpacked -> Chọn thư mục $DIR/Extension"
