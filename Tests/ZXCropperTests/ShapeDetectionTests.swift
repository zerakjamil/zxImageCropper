import CoreGraphics
import XCTest
@testable import ZXCropper

final class ShapeDetectionTests: XCTestCase {
    /// Bright square subject on a flat dark background.
    private func subjectOnDarkBackground(size: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1)) // dark navy
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1)) // gold
        ctx.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return ctx.makeImage()!
    }

    private func pixelRGBA(_ image: CGImage, at x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let w = image.width, h = image.height
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: h * ctx.bytesPerRow)
        let off = y * ctx.bytesPerRow + x * 4
        return (ptr[off], ptr[off + 1], ptr[off + 2], ptr[off + 3])
    }

    private func maskValue(_ mask: CGImage, at x: Int, y: Int) -> UInt8 {
        let data = mask.dataProvider!.data!
        let ptr = CFDataGetBytePtr(data)!
        return ptr[y * mask.bytesPerRow + x]
    }

    func testDetectsBrightSubjectOnDarkBackground() throws {
        let image = subjectOnDarkBackground(size: 100)
        let detection = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60)

        // Centre of the subject is kept; the corners are dropped.
        XCTAssertEqual(maskValue(detection.mask, at: 50, y: 50), 255, "subject centre should be kept")
        XCTAssertEqual(maskValue(detection.mask, at: 2, y: 2), 0, "background corner should be dropped")
        XCTAssertGreaterThan(detection.pixelCount, 0)

        // Bounding box should roughly match the 50×50 subject region.
        XCTAssertEqual(detection.boundingBox.width, 50, accuracy: 4)
        XCTAssertEqual(detection.boundingBox.height, 50, accuracy: 4)
    }

    func testExtractMakesBackgroundTransparentAndKeepsSubject() throws {
        let image = subjectOnDarkBackground(size: 100)
        let detection = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60)
        let result = try ImagePipeline.applyKeepMask(cgImage: image, keepMask: detection.mask, feather: 0)

        XCTAssertEqual(pixelRGBA(result, at: 2, y: 2).3, 0, "background should become fully transparent")
        XCTAssertGreaterThanOrEqual(pixelRGBA(result, at: 50, y: 50).3, 240, "subject should stay opaque")
    }

    func testFillsHolesEnclosedByTheShape() throws {
        // Gold ring shape with a dark pocket fully enclosed inside it. The pocket is
        // the same colour as the background but is not reachable from the border, so
        // it must be filled (kept) rather than dropped.
        let size = 120
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 30, width: 60, height: 60))           // solid subject
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 52, y: 52, width: 16, height: 16))           // enclosed dark pocket
        let image = ctx.makeImage()!

        let detection = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60)
        XCTAssertEqual(maskValue(detection.mask, at: 60, y: 60), 255, "enclosed pocket should be filled/kept")
        XCTAssertEqual(maskValue(detection.mask, at: 2, y: 2), 0, "external background should be dropped")
    }

    func testKeepLargestDropsStraySpeck() throws {
        // A big subject plus a tiny detached speck. keepLargest should drop the speck.
        let size = 120
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 30, width: 50, height: 50))   // big subject
        ctx.fill(CGRect(x: 100, y: 8, width: 8, height: 8))     // tiny detached speck
        let image = ctx.makeImage()!

        // CoreGraphics fill is bottom-left origin; the mask is read top-left, so the
        // speck's row is flipped: ptr-y = size - 1 - fill-y.
        let speckX = 103
        let speckY = size - 1 - 11

        let kept = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60, keepLargest: true)
        XCTAssertEqual(maskValue(kept.mask, at: speckX, y: speckY), 0, "stray speck should be dropped when keepLargest is on")
        XCTAssertEqual(maskValue(kept.mask, at: 50, y: 50), 255, "main subject should be kept")

        let both = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60, keepLargest: false)
        XCTAssertEqual(maskValue(both.mask, at: speckX, y: speckY), 255, "speck should be kept when keepLargest is off")
    }

    // MARK: - Checkerboard background (baked-in opaque transparency pattern)

    /// Opaque two-tone checkerboard with caller-drawn subject painted on top.
    private func checkerboard(size: Int, cell: Int, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let light = CGColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
        let dark = CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        var cy = 0
        while cy < size {
            var cx = 0
            while cx < size {
                ctx.setFillColor(((cx / cell) + (cy / cell)) % 2 == 0 ? light : dark)
                ctx.fill(CGRect(x: cx, y: cy, width: cell, height: cell))
                cx += cell
            }
            cy += cell
        }
        draw(ctx)
        return ctx.makeImage()!
    }

    func testCheckerboardKeepsSubjectAndLeavesEnclosedCentreTransparent() throws {
        let size = 160, cell = 16
        let blue = CGColor(red: 0.2, green: 0.6, blue: 0.95, alpha: 1)
        let image = checkerboard(size: size, cell: cell) { ctx in
            ctx.setStrokeColor(blue)
            ctx.setLineWidth(CGFloat(cell * 2))
            ctx.strokeEllipse(in: CGRect(x: 30, y: 30, width: 100, height: 100)) // ring
            ctx.setFillColor(blue)
            ctx.fill(CGRect(x: 8, y: 8, width: 6, height: 6))                     // detached speck
        }

        let d = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60, keepLargest: true)

        // Ring left edge sits on the horizontal centre line, so the y-flip is moot.
        XCTAssertEqual(maskValue(d.mask, at: 30, y: size / 2 - 1), 255, "ring should be kept")
        // The win over the flood path: an enclosed checker centre stays transparent
        // instead of being filled as a hole.
        XCTAssertEqual(maskValue(d.mask, at: size / 2, y: size / 2 - 1), 0, "enclosed checker centre stays transparent")
        XCTAssertEqual(maskValue(d.mask, at: 4, y: 4), 0, "plain checker corner is background")
        // Detached speck (ctx bottom-left → mask top-left row flips): dropped.
        XCTAssertEqual(maskValue(d.mask, at: 11, y: size - 1 - 11), 0, "detached speck is dropped")
    }

    // MARK: - Mask refinement

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

    func testMorphMaskExpandsAndShrinks() {
        let mask = solidMask(100, rect: CGRect(x: 40, y: 40, width: 20, height: 20)) // x/y 40..59

        let grown = ImagePipeline.morphMask(mask, radius: 5)!
        XCTAssertEqual(maskValue(grown, at: 37, y: 50), 255, "dilation should reach 3px outside the edge")
        XCTAssertEqual(maskValue(grown, at: 33, y: 50), 0, "dilation should not reach 7px outside the edge")

        let shrunk = ImagePipeline.morphMask(mask, radius: -5)!
        XCTAssertEqual(maskValue(shrunk, at: 41, y: 50), 0, "erosion should clear 1px inside the edge")
        XCTAssertEqual(maskValue(shrunk, at: 50, y: 50), 255, "erosion should keep the core")
    }

    func testPaintShapeMaskAddAndRemove() throws {
        let mask = solidMask(100, rect: CGRect(x: 40, y: 40, width: 20, height: 20))

        // Add a stroke far outside the shape — those pixels should become subject.
        let added = try ImagePipeline.paintShapeMask(
            mask: mask, stroke: [CGPoint(x: 0.1, y: 0.5)],
            brushSize: 14, brushShape: .circle, brushHardness: 1.0, add: true
        )
        XCTAssertEqual(maskValue(added, at: 10, y: 50), 255, "add brush should include the painted area")
        XCTAssertEqual(maskValue(added, at: 50, y: 50), 255, "existing subject should remain")

        // Remove a stroke over the shape centre — those pixels should drop out.
        let removed = try ImagePipeline.paintShapeMask(
            mask: mask, stroke: [CGPoint(x: 0.5, y: 0.5)],
            brushSize: 14, brushShape: .circle, brushHardness: 1.0, add: false
        )
        XCTAssertEqual(maskValue(removed, at: 50, y: 50), 0, "remove brush should exclude the painted area")
    }

    func testMaskBoundingBox() {
        let mask = solidMask(100, rect: CGRect(x: 30, y: 20, width: 40, height: 25))
        let box = ImagePipeline.maskBoundingBox(mask)
        XCTAssertEqual(box.minX, 30, accuracy: 1)
        XCTAssertEqual(box.minY, 20, accuracy: 1)
        XCTAssertEqual(box.width, 40, accuracy: 1)
        XCTAssertEqual(box.height, 25, accuracy: 1)
    }
}
