#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/assets"
ICONSET_DIR="$ASSETS_DIR/ZXCropper.iconset"
SOURCE_PNG="$ASSETS_DIR/zxcropper-icon.png"
ICNS_PATH="$ASSETS_DIR/ZXCropper.icns"

if [[ ! -f "$SOURCE_PNG" ]]; then
    echo "Error: Source icon not found at: $SOURCE_PNG" >&2
    exit 1
fi

# Clean up old generated/obsolete icon assets
rm -f "$ASSETS_DIR/ZXCropper-1024.png"
rm -f "$ASSETS_DIR/zximagecropper-logo.svg"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Generate all standard macOS icon resolutions
sips -z 16 16 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

# Compile iconset into .icns bundle
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

echo "Using source icon: $SOURCE_PNG"
echo "Generated macOS icon: $ICNS_PATH"
