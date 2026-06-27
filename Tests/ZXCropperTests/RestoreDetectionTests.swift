import CoreGraphics
import XCTest
@testable import ZXCropper

final class RestoreDetectionTests: XCTestCase {
    // MARK: - Helpers

    private func makeImage(_ size: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        draw(ctx)
        return ctx.makeImage()!
    }

    private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let w = image.width, h = image.height
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: h * ctx.bytesPerRow)
        return ptr[y * ctx.bytesPerRow + x * 4 + 3]
    }

    private func solidMask(_ size: Int, rect: CGRect) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * ctx.bytesPerRow)
        memset(ptr, 0, size * ctx.bytesPerRow)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                ptr[y * ctx.bytesPerRow + x] = 255
            }
        }
        return ctx.makeImage()!
    }

    // MARK: - Trim

    func testTrimTransparentCropsToContent() {
        // 20×20 opaque block centred in a 100×100 transparent canvas.
        let image = makeImage(100) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
        }
        let trimmed = ImagePipeline.trimTransparent(cgImage: image)
        XCTAssertEqual(trimmed.width, 20)
        XCTAssertEqual(trimmed.height, 20)
    }

    func testTrimTransparentNoOpWhenFull() {
        let image = makeImage(30) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }
        let trimmed = ImagePipeline.trimTransparent(cgImage: image)
        XCTAssertEqual(trimmed.width, 30)
        XCTAssertEqual(trimmed.height, 30)
    }

    // MARK: - Removed-spot detection + restore

    func testDetectRemovedSpotsFindsEnclosedHole() {
        // Original: solid 60×60 opaque block (covers the hole region).
        let original = makeImage(100) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        }
        // Processed: same block, but with a 12×12 transparent hole punched in the
        // centre — enclosed by opaque pixels, not connected to the border.
        let processed = makeImage(100) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
            ctx.clear(CGRect(x: 44, y: 44, width: 12, height: 12))
        }

        let spots = try! ImagePipeline.detectRemovedSpots(processed: processed, original: original, minSize: 16)
        XCTAssertEqual(spots.count, 1, "one enclosed removed hole expected")
        XCTAssertGreaterThanOrEqual(spots.first?.pixelCount ?? 0, 100)
    }

    func testRestoreFillsHoleFromOriginal() {
        let original = makeImage(100) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        }
        let processed = makeImage(100) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
            ctx.clear(CGRect(x: 44, y: 44, width: 12, height: 12))
        }

        XCTAssertLessThan(alpha(processed, 50, 50), 128, "hole should start transparent")

        let mask = solidMask(100, rect: CGRect(x: 44, y: 44, width: 12, height: 12))
        let restored = try! ImagePipeline.restore(
            base: processed, original: original,
            strokes: [], polygons: [], brushSize: 1, selectionMask: mask
        )
        XCTAssertGreaterThan(alpha(restored, 50, 50), 200, "hole should be opaque after restore")
    }

    // MARK: - Background eraser (spatial luma key)

    func testEraseBackgroundRemovesDarkKeepsBright() {
        // Left half black, right half white, all opaque.
        let image = makeImage(100) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        }
        // Paint the whole image.
        let mask = solidMask(100, rect: CGRect(x: 0, y: 0, width: 100, height: 100))

        let result = try! ImagePipeline.eraseBackground(
            cgImage: image, strokes: [], polygons: [],
            brushSize: 1, feather: 0, threshold: 30, softness: 20, selectionMask: mask
        )
        XCTAssertLessThan(alpha(result, 25, 50), 40, "dark half should be erased")
        XCTAssertGreaterThan(alpha(result, 75, 50), 220, "bright half should be kept")
    }

    // MARK: - Dark spot scope (luma-key preview)

    func testDetectDarkSpotsScope() {
        // Black background (edge-connected) + a white block with an enclosed black
        // hole inside it.
        let image = makeImage(100) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))      // opaque black bg
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 30, y: 30, width: 40, height: 40))      // bright block
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 44, y: 44, width: 12, height: 12))      // enclosed hole
        }

        let enclosed = try! ImagePipeline.detectDarkSpots(cgImage: image, threshold: 30, minSize: 16)
        XCTAssertEqual(enclosed.count, 1, "default detects only the enclosed dark spot")

        let all = try! ImagePipeline.detectDarkSpots(cgImage: image, threshold: 30, minSize: 16, includeBorderConnected: true)
        XCTAssertEqual(all.count, 2, "edge-connected scope also detects the background luma would remove")
    }

    // MARK: - Sprite valley splitting

    func testDetectSpriteBoxesSplitsFusedNeighbours() {
        // Five well-separated squares set the median size, plus a pair only 2px
        // apart that merge then get re-cut at the gutter.
        let size = 200
        let image: CGImage = {
            let ctx = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            // Separated singles (≥20px apart).
            for x in stride(from: 10, through: 130, by: 30) {
                ctx.fill(CGRect(x: x, y: 10, width: 10, height: 10))
            }
            // Fused pair 2px apart on a different row.
            ctx.fill(CGRect(x: 50, y: 120, width: 10, height: 10))
            ctx.fill(CGRect(x: 62, y: 120, width: 10, height: 10))
            return ctx.makeImage()!
        }()

        let boxes = ImagePipeline.detectSpriteBoxes(cgImage: image, minDimension: 6, mergeGap: 4, padding: 0)
        // 5 singles + the fused pair re-split into 2 = 7.
        XCTAssertEqual(boxes.count, 7, "fused neighbours should be split back apart")
    }
}
