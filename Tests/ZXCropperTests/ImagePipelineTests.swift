import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ZXCropper

final class ImagePipelineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZXCropperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func createSampleImage(width: Int = 100, height: Int = 80) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testMakeBackupURLPreservesExtensions() {
        let jpgURL = URL(fileURLWithPath: "/tmp/sample.jpg")
        let jpegURL = URL(fileURLWithPath: "/tmp/sample.jpeg")
        let pngURL = URL(fileURLWithPath: "/tmp/sample.png")
        let webpURL = URL(fileURLWithPath: "/tmp/sample.webp")

        let backupJpg = ImagePipeline.makeBackupURL(for: jpgURL)
        let backupJpeg = ImagePipeline.makeBackupURL(for: jpegURL)
        let backupPng = ImagePipeline.makeBackupURL(for: pngURL)
        let backupWebp = ImagePipeline.makeBackupURL(for: webpURL)

        XCTAssertEqual(backupJpg.pathExtension, "jpg")
        XCTAssertTrue(backupJpg.lastPathComponent.starts(with: "sample.backup-"))

        XCTAssertEqual(backupJpeg.pathExtension, "jpeg")
        XCTAssertTrue(backupJpeg.lastPathComponent.starts(with: "sample.backup-"))

        XCTAssertEqual(backupPng.pathExtension, "png")
        XCTAssertTrue(backupPng.lastPathComponent.starts(with: "sample.backup-"))

        XCTAssertEqual(backupWebp.pathExtension, "webp")
        XCTAssertTrue(backupWebp.lastPathComponent.starts(with: "sample.backup-"))
    }

    func testLoadAndSaveJPEGImage() throws {
        let image = createSampleImage(width: 120, height: 90)
        let jpgURL = tempDirectory.appendingPathComponent("test-photo.jpg")

        let jpegData = try ImagePipeline.makeJPEGData(from: image, sourceProperties: nil)
        try jpegData.write(to: jpgURL)

        // Test loading JPEG
        let loaded = try ImagePipeline.loadImage(at: jpgURL)
        XCTAssertEqual(loaded.cgImage.width, 120)
        XCTAssertEqual(loaded.cgImage.height, 90)

        // Test save replacing original
        let updatedImage = createSampleImage(width: 60, height: 45)
        let backupURL = try ImagePipeline.saveReplacingOriginal(
            image: updatedImage,
            originalURL: jpgURL,
            sourceProperties: loaded.sourceProperties
        )

        XCTAssertEqual(backupURL.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpgURL.path))

        // Verify overwritten file is valid JPEG and has new dimensions
        let reloaded = try ImagePipeline.loadImage(at: jpgURL)
        XCTAssertEqual(reloaded.cgImage.width, 60)
        XCTAssertEqual(reloaded.cgImage.height, 45)
    }

    func testLoadAndSaveJPEGWithLongExtension() throws {
        let image = createSampleImage(width: 80, height: 60)
        let jpegURL = tempDirectory.appendingPathComponent("test-photo.jpeg")

        let jpegData = try ImagePipeline.makeJPEGData(from: image, sourceProperties: nil)
        try jpegData.write(to: jpegURL)

        let loaded = try ImagePipeline.loadImage(at: jpegURL)
        XCTAssertEqual(loaded.cgImage.width, 80)
        XCTAssertEqual(loaded.cgImage.height, 60)

        let backupURL = try ImagePipeline.saveReplacingOriginal(
            image: image,
            originalURL: jpegURL,
            sourceProperties: loaded.sourceProperties
        )

        XCTAssertEqual(backupURL.pathExtension, "jpeg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testLoadPNGImage() throws {
        let image = createSampleImage(width: 50, height: 50)
        let pngURL = tempDirectory.appendingPathComponent("test-icon.png")

        let pngData = try ImagePipeline.makePNGData(from: image, sourceProperties: nil)
        try pngData.write(to: pngURL)

        let loaded = try ImagePipeline.loadImage(at: pngURL)
        XCTAssertEqual(loaded.cgImage.width, 50)
        XCTAssertEqual(loaded.cgImage.height, 50)
    }

    func testUnsupportedFormatThrowsError() throws {
        let textURL = tempDirectory.appendingPathComponent("document.txt")
        try "Not an image".write(to: textURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ImagePipeline.loadImage(at: textURL)) { error in
            guard let pipelineError = error as? PipelineError else {
                return XCTFail("Expected PipelineError but got \(error)")
            }
            guard case .unsupportedFormat = pipelineError else {
                return XCTFail("Expected unsupportedFormat but got \(pipelineError)")
            }
        }
    }
}
