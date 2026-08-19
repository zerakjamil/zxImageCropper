# ZXImageCropper (ZXCropper)

Fast, native macOS image editor for PNG, JPEG, and WebP files, launched directly from Finder with a right-click Quick Action named **Edit Image**.

## What This App Solves

ZXImageCropper is designed for speed-first edits when you do not want to open a full design tool.

- Open directly from Finder context menu
- Crop and resize in one compact window
- Preserve safety by auto-creating backups
- Overwrite the original only after successful processing

## Scope

Included:

- Single file selection from Finder
- PNG, JPEG (.jpg / .jpeg), and WebP input/output
- Crop with free mode + aspect presets
- Side and corner handle resizing for precise alignment
- Numeric resize output fields
- Backup + overwrite flow

Excluded:

- RAW formats
- Batch editing
- Metadata editing UI

## Requirements

- macOS 13+
- Xcode Command Line Tools

Install command line tools if needed:

  xcode-select --install

## Quick Start

1. Generate icon assets (optional but recommended):

     ./scripts/generate_icon.sh

2. Build app bundle:

     ./scripts/build_app.sh

3. Install Finder Quick Action:

     ./scripts/install_quick_action.sh

4. Use in Finder:

   - Right-click an image (PNG, JPEG, or WebP)
   - Choose Quick Actions -> Edit Image
   - Crop/resize
   - Press Done

## Finder Workflow

When you run **Edit Image**:

1. App opens in front of other windows.
2. Selected image is loaded from launch argument.
3. You adjust crop and output size.
4. Press Done to save.
5. App creates backup, overwrites original safely, and auto-closes.

## Crop Controls (Precision)

- Drag inside crop box: move crop region
- Drag side handles: adjust one side at a time
- Drag corner handles: adjust two axes at once
- Option + drag outside crop: intentional redraw mode
- Reset Crop button: restore default crop quickly

This interaction model is hardened for unstable mouse press/hold behavior.

## Resize Controls

- Width and Height fields accept numeric values only
- Preview updates off-main-thread for responsiveness
- Large image files remain interactive during preview recompute

## Keyboard Shortcuts

- Cmd + Return: Done
- Esc: Cancel

## Save Safety Policy

On Done:

1. Create sidecar backup first
2. Render final image
3. Write to temp file
4. Replace original file
5. Close editor window

Backup naming:

- `<name>.backup-YYYYMMDD-HHMMSS-SSS.<ext>`
- Collision-safe suffix is added when needed

On Cancel:

- No file changes are made

## Build and Developer Commands

Swift package build:

  swift build

Xcode CLI build:

  xcodebuild -scheme ZXCropper -configuration Release -destination 'platform=macOS' build

Build distributable app:

  ./scripts/build_app.sh

Install/refresh Quick Action:

  ./scripts/install_quick_action.sh

## Project Layout

- Sources/ZXCropper: SwiftUI app source
- scripts/build_app.sh: app bundle build script
- scripts/install_quick_action.sh: Finder Quick Action installer
- scripts/generate_icon.sh: icon generation script
- assets: logo and icon outputs

## Troubleshooting

### Edit Image does not show in Finder

1. Ensure the selected file is PNG.
2. Re-run installer:

     ./scripts/install_quick_action.sh

3. Reopen Finder window.

### App opens but no image loads

- Launch via Finder Quick Action instead of opening app directly.

### Save failed message on a specific PNG

- Retry once (backups are collision-safe).
- Verify file is writable.
- Check disk free space.

### App does not appear on top

- Make sure you are launching from the latest built bundle in dist/ZXCropper.app.
- Re-run build + install scripts.

## Validation Checklist

1. Finder right-click launches editor with selected PNG.
2. Side/corner handles allow accurate crop alignment.
3. Resize fields and preview behave correctly.
4. Done creates backup and overwrites original.
5. Cancel makes zero file changes.
6. Repeated edits do not corrupt output.
