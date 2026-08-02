import CoreGraphics
import XCTest
@testable import ZXCropper

/// Tests for the tiered subject-detection pipeline (the "Critical Fix" tiers):
///
/// - Tier 1: Vision attention saliency + Otsu threshold.
/// - Tier 2: CIELAB ΔE border flood-fill, prior-protected (dark clothing against a
///   dark background must NOT be eaten), adaptive T0/T1/T2 expansion for gradients.
/// - Tier 3: morphological closing (arm–torso seams) and edge-anchored recovery.
/// - Fix A: near-full-frame masks are never cutouts (empty contour, nil path set).
/// - Fix C: dynamic RDP epsilon scales with canvas size.
final class TieredDetectionTests: XCTestCase {
    // MARK: - Image helpers

    private func makeOpaque(size: Int) -> CGContext {
        CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private func maskValue(_ mask: CGImage, at x: Int, y: Int) -> UInt8 {
        let data = mask.dataProvider!.data!
        let ptr = CFDataGetBytePtr(data)!
        return ptr[y * mask.bytesPerRow + x]
    }

    /// Grayscale mask, top-left origin bytes, filled rect.
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

    private func makeGrayLuminance(size: Int, blob: CGRect) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * ctx.bytesPerRow)
        memset(ptr, 0, size * ctx.bytesPerRow)
        for y in Int(blob.minY)..<Int(blob.maxY) {
            for x in Int(blob.minX)..<Int(blob.maxX) {
                ptr[y * ctx.bytesPerRow + x] = 255
            }
        }
        return ctx.makeImage()!
    }

    // MARK: - Tier 1: Otsu

    func testOtsuThresholdSplitsBimodalHistogram() {
        // Two sharp peaks at 50 and 150, equal weight. The optimal split must land
        // strictly between them.
        var hist = [Int](repeating: 0, count: 256)
        for i in 51...150 { hist[i] = 1 } // 100 px at every value 51…150
        let t = ImagePipeline.otsuThreshold(histogram: hist, total: 100)
        XCTAssertGreaterThanOrEqual(t, 50)
        XCTAssertLessThan(t, 150, "Otsu must split between the two modes")
    }

    func testOtsuThresholdDegenerateHistogramReturns128() {
        // A single-valued histogram has no separating threshold — 128 is the
        // documented fallback (callers' kept-fraction gates reject the output).
        var single = [Int](repeating: 0, count: 256)
        single[200] = 1000
        XCTAssertEqual(ImagePipeline.otsuThreshold(histogram: single, total: 1000), 128)
        // A flat uniform histogram is NOT degenerate: Otsu splits it at the global
        // mean (127.5), so the first argmax lands on 127.
        let flat = [Int](repeating: 100, count: 256)
        XCTAssertEqual(ImagePipeline.otsuThreshold(histogram: flat, total: 25600), 127)
    }

    // MARK: - Tier 1: saliency → subject mask

    func testSaliencyThresholdsBrightCentralBlob() throws {
        // A bright rectangle on a dark canvas: Otsu keeps the bright pixels (subject)
        // and drops the dark background.
        let size = 64
        let luma = makeGrayLuminance(size: size, blob: CGRect(x: 20, y: 20, width: 24, height: 24))
        let mask = try XCTUnwrap(ImagePipeline.saliencySubjectMask(luminance: luma))

        XCTAssertEqual(maskValue(mask, at: 32, y: 32), 255, "bright blob centre should be subject")
        XCTAssertEqual(maskValue(mask, at: 2, y: 2), 0, "dark corner should be background")
    }

    func testSaliencySubjectMaskNilOnFlatImage() {
        // Uniform luminance has no salient structure — must be nil (no prior), never
        // a full-frame mask.
        let size = 32
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        memset(ctx.data!, 200, size * ctx.bytesPerRow)
        let flat = ctx.makeImage()!
        XCTAssertNil(ImagePipeline.saliencySubjectMask(luminance: flat))
    }

    func testOtsuFirstArgmaxTieBreak() {
        // Two equal modes at 10 and 20: the partition is identical for any threshold
        // 10…19, and the loop only evaluates bins with mass, so the lowest wins.
        var hist = [Int](repeating: 0, count: 256)
        hist[10] = 100
        hist[20] = 100
        let t = ImagePipeline.otsuThreshold(histogram: hist, total: 200)
        XCTAssertEqual(t, 10, "first argmax tie-break keeps the lowest optimal split")
    }

    // MARK: - Tier 2: ΔE tolerance mapping

    func testDeltaEThresholdMapping() {
        // tolerance 60 → 60 × 0.375 = 22.5; floor 4.0 at the low end.
        XCTAssertEqual(ImagePipeline.deltaEThreshold(fromTolerance: 60), 22.5)
        XCTAssertEqual(ImagePipeline.deltaEThreshold(fromTolerance: 200), 75)
        XCTAssertEqual(ImagePipeline.deltaEThreshold(fromTolerance: 10), 4.0, "floor keeps the slider from being a no-op key")
    }

    // MARK: - Tier 2: subject prior protects dark subject against dark background

    func testFloodWithoutPriorEatsDarkSubjectOnDarkBackground() throws {
        // THE critical case: a dark-clothed character on a dark background. ΔE
        // between them is well under the tolerance, so without a prior the flood
        // keys the subject as background and the mask comes back empty.
        let size = 120
        let ctx = makeOpaque(size: size)
        ctx.setFillColor(CGColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)) // near-black bg
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1)) // dark subject
        ctx.fill(CGRect(x: 35, y: 35, width: 50, height: 50))
        let image = ctx.makeImage()!

        // keepLargest is off (as the ladder uses it) so nothing survives by luck.
        let detection = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60, keepLargest: false)
        XCTAssertEqual(maskValue(detection.mask, at: 60, y: 60), 0,
                       "dark subject matching a dark background is eaten without a prior")
    }

    func testFloodWithPriorKeepsDarkSubjectOnDarkBackground() throws {
        // Same image, but a saliency prior protects the subject region: prior pixels
        // are never background, never seeded, never enqueued — so the dark subject
        // survives even though its colour matches the background.
        let size = 120
        let ctx = makeOpaque(size: size)
        ctx.setFillColor(CGColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 35, y: 35, width: 50, height: 50))
        let image = ctx.makeImage()!
        let prior = solidMask(size, rect: CGRect(x: 34, y: 34, width: 52, height: 52))

        let detection = try ImagePipeline.detectForegroundShape(
            cgImage: image, tolerance: 60, keepLargest: false, subjectPrior: prior
        )
        XCTAssertEqual(maskValue(detection.mask, at: 60, y: 60), 255, "prior-protected subject is kept")
        XCTAssertEqual(maskValue(detection.mask, at: 2, y: 2), 0, "background is still keyed")
    }

    func testPriorDecontaminatesBorderPalette() throws {
        // The subject TOUCHES the image border. Without decontamination its dark
        // pixels would enter the border palette and the flood would key everything
        // near it; the prior must exclude those pixels from the palette.
        let size = 100
        let ctx = makeOpaque(size: size)
        ctx.setFillColor(CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)) // near-white bg
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)) // black subject
        ctx.fill(CGRect(x: 40, y: 0, width: 20, height: 100))                  // touches top+bottom
        let image = ctx.makeImage()!
        let prior = solidMask(size, rect: CGRect(x: 40, y: 0, width: 20, height: 100))

        let detection = try ImagePipeline.detectForegroundShape(
            cgImage: image, tolerance: 60, keepLargest: false, subjectPrior: prior
        )
        // The black subject on the white border must be kept, and the white
        // background around it keyed.
        XCTAssertEqual(maskValue(detection.mask, at: 50, y: 50), 255, "border-touching dark subject survives decontamination")
        XCTAssertEqual(maskValue(detection.mask, at: 20, y: 20), 0, "white background is keyed")
    }

    // MARK: - Tier 2: adaptive flood keys gradients / vignettes

    func testFloodKeysRadialGradientBackground() throws {
        // Background is a radial vignette (dark at the edges, lighter in the middle).
        // Border sampling sees only the dark fringe; the flood's T1 expansion must
        // still key the whole gradient rather than leaving a ring of "almost
        // background" around a bright subject.
        let size = 160
        let ctx = makeOpaque(size: size)
        let dark = CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        let lessDark = CGColor(red: 0.22, green: 0.24, blue: 0.30, alpha: 1)
        let grad = CGGradient(colorsSpace: ctx.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                              colors: [dark, lessDark] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 80, y: 80), startRadius: 0,
                               endCenter: CGPoint(x: 80, y: 80), endRadius: 120, options: [])
        ctx.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.35, alpha: 1)) // bright gold subject
        ctx.fill(CGRect(x: 60, y: 60, width: 40, height: 40))
        let image = ctx.makeImage()!

        let detection = try ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60, keepLargest: false)
        // Every corner is background, and the mid-gradient between corner and subject
        // is too.
        for (x, y) in [(5, 5), (155, 5), (5, 155), (155, 155)] {
            XCTAssertEqual(maskValue(detection.mask, at: x, y: y), 0, "vignette corner should be keyed")
        }
        XCTAssertEqual(maskValue(detection.mask, at: 40, y: 40), 0, "mid gradient should be keyed by the expansion")
        XCTAssertEqual(maskValue(detection.mask, at: 80, y: 80), 255, "bright subject should be kept")
    }

    // MARK: - Tier 3: morphology closing

    func testBinaryCloseFillsNarrowInteriorSeam() {
        // Two blocks separated by a 1px gap — the arm–torso seam. Closing at radius 1
        // bridges the gap; the outer silhouette is unchanged.
        let width = 20, height = 20
        var buf = [UInt8](repeating: 0, count: width * height)
        for y in 5..<15 {
            for x in 5..<9 { buf[y * width + x] = 255 }  // left block
            for x in 10..<15 { buf[y * width + x] = 255 } // right block (1px gap at x=9)
        }
        let closed = ImagePipeline.binaryClose(buf, width: width, height: height, radius: 1)
        XCTAssertEqual(closed[10 * width + 9], 255, "the 1px seam must close")
        // Outer silhouette untouched: corners of the union stay background.
        XCTAssertEqual(closed[0], 0)
        XCTAssertEqual(closed[19 * width + 19], 0)
    }

    func testBinaryDilateAndErodeRoundTrip() {
        let width = 16, height = 16
        var buf = [UInt8](repeating: 0, count: width * height)
        for y in 6..<10 {
            for x in 6..<10 { buf[y * width + x] = 255 }
        }
        let dilated = ImagePipeline.binaryDilate(buf, width: width, height: height, radius: 1)
        XCTAssertEqual(dilated[5 * width + 8], 255, "dilation expands one ring")
        let eroded = ImagePipeline.binaryErode(dilated, width: width, height: height, radius: 1)
        XCTAssertEqual(eroded[6 * width + 8], 255, "erosion restores the original core")
        XCTAssertEqual(eroded[5 * width + 8], 0, "the expanded ring is eroded away")
    }

    func testSmallSubjectSurvivesKeepLargest() throws {
        // F7 regression: a 7×7 (49px) subject sits below the 64px dust floor of
        // dropDisconnectedSpecks. Before the fix nothing met minKeep, so the whole
        // mask was wiped and detection degraded to nil; the largest component must
        // survive.
        let size = 40
        let ctx = makeOpaque(size: size)
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 16, y: 16, width: 7, height: 7))
        let image = ctx.makeImage()!

        let detection = try ImagePipeline.detectForegroundShape(
            cgImage: image, tolerance: 60, keepLargest: true
        )
        XCTAssertGreaterThan(detection.pixelCount, 0,
                             "a small subject below the dust floor must survive keep-largest")
    }

    // MARK: - Fix A: uniform gate

    func testIsUsableSubjectMaskGates() {
        let usable = solidMask(40, rect: CGRect(x: 10, y: 10, width: 20, height: 20)) // 25% kept
        XCTAssertTrue(ImagePipeline.isUsableSubjectMask(usable))

        let fullFrame = solidMask(40, rect: CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertFalse(ImagePipeline.isUsableSubjectMask(fullFrame), "near-full frame is rejected")

        let empty = solidMask(40, rect: .zero)
        XCTAssertFalse(ImagePipeline.isUsableSubjectMask(empty), "empty mask is rejected")
    }

    // MARK: - Fix A: subjectMaskAll degradation ladder

    func testSubjectMaskAllNeverReturnsNearFullFrame() {
        // Fix A defense at the ladder level. A flat canvas has no real subject, but
        // the learned tiers may hallucinate a blob; the invariant is that whatever
        // comes out passes the uniform usability gate (fraction in (0.01, 0.99)) —
        // a near-full-frame outline can never leak out.
        let size = 48
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let flat = ctx.makeImage()!

        if let mask = ImagePipeline.subjectMaskAll(cgImage: flat, tolerance: 60) {
            XCTAssertTrue(ImagePipeline.isUsableSubjectMask(mask),
                          "ladder output must never be a near-full-frame mask")
        }
        // nil (the clean degradation) is also acceptable.
    }

    func testSubjectMaskAllDetectsContrastSubject() throws {
        // Bright subject on a dark background: the ladder produces a usable mask and
        // the subject centre is kept.
        let size = 100
        let ctx = makeOpaque(size: size)
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
        let image = ctx.makeImage()!

        let mask = try XCTUnwrap(ImagePipeline.subjectMaskAll(cgImage: image, tolerance: 60))
        XCTAssertEqual(maskValue(mask, at: 50, y: 50), 255)
        XCTAssertEqual(maskValue(mask, at: 2, y: 2), 0)
        XCTAssertTrue(ImagePipeline.isUsableSubjectMask(mask))
    }

    // MARK: - Fix C: dynamic RDP epsilon

    func testSimplifiedPenContourTracksCircleContourOnLargeCanvas() {
        // A large circle at maxPoints 80: with the dynamic epsilon the contour keeps
        // real silhouette detail (well above 4), tracking the circular shape rather
        // than collapsing to a square.
        let size = 400
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * ctx.bytesPerRow)
        memset(ptr, 0, size * ctx.bytesPerRow)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 40, y: 40, width: 320, height: 320))
        let mask = ctx.makeImage()!

        let simplified = ImagePipeline.simplifiedPenContour(from: mask, maxPoints: 80)
        XCTAssertGreaterThanOrEqual(simplified.count, 16, "a large circle keeps real contour detail")
        XCTAssertLessThanOrEqual(simplified.count, 80)
    }

    func testDetectPenPathSetNodesTrackCharacterSilhouette() {
        // Two overlapping blobs form a bean/character-like silhouette with concavity.
        // The pen nodes must hug the boundary (≤ 80) — never a 4-corner box around
        // the canvas.
        let size = 200
        let ctx = makeOpaque(size: size)
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.4, blue: 0.2, alpha: 1)) // character colour
        ctx.fillEllipse(in: CGRect(x: 40, y: 30, width: 80, height: 140))     // torso
        ctx.fillEllipse(in: CGRect(x: 100, y: 70, width: 60, height: 90))     // arm extends right
        let image = ctx.makeImage()!

        let detection = try! ImagePipeline.detectForegroundShape(cgImage: image, tolerance: 60, keepLargest: false)
        let set = ImagePipeline.penPathSet(fromMask: detection.mask)
        guard let set else { return XCTFail("expected a detected path set") }

        let contour = set.combinedOuterPath
        // More than a rectangle's corners, less than the budget.
        XCTAssertGreaterThan(contour.count, 8, "a character silhouette must not collapse to a box")
        XCTAssertLessThanOrEqual(contour.count, 80)
        // Nodes must sit inside the frame and span the actual subject, not the whole
        // canvas.
        let xs = contour.map(\.anchor.x)
        let ys = contour.map(\.anchor.y)
        XCTAssertGreaterThan(xs.min()!, 0.05, "nodes hug the character, not the canvas edge")
        XCTAssertLessThan(xs.max()!, 0.95)
        XCTAssertLessThan(ys.max()!, 0.95)
    }
}
