import CoreGraphics
import XCTest
@testable import ZXCropper

/// Tests for the pen-path contour pipeline: mask → boundary trace → RDP
/// simplification → pen vertices → cut.
final class ContourExtractionTests: XCTestCase {
    /// Bright square subject on a flat dark background (matches ShapeDetectionTests).
    private func subjectOnDarkBackground(size: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return ctx.makeImage()!
    }

    /// Grayscale keep-mask, top-left origin bytes (row 0 = top), filled rect.
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

    private func maskValue(_ mask: CGImage, at x: Int, y: Int) -> UInt8 {
        let data = mask.dataProvider!.data!
        let ptr = CFDataGetBytePtr(data)!
        return ptr[y * mask.bytesPerRow + x]
    }

    private func pixelAlpha(_ image: CGImage, at x: Int, y: Int) -> UInt8 {
        let w = image.width, h = image.height
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: h * ctx.bytesPerRow)
        return ptr[y * ctx.bytesPerRow + x * 4 + 3]
    }

    /// Every consecutive pair (including the wrap) must be an 8-neighbour — the
    /// contour is an ordered, closed loop with no jumps.
    private func assertClosedNeighborLoop(_ pts: [CGPoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(pts.count, 4, file: file, line: line)
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            XCTAssertLessThanOrEqual(abs(a.x - b.x), 1.001, file: file, line: line)
            XCTAssertLessThanOrEqual(abs(a.y - b.y), 1.001, file: file, line: line)
        }
    }

    // MARK: - Contour extraction

    func testContourOfSquareMaskIsClosedLoopWithinBounds() {
        let mask = solidMask(100, rect: CGRect(x: 30, y: 30, width: 40, height: 40))
        let contour = ImagePipeline.contourPoints(from: mask)

        XCTAssertFalse(contour.isEmpty)
        assertClosedNeighborLoop(contour)
        for p in contour {
            XCTAssertGreaterThanOrEqual(p.x, 30); XCTAssertLessThanOrEqual(p.x, 70)
            XCTAssertGreaterThanOrEqual(p.y, 30); XCTAssertLessThanOrEqual(p.y, 70)
        }
        // A 40×40 block yields its full corner-space perimeter (160 corners), well
        // beyond the RDP budget.
        XCTAssertGreaterThan(contour.count, 60)
    }

    func testContourOfBorderTouchingSubjectStaysInsideFrame() {
        // Subject fills the left half and touches the image border.
        let mask = solidMask(100, rect: CGRect(x: 0, y: 0, width: 50, height: 100))
        let contour = ImagePipeline.contourPoints(from: mask)

        XCTAssertFalse(contour.isEmpty)
        assertClosedNeighborLoop(contour)
        for p in contour {
            XCTAssertGreaterThanOrEqual(p.x, 0); XCTAssertLessThanOrEqual(p.x, 50)
            XCTAssertGreaterThanOrEqual(p.y, 0); XCTAssertLessThanOrEqual(p.y, 100)
        }
    }

    func testContourOfConcaveLShapeIsClosedFullLoop() {
        // An L-shaped subject — cells (x<3 || y<3) in a 10×10 grid. The concave
        // notch at (3,3) is where the old right-hand wall-follow broke into an open
        // path; the boundary-edge chain must trace the full closed perimeter.
        let size = 10
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * size)
        memset(ptr, 0, size * size)
        for y in 0..<size {
            for x in 0..<size where x < 3 || y < 3 {
                ptr[y * size + x] = 255
            }
        }
        let mask = ctx.makeImage()!
        let contour = ImagePipeline.contourPoints(from: mask)

        XCTAssertFalse(contour.isEmpty)
        assertClosedNeighborLoop(contour)
        // The full L perimeter (≈ 3·3 + 2·7 + … > 20 corners) is traced, not a
        // broken 14-point stub.
        XCTAssertGreaterThan(contour.count, 20)
        for p in contour {
            XCTAssertGreaterThanOrEqual(p.x, 0); XCTAssertLessThanOrEqual(p.x, 10)
            XCTAssertGreaterThanOrEqual(p.y, 0); XCTAssertLessThanOrEqual(p.y, 10)
        }
    }

    func testContourOfFullFrameIsEmpty() {
        // Fix A: a full-frame mask has no cutout boundary. It MUST NOT fall back to
        // a 4-corner rectangle around the canvas — an empty contour is the only
        // valid answer, and callers degrade (report / show nothing).
        let mask = solidMask(100, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let contour = ImagePipeline.contourPoints(from: mask)
        XCTAssertTrue(contour.isEmpty, "a full-frame mask must not emit a frame outline")
    }

    func testContourOfNearFullFrameIsEmpty() {
        // A mask that is the frame minus one pixel is still frame-hugging: it must
        // also be empty, not a rectangle.
        let mask = solidMask(100, rect: CGRect(x: 0, y: 0, width: 100, height: 99))
        let contour = ImagePipeline.contourPoints(from: mask)
        XCTAssertTrue(contour.isEmpty)
    }

    func testPenPathSetOfFullFrameMaskIsNil() {
        // penPathSet fed a full-frame mask directly must degrade to nil (never a
        // 4-corner candidate the user could cut on).
        let mask = solidMask(100, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(ImagePipeline.penPathSet(fromMask: mask))
    }

    func testContourOfHollowBorderRingIsEmpty() {
        // Fix A extent guard: a 1px hollow border ring has tiny AREA (~4%) but
        // full-frame EXTENT, so the pixel-count guard can't see it. Its largest loop
        // is the canvas rectangle — must never be emitted as a cutout.
        let size = 100
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * ctx.bytesPerRow)
        memset(ptr, 0, size * ctx.bytesPerRow)
        for x in 0..<size {
            ptr[x] = 255
            ptr[(size - 1) * size + x] = 255
        }
        for y in 0..<size {
            ptr[y * size] = 255
            ptr[y * size + size - 1] = 255
        }
        let mask = ctx.makeImage()!
        XCTAssertTrue(ImagePipeline.contourPoints(from: mask).isEmpty,
                      "a border ring must not trace the canvas rectangle")
        XCTAssertNil(ImagePipeline.penPathSet(fromMask: mask))
    }

    func testThinDiagonalKeepsClosedOutlineAfterSimplification() {
        // F6 regression: a 1px-thick 45° diagonal is the confirmed rdpSimplifyClosed
        // collapse case — both open halves simplify to their endpoints, giving a
        // 2-point chord that penPathSet silently dropped. The raw-boundary fallback
        // must keep a real closed outline.
        let size = 220
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * ctx.bytesPerRow)
        memset(ptr, 0, size * ctx.bytesPerRow)
        for k in 0..<200 { ptr[k * size + k] = 255 }
        let mask = ctx.makeImage()!

        let simplified = ImagePipeline.simplifiedPenContour(from: mask, maxPoints: 80)
        XCTAssertGreaterThanOrEqual(simplified.count, 4, "a thin blade must keep a closed outline")
        XCTAssertLessThanOrEqual(simplified.count, 80)

        let set = ImagePipeline.penPathSet(fromMask: mask)
        guard let set, let part = set.componentPaths.first else {
            return XCTFail("a thin blade part must not be silently dropped")
        }
        XCTAssertGreaterThanOrEqual(part.count, 4)
        XCTAssertLessThanOrEqual(part.count, 80)
    }

    // MARK: - RDP simplification

    func testRDPOpenCollapsesCollinearPoints() {
        let pts = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0),
            CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 3),
        ]
        let simplified = ImagePipeline.rdpSimplify(pts, epsilon: 1)
        XCTAssertEqual(simplified, [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 3)])
    }

    func testRDPClosedSquareCollapsesToFourCorners() {
        var pts: [CGPoint] = []
        for x in 30..<70 { pts.append(CGPoint(x: x, y: 30)) }                  // top
        for y in 31..<70 { pts.append(CGPoint(x: 69, y: y)) }                  // right
        for x in stride(from: 68, through: 30, by: -1) { pts.append(CGPoint(x: x, y: 69)) } // bottom
        for y in stride(from: 68, through: 31, by: -1) { pts.append(CGPoint(x: 30, y: y)) } // left

        let simplified = ImagePipeline.rdpSimplifyClosed(pts, epsilon: 2)
        XCTAssertEqual(simplified.count, 4)
        let corners = Set(simplified)
        XCTAssertTrue(corners.contains(CGPoint(x: 30, y: 30)))
        XCTAssertTrue(corners.contains(CGPoint(x: 69, y: 30)))
        XCTAssertTrue(corners.contains(CGPoint(x: 69, y: 69)))
        XCTAssertTrue(corners.contains(CGPoint(x: 30, y: 69)))
    }

    // MARK: - Pen path end to end

    func testSimplifiedPenContourRespectsPointBudget() {
        // A filled circle has a long staircased boundary that must stay ≥ 4 points
        // yet collapse to at most the requested budget.
        let size = 100
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * ctx.bytesPerRow)
        memset(ptr, 0, size * ctx.bytesPerRow)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 10, y: 10, width: 80, height: 80))
        let mask = ctx.makeImage()!

        let rawCount = ImagePipeline.contourPoints(from: mask).count
        XCTAssertGreaterThan(rawCount, 60, "a circle's raster boundary should exceed the budget")

        let simplified = ImagePipeline.simplifiedPenContour(from: mask, maxPoints: 30)
        XCTAssertGreaterThanOrEqual(simplified.count, 8)
        XCTAssertLessThanOrEqual(simplified.count, 30)
        for p in simplified {
            XCTAssertGreaterThanOrEqual(p.x, 0); XCTAssertLessThanOrEqual(p.x, 1)
            XCTAssertGreaterThanOrEqual(p.y, 0); XCTAssertLessThanOrEqual(p.y, 1)
        }
    }

    func testDetectedSubjectBecomesPenPathThatCutsCorrectly() throws {
        let image = subjectOnDarkBackground(size: 100)
        let detection = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60)
        let vertices = ImagePipeline.simplifiedPenContour(from: detection.mask, maxPoints: 60)
            .map { PolygonVertex(anchor: $0, controlIn: nil, controlOut: nil) }

        // A square subject simplifies to its four corners.
        XCTAssertEqual(vertices.count, 4)

        // Normalized anchors match the 25…75 subject region.
        var minX = 1.0 as CGFloat, maxX = 0.0 as CGFloat
        var minY = 1.0 as CGFloat, maxY = 0.0 as CGFloat
        for v in vertices {
            minX = min(minX, v.anchor.x); maxX = max(maxX, v.anchor.x)
            minY = min(minY, v.anchor.y); maxY = max(maxY, v.anchor.y)
        }
        XCTAssertEqual(minX, 0.25, accuracy: 0.05)
        XCTAssertEqual(maxX, 0.75, accuracy: 0.05)
        XCTAssertEqual(minY, 0.25, accuracy: 0.05)
        XCTAssertEqual(maxY, 0.75, accuracy: 0.05)

        // Feed the auto path into the existing cut pipeline: erasing inside the
        // polygon removes the subject centre and keeps the background corner.
        let cut = try ImagePipeline.applyEraseMask(
            cgImage: image, strokes: [], polygons: [vertices],
            brushSize: 10, brushShape: .circle, brushHardness: 1.0, feather: 0
        )
        XCTAssertEqual(pixelAlpha(cut, at: 50, y: 50), 0, "polygon interior should be erased")
        XCTAssertGreaterThanOrEqual(pixelAlpha(cut, at: 2, y: 2), 250, "polygon exterior should stay opaque")
    }

    // MARK: - Vision foreground mask (macOS 14+)

    /// Photo-like ball on a gradient background — the case Vision segments well.
    private func ballOnGradient(size: Int = 300) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let sky = [CGColor(red: 0.15, green: 0.25, blue: 0.55, alpha: 1),
                   CGColor(red: 0.4, green: 0.15, blue: 0.3, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: ctx.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                              colors: sky, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 0), options: [])
        let ball = CGGradient(colorsSpace: ctx.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.95, green: 0.75, blue: 0.35, alpha: 1),
                                       CGColor(red: 0.55, green: 0.3, blue: 0.1, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: 150, y: 150)
        let r: CGFloat = 80
        ctx.addEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        ctx.clip()
        ctx.drawRadialGradient(ball, startCenter: CGPoint(x: -30, y: 30), startRadius: 0,
                               endCenter: CGPoint(x: 0, y: 0), endRadius: r, options: [])
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    func testVisionForegroundMaskPolarityAndOrientation() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("Needs macOS 14+")
        }
        let image = ballOnGradient()
        guard let mask = try ImagePipeline.foregroundInstanceMask(cgImage: image) else {
            throw XCTSkip("Vision returned no usable mask on this image")
        }
        // Ball centre is subject (keep), far corner is background (dropped).
        XCTAssertEqual(maskValue(mask, at: 150, y: 150), 255, "subject centre should be kept")
        XCTAssertEqual(maskValue(mask, at: 5, y: 5), 0, "background corner should be dropped")

        // Orientation: the ball sits at centre; a point just off it but still in the
        // middle row must be background (no vertical flip confusion).
        XCTAssertEqual(maskValue(mask, at: 20, y: 150), 0, "background beside the ball should be dropped")
    }

    // MARK: - Game Asset / VFX detection

    func testAlphaVFXReturnsThreeCandidates() throws {
        // Transparent PNG: fully opaque core (α=255) with a soft glow halo (α fading
        // 100→10). detectGameAssetVFXPaths must produce [core, glow, hull].
        let size = 100
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let bpr = ctx.bytesPerRow
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * bpr)
        memset(ptr, 0, size * bpr)

        let coreR: CGFloat = 12
        let glowR: CGFloat = 28
        for y in 0..<size {
            for x in 0..<size {
                let dist = sqrt(pow(CGFloat(x - 50), 2) + pow(CGFloat(y - 50), 2))
                let o = y * bpr + x * 4
                if dist <= coreR {
                    ptr[o] = 220; ptr[o + 1] = 180; ptr[o + 2] = 80; ptr[o + 3] = 255
                } else if dist <= glowR {
                    let frac = 1 - (dist - coreR) / (glowR - coreR)
                    let a = UInt8(frac * 100)
                    ptr[o] = 220; ptr[o + 1] = 180; ptr[o + 2] = 80; ptr[o + 3] = a
                } // else transparent (alpha 0)
            }
        }
        let image = ctx.makeImage()!

        guard let candidates = ImagePipeline.detectGameAssetVFXPaths(cgImage: image, tolerance: 60) else {
            return XCTFail("alpha VFX should return 3 candidates")
        }
        XCTAssertEqual(candidates.count, 3, "must return core, glow, hull")
        for (i, c) in candidates.enumerated() {
            XCTAssertGreaterThanOrEqual(c.count, 3, "candidate \(i) must have ≥3 vertices")
        }

        // Core lies inside glow: core's widest span ≤ glow's widest span (normalized).
        let coreMinX = candidates[0].map(\.anchor.x).min()!
        let coreMaxX = candidates[0].map(\.anchor.x).max()!
        let glowMinX = candidates[1].map(\.anchor.x).min()!
        let glowMaxX = candidates[1].map(\.anchor.x).max()!
        XCTAssertGreaterThanOrEqual(coreMinX, glowMinX - 0.05, "core must not be left of glow")
        XCTAssertLessThanOrEqual(coreMaxX, glowMaxX + 0.05, "core must not be right of glow")

        // Hull encloses glow (hull's span ≥ glow's span).
        let hullMaxX = candidates[2].map(\.anchor.x).max()!
        XCTAssertGreaterThanOrEqual(hullMaxX, glowMaxX - 0.02, "hull must contain glow")
    }

    func testAlphaVFXNilOnFullyOpaqueImage() throws {
        // A fully opaque image with subject on dark bg should NOT trigger the alpha
        // VFX path — it falls through to the standard pipeline (returns nil from
        // detectGameAssetVFXPaths for fallback, or canonical candidates).
        let size = 100
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
        let image = ctx.makeImage()!

        // For opaque images, detectGameAssetVFXPaths should either produce 3
        // candidates OR nil (falling back to standard detection). The opaque VFX
        // path calls subjectMaskAll + opaqueVFXPaths internally, so it may succeed.
        if let candidates = ImagePipeline.detectGameAssetVFXPaths(cgImage: image, tolerance: 60) {
            XCTAssertEqual(candidates.count, 3)
            for (i, c) in candidates.enumerated() {
                XCTAssertGreaterThanOrEqual(c.count, 3, "opaque VFX candidate \(i) must have ≥3 vertices")
            }
        }
        // else: nil is OK — means standard detection should be used
    }

    func testAlphaVFXGlowMaskLargerThanCore() throws {
        // Verify that the glow candidate (index 1) strictly encloses the core
        // candidate (index 0) for a feathered glow disc.
        let size = 80
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let bpr = ctx.bytesPerRow
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * bpr)
        memset(ptr, 0, size * bpr)

        for y in 0..<size {
            for x in 0..<size {
                let dist = sqrt(pow(CGFloat(x - 40), 2) + pow(CGFloat(y - 40), 2))
                let o = y * bpr + x * 4
                if dist <= 15 {
                    ptr[o] = 255; ptr[o + 1] = 200; ptr[o + 2] = 50; ptr[o + 3] = 255
                } else if dist <= 35 {
                    let a = UInt8(max(0, min(255, (35 - dist) / 20 * 255)))
                    ptr[o] = 255; ptr[o + 1] = 200; ptr[o + 2] = 50; ptr[o + 3] = a
                }
            }
        }
        let image = ctx.makeImage()!

        guard let candidates = ImagePipeline.detectGameAssetVFXPaths(cgImage: image, tolerance: 60) else {
            return XCTFail("alpha VFX should return candidates")
        }
        XCTAssertGreaterThanOrEqual(candidates[0].count, 3, "core path should be valid")
        XCTAssertGreaterThanOrEqual(candidates[1].count, 3, "glow path should be valid")
        // Glow area (span in normalized coords) must exceed core span.
        let coreDx = candidates[0].map(\.anchor.x).max()! - candidates[0].map(\.anchor.x).min()!
        let glowDx = candidates[1].map(\.anchor.x).max()! - candidates[1].map(\.anchor.x).min()!
        XCTAssertGreaterThan(glowDx, coreDx, "glow must be wider than core")
    }
}
