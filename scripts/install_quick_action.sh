#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APP_PATH="$ROOT_DIR/dist/ZXCropper.app"
APP_PATH="${1:-$DEFAULT_APP_PATH}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found at: $APP_PATH"
    echo "Building app bundle first..."
    "$ROOT_DIR/scripts/build_app.sh"
fi

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
WORKFLOW_DIR="$HOME/Library/Services/Edit Image.workflow"
CONTENTS_DIR="$WORKFLOW_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$WORKFLOW_DIR"
mkdir -p "$RESOURCES_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Edit Image</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en_US</string>
    <key>CFBundleIdentifier</key>
    <string>com.zxcropper.quickaction.edit-image</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Edit Image</string>
            </dict>
            <key>NSMessage</key>
            <string>runWorkflowAsService</string>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>org.webmproject.webp</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cat > "$CONTENTS_DIR/version.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ProductBuildVersion</key>
    <string>1</string>
    <key>ProjectName</key>
    <string>Edit Image</string>
    <key>SourceVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST

cat > "$RESOURCES_DIR/document.wflow" <<'WFLOW'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key>
    <string>346</string>
    <key>AMApplicationVersion</key>
    <string>2.3</string>
    <key>AMDocumentVersion</key>
    <string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Optional</key>
                    <false/>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.path</string>
                    </array>
                </dict>
                <key>AMActionVersion</key>
                <string>2.0.3</string>
                <key>AMApplication</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>AMParameterProperties</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <dict/>
                    <key>CheckedForUserDefaultShell</key>
                    <dict/>
                    <key>inputMethod</key>
                    <dict/>
                    <key>shell</key>
                    <dict/>
                    <key>source</key>
                    <dict/>
                </dict>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.string</string>
                    </array>
                </dict>
                <key>ActionBundlePath</key>
                <string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key>
                <string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <string>#!/bin/zsh
app_path="__APP_PATH__"
input_file=""

while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        input_file="$line"
        break
    fi
done

if [[ -z "$input_file" ]]; then
    exit 0
fi

/usr/bin/open -a "$app_path" --args "$input_file"
/usr/bin/open "$input_file" -a "$app_path" 2>/dev/null || true

/usr/bin/osascript \
    -e 'try' \
    -e 'tell application id "com.zxcropper.app" to activate' \
    -e 'end try' \
    >/dev/null 2>&amp;1 || true</string>
                    <key>CheckedForUserDefaultShell</key>
                    <true/>
                    <key>inputMethod</key>
                    <integer>0</integer>
                    <key>shell</key>
                    <string>/bin/zsh</string>
                    <key>source</key>
                    <string></string>
                </dict>
                <key>BundleIdentifier</key>
                <string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key>
                <string>2.0.3</string>
                <key>CanShowSelectedItemsWhenRun</key>
                <false/>
                <key>CanShowWhenRun</key>
                <true/>
                <key>Category</key>
                <array>
                    <string>AMCategoryUtilities</string>
                </array>
                <key>Class Name</key>
                <string>RunShellScriptAction</string>
                <key>InputUUID</key>
                <string>13A9D788-E2FC-453A-92A2-7E2CC67A9F7A</string>
                <key>OutputUUID</key>
                <string>CC6D82DA-4467-4AF0-9566-91BC4E12FC6C</string>
                <key>UUID</key>
                <string>F06D019B-83AA-46BE-932E-1A95A12DDF3D</string>
                <key>isViewVisible</key>
                <true/>
            </dict>
            <key>isViewVisible</key>
            <true/>
        </dict>
    </array>
    <key>connectors</key>
    <dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>serviceApplicationBundleID</key>
        <string></string>
        <key>serviceInputTypeIdentifier</key>
        <string>com.apple.Automator.fileSystemObject.image</string>
        <key>serviceOutputTypeIdentifier</key>
        <string>com.apple.Automator.nothing</string>
        <key>serviceProcessesInput</key>
        <integer>0</integer>
        <key>workflowTypeIdentifier</key>
        <string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
WFLOW

escaped_path=${APP_PATH//&/\\&}
sed -i '' "s|__APP_PATH__|$escaped_path|g" "$RESOURCES_DIR/document.wflow"

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
plutil -lint "$RESOURCES_DIR/document.wflow" >/dev/null

/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
/usr/bin/killall Finder >/dev/null 2>&1 || true

echo "Installed Finder Quick Action: Edit Image"
echo "Workflow location: $WORKFLOW_DIR"
echo "App path used: $APP_PATH"
