import CoreGraphics
import XCTest
@testable import ZXCropper

final class ShellActionRunnerTests: XCTestCase {
    func testBuildCommandQuotesArguments() {
        let command = ShellActionRunner.buildCommand(
            commandName: "rem",
            arguments: ["/tmp/green image's copy.png"]
        )

        XCTAssertEqual(command, "rem '/tmp/green image'\"'\"'s copy.png'")
    }

    func testRemActionProducesSingleImageOutput() {
        XCTAssertTrue(ShellImageAction.rem.expectsSingleImageOutput)
        XCTAssertEqual(ShellImageAction.rem.title, "REM")
        XCTAssertFalse(ShellImageAction.slice.expectsSingleImageOutput)
    }

    func testSliceRowsColumnsFilterToDigits() {
        let viewModel = EditorViewModel(imagePath: nil)

        viewModel.updateSliceRows("a3b")
        viewModel.updateSliceColumns("x5")

        XCTAssertEqual(viewModel.sliceRows, "3")
        XCTAssertEqual(viewModel.sliceColumns, "5")
        XCTAssertEqual(viewModel.resolvedSliceRows, 3)
        XCTAssertEqual(viewModel.resolvedSliceColumns, 5)
    }

    private func makeSpriteSheet(_ rects: [CGRect], size: Int = 100) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: size, height: size)) // transparent
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        for rect in rects {
            context.fill(rect)
        }
        return context.makeImage()
    }

    func testDetectSpriteBoxesFindsSeparateSprites() {
        guard let image = makeSpriteSheet([
            CGRect(x: 10, y: 10, width: 20, height: 20),
            CGRect(x: 70, y: 10, width: 20, height: 20),
            CGRect(x: 40, y: 70, width: 20, height: 20)
        ]) else { return XCTFail("Failed to build sprite sheet") }

        let boxes = ImagePipeline.detectSpriteBoxes(cgImage: image, minDimension: 8, mergeGap: 6, padding: 2)

        XCTAssertEqual(boxes.count, 3, "expected three separate sprites")
        for box in boxes {
            XCTAssertGreaterThanOrEqual(box.width, 20)
            XCTAssertLessThanOrEqual(box.width, 26) // 20 + 2*padding
            XCTAssertGreaterThanOrEqual(box.height, 20)
            XCTAssertLessThanOrEqual(box.height, 26)
        }
        // Boxes must not overlap each other.
        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                XCTAssertFalse(boxes[i].intersects(boxes[j]), "detected boxes overlap")
            }
        }
    }

    func testDetectSpriteBoxesMergesNearbyFragments() {
        // Two squares 4px apart should merge into one sprite (gap < mergeGap).
        guard let image = makeSpriteSheet([
            CGRect(x: 20, y: 40, width: 20, height: 20),
            CGRect(x: 44, y: 40, width: 20, height: 20)
        ]) else { return XCTFail("Failed to build sprite sheet") }

        let boxes = ImagePipeline.detectSpriteBoxes(cgImage: image, minDimension: 8, mergeGap: 8, padding: 0)
        XCTAssertEqual(boxes.count, 1, "nearby fragments should merge")
    }

    func testDetectSpriteBoxesEmptyOnBlankImage() {
        guard let image = makeSpriteSheet([]) else { return XCTFail("Failed to build sprite sheet") }
        XCTAssertTrue(ImagePipeline.detectSpriteBoxes(cgImage: image).isEmpty)
    }

    func testSliceGridProducesRowMajorCellsTilingImage() {
        let width = 10
        let height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            return XCTFail("Failed to build test image")
        }

        let cells = ImagePipeline.sliceGrid(cgImage: image, rows: 2, columns: 4)

        XCTAssertEqual(cells.count, 8) // row-major, 2*4
        // Widths sum to source width per row (no gaps/overlap).
        let firstRowWidth = cells[0..<4].reduce(0) { $0 + $1.width }
        XCTAssertEqual(firstRowWidth, width)
        let firstColumnHeight = cells[0].height + cells[4].height
        XCTAssertEqual(firstColumnHeight, height)
    }
}