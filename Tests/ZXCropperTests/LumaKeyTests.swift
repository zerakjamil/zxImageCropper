import CoreGraphics
import XCTest
@testable import ZXCropper

final class LumaKeyTests: XCTestCase {
    private func makeImage(size: Int, bgColor: (UInt8, UInt8, UInt8), assetRect: CGRect, assetColor: (UInt8, UInt8, UInt8)) -> CGImage? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(
            red: CGFloat(bgColor.0) / 255,
            green: CGFloat(bgColor.1) / 255,
            blue: CGFloat(bgColor.2) / 255,
            alpha: 1
        )
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(
            red: CGFloat(assetColor.0) / 255,
            green: CGFloat(assetColor.1) / 255,
            blue: CGFloat(assetColor.2) / 255,
            alpha: 1
        )
        ctx.fill(assetRect)
        return ctx.makeImage()
    }

    private func makeImageWithDarkAssetParts(size: Int, bgColor: (UInt8, UInt8, UInt8)) -> CGImage? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Fill black background
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Draw a bright asset square in the center
        ctx.setFillColor(red: 1, green: 0.5, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        // Draw a pure black part INSIDE the asset (e.g. an eye or shadow)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
        return ctx.makeImage()
    }

    private func pixelRGBA(_ image: CGImage, at x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard let provider = image.dataProvider,
              let data = provider.data,
              let ptr = CFDataGetBytePtr(data) else { return (0, 0, 0, 0) }
        let bpr = image.bytesPerRow
        let bpp = max(1, image.bitsPerPixel / 8)
        let off = y * bpr + x * bpp
        return (ptr[off], ptr[off + 1], ptr[off + 2], ptr[off + 3])
    }

    func testPureBlackBackgroundBecomesTransparent() {
        guard let image = makeImage(
            size: 100,
            bgColor: (0, 0, 0),
            assetRect: CGRect(x: 30, y: 30, width: 40, height: 40),
            assetColor: (200, 100, 50)
        ) else { return XCTFail("Failed to build test image") }

        let result = try? ImagePipeline.lumaKey(
            cgImage: image, threshold: 30, softness: 20, feather: 2
        )
        guard let result else { return XCTFail("lumaKey threw") }

        let corner = pixelRGBA(result, at: 2, y: 2)
        XCTAssertEqual(corner.3, 0, "pure black corner should be transparent")
    }

    func testAssetPreservedOpaque() {
        guard let image = makeImage(
            size: 100,
            bgColor: (0, 0, 0),
            assetRect: CGRect(x: 30, y: 30, width: 40, height: 40),
            assetColor: (200, 100, 50)
        ) else { return XCTFail("Failed to build test image") }

        let result = try? ImagePipeline.lumaKey(
            cgImage: image, threshold: 30, softness: 20, feather: 2
        )
        guard let result else { return XCTFail("lumaKey threw") }

        let center = pixelRGBA(result, at: 50, y: 50)
        XCTAssertGreaterThanOrEqual(center.3, 240, "asset center should remain opaque")
    }

    func testDarkAssetPartsPreserved() {
        // Asset has a pure black region INSIDE it (surrounded by bright asset).
        // The flood-fill can't reach it from the border, so it must be preserved.
        guard let image = makeImageWithDarkAssetParts(size: 100, bgColor: (0, 0, 0)) else {
            return XCTFail("Failed to build test image")
        }

        let result = try? ImagePipeline.lumaKey(
            cgImage: image, threshold: 30, softness: 20, feather: 2
        )
        guard let result else { return XCTFail("lumaKey threw") }

        // The black region inside the asset (at 50,50) should be preserved (opaque)
        let darkAssetPixel = pixelRGBA(result, at: 50, y: 50)
        XCTAssertGreaterThan(darkAssetPixel.3, 200, "dark asset part surrounded by bright asset should be preserved")

        // The external black background (at 2,2) should be transparent
        let bgPixel = pixelRGBA(result, at: 2, y: 2)
        XCTAssertEqual(bgPixel.3, 0, "external black bg should be transparent")
    }

    func testMatteBlackBackgroundRemoved() {
        // Matte black (not pure 0,0,0 but very dark like 10,10,10)
        guard let image = makeImage(
            size: 100,
            bgColor: (10, 10, 10),
            assetRect: CGRect(x: 30, y: 30, width: 40, height: 40),
            assetColor: (200, 100, 50)
        ) else { return XCTFail("Failed to build test image") }

        let result = try? ImagePipeline.lumaKey(
            cgImage: image, threshold: 30, softness: 20, feather: 2
        )
        guard let result else { return XCTFail("lumaKey threw") }

        let corner = pixelRGBA(result, at: 2, y: 2)
        XCTAssertEqual(corner.3, 0, "matte black corner should be transparent")
    }

    func testBrightAssetWithDarkEdgesPreserved() {
        // Asset that has dark but not pure-black edges. Threshold should
        // be high enough to remove bg but low enough to preserve asset edges.
        guard let image = makeImage(
            size: 100,
            bgColor: (0, 0, 0),
            assetRect: CGRect(x: 30, y: 30, width: 40, height: 40),
            assetColor: (50, 30, 15)  // dark brown asset
        ) else { return XCTFail("Failed to build test image") }

        let result = try? ImagePipeline.lumaKey(
            cgImage: image, threshold: 20, softness: 15, feather: 2
        )
        guard let result else { return XCTFail("lumaKey threw") }

        let center = pixelRGBA(result, at: 50, y: 50)
        // Dark asset should still be mostly preserved (alpha > 128)
        XCTAssertGreaterThan(center.3, 128, "dark brown asset should be mostly preserved")
    }

    func testDarkSpotDetectionFindsInnerBlackMatte() {
        // Image with black bg, bright asset, and a black circle inside the asset
        guard let image = makeImageWithDarkAssetParts(size: 100, bgColor: (0, 0, 0)) else {
            return XCTFail("Failed to build test image")
        }

        let spots = try? ImagePipeline.detectDarkSpots(
            cgImage: image, threshold: 30, minSize: 16
        )
        guard let spots else { return XCTFail("detectDarkSpots threw") }
        XCTAssertGreaterThanOrEqual(spots.count, 1, "should detect the inner black matte as a spot")
        // The spot should be inside the asset (around x=40..60, y=40..60)
        let spot = spots.first!
        XCTAssertGreaterThan(spot.boundingBox.midX, 35, "spot should be inside asset")
        XCTAssertLessThan(spot.boundingBox.midX, 65, "spot should be inside asset")
    }

    func testDarkSpotDetectionIgnoresTransparentPixels() {
        // After luma keying, transparent pixels have RGB=0,0,0.
        // The detector should NOT detect those as dark spots.
        guard let image = makeImageWithDarkAssetParts(size: 100, bgColor: (0, 0, 0)) else {
            return XCTFail("Failed to build test image")
        }
        // First luma key to make bg transparent
        guard let keyed = try? ImagePipeline.lumaKey(
            cgImage: image, threshold: 30, softness: 20, feather: 2
        ) else { return XCTFail("lumaKey threw") }

        // Now detect dark spots on the keyed result
        let spots = try? ImagePipeline.detectDarkSpots(
            cgImage: keyed, threshold: 30, minSize: 16
        )
        guard let spots else { return XCTFail("detectDarkSpots threw") }
        // Should still find the inner black matte (it's opaque, not transparent)
        XCTAssertGreaterThanOrEqual(spots.count, 1, "should still detect inner black matte after luma key")
        // Should NOT detect the transparent background as spots
        for spot in spots {
            XCTAssertGreaterThan(spot.boundingBox.midX, 20, "spot should be inside asset, not in transparent bg")
            XCTAssertLessThan(spot.boundingBox.midX, 80, "spot should be inside asset, not in transparent bg")
        }
    }
}
