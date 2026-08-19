#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ZXCropper"
APP_BUNDLE="$ROOT_DIR/dist/${APP_NAME}.app"
APP_ICON_PATH="$ROOT_DIR/assets/ZXCropper.icns"

cd "$ROOT_DIR"

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ZXCropper</string>
    <key>CFBundleIdentifier</key>
    <string>com.zxcropper.app</string>
    <key>CFBundleIconFile</key>
    <string>ZXCropper.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ZXCropper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Edit Image</string>
            </dict>
            <key>NSMessage</key>
            <string>editImageService</string>
            <key>NSPortName</key>
            <string>com.zxcropper.app</string>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>org.webmproject.webp</string>
            </array>
            <key>NSUserInterfaceType</key>
            <string>None</string>
            <key>NSRequiredContext</key>
            <dict>
                <key>NSApplicationIdentifier</key>
                <string>com.zxcropper.app</string>
            </dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PNG Image</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.png</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>JPEG Image</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.jpeg</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>WebP Image</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.webmproject.webp</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [[ -f "$APP_ICON_PATH" ]]; then
    cp "$APP_ICON_PATH" "$APP_BUNDLE/Contents/Resources/ZXCropper.icns"
fi

cat > "$APP_BUNDLE/Contents/PkgInfo" <<'PKG'
APPL????
PKG

echo "Built app bundle: $APP_BUNDLE"
