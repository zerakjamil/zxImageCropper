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

    func testSmoothHandlesAreTangentContinuous() {
        let vm = EditorViewModel(imagePath: nil)
        vm.setPenSmooth(true)
        // Four points inscribed on a circle centered at (0.5, 0.5).
        for p in [CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.8, y: 0.5),
                  CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.2, y: 0.5)] {
            vm.addPolygonVertex(PolygonVertex(anchor: p, controlIn: nil, controlOut: nil))
        }
        // Every anchor must have symmetric handles (out = mirror of in) → C1 smooth, no kinks.
        for v in vm.polygonVertices {
            guard let co = v.controlOut, let ci = v.controlIn else {
                return XCTFail("smooth mode should set handles")
            }
            XCTAssertEqual(co.x - v.anchor.x, -(ci.x - v.anchor.x), accuracy: 1e-6)
            XCTAssertEqual(co.y - v.anchor.y, -(ci.y - v.anchor.y), accuracy: 1e-6)
        }
        // Tangent at the top point (0.5,0.2) is horizontal (correct for a circle).
        let top = vm.polygonVertices.first { abs($0.anchor.y - 0.2) < 1e-6 }
        XCTAssertNotNil(top?.controlOut)
        XCTAssertEqual(top!.controlOut!.y, 0.2, accuracy: 1e-6)
    }

    func testCurveSegmentFitsCircularArc() {
        let vm = EditorViewModel(imagePath: nil) // no image -> normalized (square) space
        vm.setPenSmooth(false) // manual arc mode
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.3, y: 0.6), controlIn: nil, controlOut: nil))
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.7, y: 0.6), controlIn: nil, controlOut: nil))
        vm.curveSegment(at: 0, through: CGPoint(x: 0.5, y: 0.5))

        let verts = vm.polygonVertices
        guard let c1 = verts[0].controlOut, let c2 = verts[1].controlIn else {
            return XCTFail("curveSegment should set both handles")
        }
        let a = verts[0].anchor
        let b = verts[1].anchor
        func cubic(_ t: CGFloat) -> CGPoint {
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * mt * a.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * b.x,
                y: mt * mt * mt * a.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * b.y
            )
        }
        // Passes through the drag point.
        let mid = cubic(0.5)
        XCTAssertEqual(mid.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(mid.y, 0.5, accuracy: 0.01)
        // Every sampled point lies on the circle through the 3 points: center (0.5, 0.75), r = 0.25.
        let center = CGPoint(x: 0.5, y: 0.75)
        for t in stride(from: CGFloat(0.1), through: 0.9, by: 0.2) {
            let pt = cubic(t)
            XCTAssertEqual(hypot(pt.x - center.x, pt.y - center.y), 0.25, accuracy: 0.02)
        }
    }

    func testFinalizeCurveSegmentStaysCircularForWideBulge() {
        // Three points on a known circle: center (0.5, 0.5), radius 0.3, at 0°, 30°,
        // and 200° — dragging through 200° forces the "long way round" arc from a to
        // b, a ~330° sweep. A single cubic Bézier badly flattens a bulge this wide;
        // finalizeCurveSegment must split it into multiple pieces to stay circular.
        let center = CGPoint(x: 0.5, y: 0.5)
        let radius: CGFloat = 0.3
        func onCircle(_ degrees: CGFloat) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: center.x + radius * cos(r), y: center.y + radius * sin(r))
        }
        let a = onCircle(0)
        let b = onCircle(30)
        let p = onCircle(200)

        let vm = EditorViewModel(imagePath: nil)
        vm.setPenSmooth(false)
        vm.addPolygonVertex(PolygonVertex(anchor: a, controlIn: nil, controlOut: nil))
        vm.addPolygonVertex(PolygonVertex(anchor: b, controlIn: nil, controlOut: nil))
        vm.finalizeCurveSegment(at: 0, through: p)

        let verts = vm.polygonVertices
        XCTAssertGreaterThan(verts.count, 2, "a ~330° bulge must be split into multiple pieces")

        func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * mt * p0.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * p3.x,
                y: mt * mt * mt * p0.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p3.y
            )
        }

        // Walk every piece (original a -> ... -> original b) and check it hugs the
        // true circle tightly — much tighter than a single-cubic wide-arc fit could.
        for seg in 0..<(verts.count - 1) {
            guard let c1 = verts[seg].controlOut, let c2 = verts[seg + 1].controlIn else {
                return XCTFail("every piece must have both handles set")
            }
            for i in 0...8 {
                let t = CGFloat(i) / 8
                let pt = cubic(verts[seg].anchor, c1, c2, verts[seg + 1].anchor, t)
                XCTAssertEqual(hypot(pt.x - center.x, pt.y - center.y), radius, accuracy: 0.0015)
            }
        }
    }

    func testFinalizeCurveSegmentMatchesLivePreviewForModestBulge() {
        // A modest bulge (<=90°) needs no splitting — finalize must produce the
        // exact same single-piece curve as the live-preview curveSegment, so there's
        // no visible "snap" when the drag ends.
        let vm = EditorViewModel(imagePath: nil)
        vm.setPenSmooth(false)
        // Shallow bulge (~23° sweep, well under the 90° split threshold).
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.3, y: 0.6), controlIn: nil, controlOut: nil))
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.7, y: 0.6), controlIn: nil, controlOut: nil))
        vm.curveSegment(at: 0, through: CGPoint(x: 0.5, y: 0.58))
        let previewHandles = (vm.polygonVertices[0].controlOut, vm.polygonVertices[1].controlIn)

        vm.finalizeCurveSegment(at: 0, through: CGPoint(x: 0.5, y: 0.58))
        XCTAssertEqual(vm.polygonVertices.count, 2, "modest bulge should not insert extra anchors")
        XCTAssertEqual(vm.polygonVertices[0].controlOut!.x, previewHandles.0!.x, accuracy: 1e-9)
        XCTAssertEqual(vm.polygonVertices[0].controlOut!.y, previewHandles.0!.y, accuracy: 1e-9)
        XCTAssertEqual(vm.polygonVertices[1].controlIn!.x, previewHandles.1!.x, accuracy: 1e-9)
        XCTAssertEqual(vm.polygonVertices[1].controlIn!.y, previewHandles.1!.y, accuracy: 1e-9)
    }

    func testInsertVertexPreservesCurveShape() {
        let vm = EditorViewModel(imagePath: nil)
        vm.setPenSmooth(false) // manual arc mode
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.3, y: 0.6), controlIn: nil, controlOut: nil))
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.7, y: 0.6), controlIn: nil, controlOut: nil))
        vm.curveSegment(at: 0, through: CGPoint(x: 0.5, y: 0.5))

        func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x,
                y: mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y
            )
        }
        let o = vm.polygonVertices
        let a = o[0].anchor, b = o[1].anchor
        guard let c1 = o[0].controlOut, let c2 = o[1].controlIn else { return XCTFail("no curve") }

        vm.insertVertexOnSegment(0, at: cubic(a, c1, c2, b, 0.5))
        XCTAssertEqual(vm.polygonVertices.count, 3)

        let v = vm.polygonVertices
        guard let s0c1 = v[0].controlOut, let s0c2 = v[1].controlIn,
              let s1c1 = v[1].controlOut, let s1c2 = v[2].controlIn else { return XCTFail("split lost handles") }
        // The two new segments must reproduce the original curve's two halves.
        for i in 0...4 {
            let t = CGFloat(i) / 4
            let firstHalf = cubic(a, c1, c2, b, t * 0.5)
            let s0 = cubic(v[0].anchor, s0c1, s0c2, v[1].anchor, t)
            XCTAssertEqual(firstHalf.x, s0.x, accuracy: 0.004)
            XCTAssertEqual(firstHalf.y, s0.y, accuracy: 0.004)
            let secondHalf = cubic(a, c1, c2, b, 0.5 + t * 0.5)
            let s1 = cubic(v[1].anchor, s1c1, s1c2, v[2].anchor, t)
            XCTAssertEqual(secondHalf.x, s1.x, accuracy: 0.004)
            XCTAssertEqual(secondHalf.y, s1.y, accuracy: 0.004)
        }
    }

    func testCurveSegmentCollinearStaysStraight() {
        let vm = EditorViewModel(imagePath: nil)
        vm.setPenSmooth(false) // manual arc mode
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.2, y: 0.5), controlIn: nil, controlOut: nil))
        vm.addPolygonVertex(PolygonVertex(anchor: CGPoint(x: 0.8, y: 0.5), controlIn: nil, controlOut: nil))
        vm.curveSegment(at: 0, through: CGPoint(x: 0.5, y: 0.5)) // on the line
        XCTAssertNil(vm.polygonVertices[0].controlOut)
        XCTAssertNil(vm.polygonVertices[1].controlIn)
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