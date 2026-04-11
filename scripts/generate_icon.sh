#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/assets"
ICONSET_DIR="$ASSETS_DIR/ZXCropper.iconset"
BASE_PNG="$ASSETS_DIR/ZXCropper-1024.png"
ICNS_PATH="$ASSETS_DIR/ZXCropper.icns"

mkdir -p "$ASSETS_DIR"

swift - "$BASE_PNG" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: rect.size)
image.lockFocus()

let bgPath = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 216, yRadius: 216)
let bgGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.14, green: 0.17, blue: 0.21, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.15, alpha: 1)
])!
bgGradient.draw(in: bgPath, angle: 315)

let panelPath = NSBezierPath(roundedRect: NSRect(x: 192, y: 192, width: 640, height: 640), xRadius: 112, yRadius: 112)
NSColor(calibratedWhite: 0.07, alpha: 0.8).setFill()
panelPath.fill()

let accent = NSColor(calibratedRed: 0.22, green: 0.76, blue: 1.0, alpha: 1)
accent.setStroke()

func strokeSegment(_ points: [NSPoint]) {
    let path = NSBezierPath()
    path.lineWidth = 42
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    if let first = points.first {
        path.move(to: first)
        for p in points.dropFirst() {
            path.line(to: p)
        }
    }
    path.stroke()
}

strokeSegment([NSPoint(x: 274, y: 402), NSPoint(x: 274, y: 294), NSPoint(x: 382, y: 294)])
strokeSegment([NSPoint(x: 742, y: 402), NSPoint(x: 742, y: 294), NSPoint(x: 634, y: 294)])
strokeSegment([NSPoint(x: 274, y: 622), NSPoint(x: 274, y: 730), NSPoint(x: 382, y: 730)])
strokeSegment([NSPoint(x: 742, y: 622), NSPoint(x: 742, y: 730), NSPoint(x: 634, y: 730)])

let zPath = NSBezierPath()
zPath.lineWidth = 68
zPath.lineCapStyle = .round
zPath.lineJoinStyle = .round
zPath.move(to: NSPoint(x: 382, y: 362))
zPath.line(to: NSPoint(x: 640, y: 362))
zPath.line(to: NSPoint(x: 430, y: 662))
zPath.line(to: NSPoint(x: 642, y: 662))
NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1).setStroke()
zPath.stroke()

let dotPath = NSBezierPath(ovalIn: NSRect(x: 728, y: 728, width: 40, height: 40))
accent.setFill()
dotPath.fill()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let pngData = rep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
SWIFT

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$BASE_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$BASE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$BASE_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$BASE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$BASE_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$BASE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$BASE_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$BASE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$BASE_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$BASE_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

echo "Generated SVG logo: $ASSETS_DIR/zximagecropper-logo.svg"
echo "Generated base icon PNG: $BASE_PNG"
echo "Generated macOS icon: $ICNS_PATH"
