import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PipelineError: LocalizedError {
    case fileNotFound
    case permissionDenied
    case unsupportedFormat
    case unableToLoadImage
    case renderFailed
    case imageEncodingFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Image file not found."
        case .permissionDenied:
            return "Permission denied. Grant folder access and try again."
        case .unsupportedFormat:
            return "Supports PNG, JPEG, and WebP files only."
        case .unableToLoadImage:
            return "Unable to load the source image."
        case .renderFailed:
            return "Failed to process the image."
        case .imageEncodingFailed, .pngEncodingFailed:
            return "Failed to encode image output."
        }
    }
}

struct LoadedImage {
    let url: URL
    let cgImage: CGImage
    let sourceProperties: CFDictionary?
}

enum ImagePipeline {
    /// Shared across all pipelines and the ShapeDetector extensions. CIContext is
    /// thread-safe; a fresh one per operation wastes a GPU/Metal stack.
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func loadImage(at url: URL) throws -> LoadedImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PipelineError.fileNotFound
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
        } catch {
            throw PipelineError.permissionDenied
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PipelineError.unableToLoadImage
        }

        guard let typeRef = CGImageSourceGetType(source) else {
            throw PipelineError.unsupportedFormat
        }

        let typeIdentifier = typeRef as String
        let inferredType = UTType(typeIdentifier) ?? UTType(filenameExtension: url.pathExtension.lowercased())
        guard let type = inferredType,
              type.conforms(to: .png) || type.conforms(to: .webP) || type.conforms(to: .jpeg) else {
            throw PipelineError.unsupportedFormat
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PipelineError.unableToLoadImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)

        return LoadedImage(url: url, cgImage: image, sourceProperties: properties)
    }

    /// Fast aspect-preserving downscale so the heavier per-pixel passes (luma key
    /// live preview) stay interactive on large sheets.
    static func downscale(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
        let w = image.width
        let h = image.height
        let scale = min(1, maxEdge / CGFloat(max(w, h, 1)))
        guard scale < 1 else { return image }
        let nw = max(1, Int(CGFloat(w) * scale))
        let nh = max(1, Int(CGFloat(h) * scale))
        guard let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: nw, height: nh,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    static func clampNormalizedRect(_ rect: CGRect) -> CGRect {
        let minDimension: CGFloat = 0.02
        var normalized = rect.standardized

        normalized.origin.x = min(max(0, normalized.origin.x), 1)
        normalized.origin.y = min(max(0, normalized.origin.y), 1)
        normalized.size.width = max(minDimension, min(1, normalized.size.width))
        normalized.size.height = max(minDimension, min(1, normalized.size.height))

        if normalized.maxX > 1 {
            normalized.origin.x = 1 - normalized.width
        }

        if normalized.maxY > 1 {
            normalized.origin.y = 1 - normalized.height
        }

        normalized.origin.x = max(0, normalized.origin.x)
        normalized.origin.y = max(0, normalized.origin.y)

        return normalized
    }

    static func render(
        cgImage: CGImage,
        cropRectNormalized: CGRect,
        outputPixels: CGSize
    ) throws -> CGImage {
        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)

        let normalized = clampNormalizedRect(cropRectNormalized)
        var cropTopLeft = CGRect(
            x: normalized.origin.x * sourceWidth,
            y: normalized.origin.y * sourceHeight,
            width: normalized.width * sourceWidth,
            height: normalized.height * sourceHeight
        ).integral

        cropTopLeft.size.width = max(1, cropTopLeft.size.width)
        cropTopLeft.size.height = max(1, cropTopLeft.size.height)

        let ciCropRect = CGRect(
            x: cropTopLeft.origin.x,
            y: sourceHeight - cropTopLeft.maxY,
            width: cropTopLeft.width,
            height: cropTopLeft.height
        )

        let sourceBounds = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        let safeCropRect = ciCropRect.intersection(sourceBounds).integral

        guard safeCropRect.width >= 1, safeCropRect.height >= 1 else {
            throw PipelineError.renderFailed
        }

        let targetWidth = max(1, Int(outputPixels.width.rounded()))
        let targetHeight = max(1, Int(outputPixels.height.rounded()))
        let scaleX = CGFloat(targetWidth) / safeCropRect.width
        let scaleY = CGFloat(targetHeight) / safeCropRect.height

        // Rebase the crop origin to zero before scaling so the render rect always intersects image extent.
        let rebased = CIImage(cgImage: cgImage)
            .cropped(to: safeCropRect)
            .transformed(
                by: CGAffineTransform(
                    translationX: -safeCropRect.origin.x,
                    y: -safeCropRect.origin.y
                )
            )
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let renderRect = CGRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(targetHeight))

        if let rendered = context.createCGImage(rebased, from: renderRect) {
            return rendered
        }

        if let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
           let rendered = context.createCGImage(rebased, from: renderRect, format: .RGBA8, colorSpace: colorSpace) {
            return rendered
        }

        throw PipelineError.renderFailed
    }

    static func applyEraseMask(
        cgImage: CGImage,
        strokes: [[CGPoint]],
        polygons: [[PolygonVertex]],
        brushSize: CGFloat,
        brushShape: BrushShape = .circle,
        brushHardness: CGFloat = 1.0,
        feather: CGFloat = 0,
        selectionMask: CGImage? = nil
    ) throws -> CGImage {
        guard !strokes.isEmpty || !polygons.isEmpty || selectionMask != nil else {
            return cgImage
        }

        let width = cgImage.width
        let height = cgImage.height

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PipelineError.renderFailed
        }

        // Step 1: rasterize all erase regions into a single grayscale "removal" buffer
        // (white = fully removed). Anti-aliasing is enabled so edges are smooth.
        let removalPtr = try rasterizeRemovalBuffer(
            width: width,
            height: height,
            strokes: strokes,
            polygons: polygons,
            brushSize: brushSize,
            brushShape: brushShape,
            brushHardness: brushHardness,
            feather: feather,
            selectionMask: selectionMask
        )
        defer { removalPtr.deallocate() }

        // Step 2: draw the source image then multiply its alpha by (1 - removal).
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PipelineError.renderFailed
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = ctx.data else { throw PipelineError.renderFailed }
        let ctxBytesPerRow = ctx.bytesPerRow
        let pixelPtr = pixelData.bindMemory(to: UInt8.self, capacity: height * ctxBytesPerRow)

        for y in 0..<height {
            let rowBase = y * ctxBytesPerRow
            let removalRow = y * width
            for x in 0..<width {
                let removal = removalPtr[removalRow + x]
                guard removal > 0 else { continue }

                let off = rowBase + x * 4
                // Premultiplied last: components are already premultiplied by alpha.
                // Scaling all four channels by keep preserves premultiplication.
                let keep = 255 - Int(removal)
                pixelPtr[off]     = UInt8((Int(pixelPtr[off])     * keep) / 255)
                pixelPtr[off + 1] = UInt8((Int(pixelPtr[off + 1]) * keep) / 255)
                pixelPtr[off + 2] = UInt8((Int(pixelPtr[off + 2]) * keep) / 255)
                pixelPtr[off + 3] = UInt8((Int(pixelPtr[off + 3]) * keep) / 255)
            }
        }

        guard let result = ctx.makeImage() else {
            throw PipelineError.renderFailed
        }

        return result
    }

    /// Rasterizes strokes, polygons and a selection mask into a single-channel
    /// removal buffer (0 = keep, 255 = fully remove) with anti-aliasing and an
    /// optional feather blur. Caller owns the returned buffer.
    static func rasterizeRemovalBuffer(
        width: Int,
        height: Int,
        strokes: [[CGPoint]],
        polygons: [[PolygonVertex]],
        brushSize: CGFloat,
        brushShape: BrushShape,
        brushHardness: CGFloat,
        feather: CGFloat,
        selectionMask: CGImage?
    ) throws -> UnsafeMutablePointer<UInt8> {
        guard let grayCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let grayData = grayCtx.data else {
            throw PipelineError.renderFailed
        }

        let grayBytesPerRow = grayCtx.bytesPerRow
        let grayPtr = grayData.bindMemory(to: UInt8.self, capacity: height * grayBytesPerRow)
        memset(grayPtr, 0, height * grayBytesPerRow)

        grayCtx.setShouldAntialias(true)
        grayCtx.setAllowsAntialiasing(true)
        let removalWhite = CGColor(gray: 1.0, alpha: 1.0)
        grayCtx.setFillColor(removalWhite)
        grayCtx.setStrokeColor(removalWhite)

        let halfBrush = brushSize / 2.0
        let hardness = min(max(brushHardness, 0), 1)
        let softBrush = hardness < 0.999

        let lineCap: CGLineCap = brushShape == .square ? .square : .round
        let lineJoin: CGLineJoin = brushShape == .square ? .miter : .round

        for stroke in strokes {
            guard !stroke.isEmpty else { continue }

            if softBrush && brushShape == .circle {
                // Stamp a radial-falloff disc at each sample point.
                for pt in stroke {
                    let px = pt.x * CGFloat(width)
                    let py = (1.0 - pt.y) * CGFloat(height)
                    stampSoftDisc(in: grayCtx, center: CGPoint(x: px, y: py), radius: halfBrush, hardness: hardness)
                }
                continue
            }

            grayCtx.setLineWidth(brushSize)
            grayCtx.setLineCap(lineCap)
            grayCtx.setLineJoin(lineJoin)

            if stroke.count == 1 {
                let pt = stroke[0]
                let px = pt.x * CGFloat(width)
                let py = (1.0 - pt.y) * CGFloat(height)
                let rect = CGRect(
                    x: px - halfBrush,
                    y: py - halfBrush,
                    width: brushSize,
                    height: brushSize
                )
                if brushShape == .square {
                    grayCtx.fill(rect)
                } else {
                    grayCtx.fillEllipse(in: rect)
                }
            } else {
                grayCtx.beginPath()
                let first = stroke[0]
                grayCtx.move(to: CGPoint(
                    x: first.x * CGFloat(width),
                    y: (1.0 - first.y) * CGFloat(height)
                ))
                for point in stroke.dropFirst() {
                    grayCtx.addLine(to: CGPoint(
                        x: point.x * CGFloat(width),
                        y: (1.0 - point.y) * CGFloat(height)
                    ))
                }
                grayCtx.strokePath()
            }
        }

        for polygon in polygons {
            guard polygon.count >= 3 else { continue }

            grayCtx.beginPath()
            grayCtx.move(to: cgPoint(polygon[0].anchor, width: width, height: height))

            for i in 0..<polygon.count {
                let next = (i + 1) % polygon.count
                let start = polygon[i]
                let end = polygon[next]
                let to = cgPoint(end.anchor, width: width, height: height)

                let control1 = start.controlOut.map { cgPoint($0, width: width, height: height) }
                let control2 = end.controlIn.map { cgPoint($0, width: width, height: height) }

                if control1 != nil || control2 != nil {
                    let c1 = control1 ?? cgPoint(start.anchor, width: width, height: height)
                    let c2 = control2 ?? to
                    grayCtx.addCurve(to: to, control1: c1, control2: c2)
                } else {
                    grayCtx.addLine(to: to)
                }
            }

            grayCtx.closePath()
            grayCtx.fillPath()
        }

        guard let removalImage = grayCtx.makeImage() else {
            throw PipelineError.renderFailed
        }

        // Optionally feather (blur) the removal buffer for soft, anti-aliased edges.
        var blurredRemoval = removalImage
        if feather > 0.01 {
            blurredRemoval = blurGrayImage(removalImage, radius: feather) ?? removalImage
        }

        // Merge in the selection mask as a continuous 0..1 removal weight.
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        memset(output, 0, width * height)

        if let removalData = blurredRemoval.dataProvider?.data,
           let removalBytes = CFDataGetBytePtr(removalData) {
            let removalStride = blurredRemoval.bytesPerRow
            for y in 0..<height {
                for x in 0..<width {
                    output[y * width + x] = removalBytes[y * removalStride + x]
                }
            }
        }

        if let mask = selectionMask,
           let maskData = mask.dataProvider?.data,
           let maskPtr = CFDataGetBytePtr(maskData) {
            var working = mask
            if feather > 0.01 {
                working = blurGrayImage(mask, radius: feather) ?? mask
            }
            if let workingData = working.dataProvider?.data,
               let workingPtr = CFDataGetBytePtr(workingData) {
                let maskStride = working.bytesPerRow
                for y in 0..<height {
                    for x in 0..<width {
                        let value = workingPtr[y * maskStride + x]
                        let idx = y * width + x
                        if value > output[idx] {
                            output[idx] = value
                        }
                    }
                }
            } else {
                // Fallback: hard mask using the original pointer.
                let maskStride = mask.bytesPerRow
                for y in 0..<height {
                    for x in 0..<width where maskPtr[y * maskStride + x] > 128 {
                        let idx = y * width + x
                        output[idx] = 255
                    }
                }
            }
        }

        return output
    }

    /// Rasterizes polygon vertices into a grayscale keep mask (255 = keep,
    /// 0 = remove). Used by "Keep Inside" to preserve the polygon interior
    /// and erase everything outside it.
    static func rasterizeKeepMask(
        width: Int,
        height: Int,
        polygons: [[PolygonVertex]],
        feather: CGFloat
    ) throws -> CGImage {
        guard let grayCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let grayData = grayCtx.data else {
            throw PipelineError.renderFailed
        }

        let grayBytesPerRow = grayCtx.bytesPerRow
        let grayPtr = grayData.bindMemory(to: UInt8.self, capacity: height * grayBytesPerRow)
        memset(grayPtr, 0, height * grayBytesPerRow)

        grayCtx.setShouldAntialias(true)
        grayCtx.setAllowsAntialiasing(true)
        let white = CGColor(gray: 1.0, alpha: 1.0)
        grayCtx.setFillColor(white)

        for polygon in polygons {
            guard polygon.count >= 3 else { continue }

            grayCtx.beginPath()
            grayCtx.move(to: cgPoint(polygon[0].anchor, width: width, height: height))

            for i in 0..<polygon.count {
                let next = (i + 1) % polygon.count
                let start = polygon[i]
                let end = polygon[next]
                let to = cgPoint(end.anchor, width: width, height: height)

                let control1 = start.controlOut.map { cgPoint($0, width: width, height: height) }
                let control2 = end.controlIn.map { cgPoint($0, width: width, height: height) }

                if control1 != nil || control2 != nil {
                    let c1 = control1 ?? cgPoint(start.anchor, width: width, height: height)
                    let c2 = control2 ?? to
                    grayCtx.addCurve(to: to, control1: c1, control2: c2)
                } else {
                    grayCtx.addLine(to: to)
                }
            }

            grayCtx.closePath()
            grayCtx.fillPath()
        }

        guard var result = grayCtx.makeImage() else {
            throw PipelineError.renderFailed
        }

        if feather > 0.01 {
            result = blurGrayImage(result, radius: feather) ?? result
        }

        return result
    }

    /// Stamps a soft radial-falloff disc (alpha 1 at center, 0 at edge) blended
    /// additively into the grayscale removal context via a CGGradient.
    private static func stampSoftDisc(in ctx: CGContext, center: CGPoint, radius: CGFloat, hardness: CGFloat) {
        guard radius > 0 else { return }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        // Solid core up to `hardness * radius`, then falloff to the edge.
        let core = min(max(hardness, 0), 0.95)
        let locations: [CGFloat] = [0, core, 1]
        let components: [CGFloat] = [
            1, 1,    // center: white, opaque
            1, 1,    // end of solid core: white, opaque
            1, 0     // edge: white, transparent
        ]
        guard let gradient = CGGradient(
            colorSpace: colorSpace,
            colorComponents: components,
            locations: locations,
            count: locations.count
        ) else { return }

        ctx.saveGState()
        ctx.setBlendMode(.lighten)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
        ctx.restoreGState()
    }

    /// Box-blurs a single-channel gray image by the given pixel radius.
    static func blurGrayImage(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let r = Int(radius.rounded())
        guard r > 0 else { return image }

        let width = image.width
        let height = image.height

        guard let srcData = image.dataProvider?.data,
              let srcPtr = CFDataGetBytePtr(srcData) else { return nil }
        let srcStride = image.bytesPerRow

        // Compact source into a tight buffer.
        var source = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                source[y * width + x] = srcPtr[y * srcStride + x]
            }
        }

        var temp = [UInt8](repeating: 0, count: width * height)
        var dest = [UInt8](repeating: 0, count: width * height)
        let window = r * 2 + 1

        // Horizontal pass.
        source.withUnsafeBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { tmp in
                for y in 0..<height {
                    let rowBase = y * width
                    var sum = 0
                    for k in -r...r {
                        let xx = min(max(k, 0), width - 1)
                        sum += Int(src[rowBase + xx])
                    }
                    for x in 0..<width {
                        tmp[rowBase + x] = UInt8(sum / window)
                        let addX = min(x + r + 1, width - 1)
                        let subX = max(x - r, 0)
                        sum += Int(src[rowBase + addX]) - Int(src[rowBase + subX])
                    }
                }
            }
        }

        // Vertical pass.
        temp.withUnsafeBufferPointer { tmp in
            dest.withUnsafeMutableBufferPointer { dst in
                for x in 0..<width {
                    var sum = 0
                    for k in -r...r {
                        let yy = min(max(k, 0), height - 1)
                        sum += Int(tmp[yy * width + x])
                    }
                    for y in 0..<height {
                        dst[y * width + x] = UInt8(sum / window)
                        let addY = min(y + r + 1, height - 1)
                        let subY = max(y - r, 0)
                        sum += Int(tmp[addY * width + x]) - Int(tmp[subY * width + x])
                    }
                }
            }
        }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let outData = ctx.data else {
            return nil
        }

        let outPtr = outData.bindMemory(to: UInt8.self, capacity: width * height)
        dest.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                outPtr.update(from: base, count: width * height)
            }
        }

        return ctx.makeImage()
    }

    private static func cgPoint(_ norm: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: norm.x * CGFloat(width), y: (1.0 - norm.y) * CGFloat(height))
    }

    /// Slices a CGImage into rows×columns cells in row-major order
    /// (left→right, top→bottom). Cell boundaries are integer pixel positions
    /// computed so cells tile the image with no gaps or overlaps.
    static func sliceGrid(cgImage: CGImage, rows: Int, columns: Int) -> [CGImage] {
        guard rows >= 1, columns >= 1 else { return [] }

        let width = cgImage.width
        let height = cgImage.height

        func xBound(_ c: Int) -> Int {
            min(max(Int((CGFloat(c) * CGFloat(width) / CGFloat(columns)).rounded()), 0), width)
        }
        func yBound(_ r: Int) -> Int {
            min(max(Int((CGFloat(r) * CGFloat(height) / CGFloat(rows)).rounded()), 0), height)
        }

        var cells: [CGImage] = []
        cells.reserveCapacity(rows * columns)

        for r in 0..<rows {
            // CGImage origin is top-left, so row 0 is the top of the image.
            let y0 = yBound(r)
            let y1 = yBound(r + 1)
            let cellHeight = max(1, y1 - y0)

            for c in 0..<columns {
                let x0 = xBound(c)
                let x1 = xBound(c + 1)
                let cellWidth = max(1, x1 - x0)

                let rect = CGRect(x: x0, y: y0, width: cellWidth, height: cellHeight)
                if let cell = cgImage.cropping(to: rect) {
                    cells.append(cell)
                }
            }
        }

        return cells
    }

    /// Exports sprite cells to a `<sourceStem>_sprites` folder next to the
    /// source file, named 1.png … N.png in row-major order. Returns the folder.
    static func exportSprites(
        cgImage: CGImage,
        rows: Int,
        columns: Int,
        sourceURL: URL,
        atlas: Bool = false
    ) throws -> URL {
        guard rows >= 1, columns >= 1 else {
            throw PipelineError.renderFailed
        }

        let cells = sliceGrid(cgImage: cgImage, rows: rows, columns: columns)
        let folderURL = try writeSprites(cells: cells, sourceURL: sourceURL)
        if atlas { _ = try? writeAtlas(cells: cells, into: folderURL) }
        return folderURL
    }

    /// Export tightly-cropped sprites for arbitrary boxes (auto-detected layout).
    static func exportSprites(
        cgImage: CGImage,
        boxes: [CGRect],
        sourceURL: URL,
        atlas: Bool = false
    ) throws -> URL {
        let width = cgImage.width
        let height = cgImage.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let cells: [CGImage] = boxes.compactMap { box in
            let rect = box.integral.intersection(bounds)
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return cgImage.cropping(to: rect)
        }

        let folderURL = try writeSprites(cells: cells, sourceURL: sourceURL)
        if atlas { _ = try? writeAtlas(cells: cells, into: folderURL) }
        return folderURL
    }

    /// Packs the sprite cells into a single `atlas.png` (shelf packer) plus an
    /// `atlas.json` frame map (TexturePacker-style) inside the sprites folder.
    @discardableResult
    private static func writeAtlas(cells: [CGImage], into folderURL: URL) throws -> URL {
        guard !cells.isEmpty else { throw PipelineError.renderFailed }

        let pad = 2
        // Shelf pack: tallest first, wrap at a roughly-square target width.
        let order = cells.indices.sorted { cells[$0].height > cells[$1].height }
        let totalArea = cells.reduce(0) { $0 + ($1.width + pad) * ($1.height + pad) }
        let widest = cells.map { $0.width }.max() ?? 1
        let targetWidth = max(widest + pad * 2, Int(Double(totalArea).squareRoot() * 1.15))

        struct Frame { let index: Int; let x: Int; let y: Int; let w: Int; let h: Int }
        var frames = [Frame]()
        var cursorX = pad, cursorY = pad, shelfHeight = 0, sheetWidth = 0
        for i in order {
            let w = cells[i].width, h = cells[i].height
            if cursorX + w + pad > targetWidth && cursorX > pad {
                cursorY += shelfHeight + pad
                cursorX = pad
                shelfHeight = 0
            }
            frames.append(Frame(index: i, x: cursorX, y: cursorY, w: w, h: h))
            cursorX += w + pad
            shelfHeight = max(shelfHeight, h)
            sheetWidth = max(sheetWidth, cursorX)
        }
        let sheetHeight = cursorY + shelfHeight + pad
        sheetWidth = max(sheetWidth, pad)

        guard sheetWidth > 0, sheetHeight > 0,
              let ctx = CGContext(
                data: nil, width: sheetWidth, height: sheetHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw PipelineError.renderFailed }
        ctx.clear(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

        // JSON frames use a top-left origin; CGContext is bottom-left, so flip y.
        for f in frames {
            let drawRect = CGRect(x: f.x, y: sheetHeight - f.y - f.h, width: f.w, height: f.h)
            ctx.draw(cells[f.index], in: drawRect)
        }
        guard let sheet = ctx.makeImage() else { throw PipelineError.renderFailed }

        let sheetURL = folderURL.appendingPathComponent("atlas.png")
        let sheetData = try makePNGData(from: sheet, sourceProperties: nil)
        try sheetData.write(to: sheetURL, options: .atomic)

        let framesByIndex = frames.sorted { $0.index < $1.index }
        var json = "{\n  \"image\": \"atlas.png\",\n  \"size\": { \"w\": \(sheetWidth), \"h\": \(sheetHeight) },\n  \"frames\": [\n"
        json += framesByIndex.map { f in
            "    { \"name\": \"\(f.index + 1).png\", \"x\": \(f.x), \"y\": \(f.y), \"w\": \(f.w), \"h\": \(f.h) }"
        }.joined(separator: ",\n")
        json += "\n  ]\n}\n"
        let jsonURL = folderURL.appendingPathComponent("atlas.json")
        try json.data(using: .utf8)?.write(to: jsonURL, options: .atomic)

        return sheetURL
    }

    private static func writeSprites(cells: [CGImage], sourceURL: URL) throws -> URL {
        guard !cells.isEmpty else {
            throw PipelineError.renderFailed
        }

        let fm = FileManager.default
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let directory = sourceURL.deletingLastPathComponent()
        let folderURL = directory.appendingPathComponent("\(stem)_sprites", isDirectory: true)

        if fm.fileExists(atPath: folderURL.path) {
            // Clear prior numbered PNG outputs (mirrors how `slice` clears outputs).
            if let contents = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) {
                for url in contents where url.pathExtension.lowercased() == "png" {
                    if Int(url.deletingPathExtension().lastPathComponent) != nil {
                        try? fm.removeItem(at: url)
                    }
                }
            }
        } else {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        for (index, cell) in cells.enumerated() {
            let data = try makePNGData(from: cell, sourceProperties: nil)
            let fileURL = folderURL.appendingPathComponent("\(index + 1).png")
            try data.write(to: fileURL, options: .atomic)
        }

        return folderURL
    }

    /// Auto-detect individual sprites in a sheet by their content edges.
    ///
    /// Builds a foreground mask (transparency if the sheet has alpha, otherwise a
    /// flat background-colour key from the corners), labels 8-connected components,
    /// drops noise, merges fragments separated by small gaps, and returns padded,
    /// row-major-ordered bounding boxes in CGImage pixel space (top-left origin).
    static func detectSpriteBoxes(
        cgImage: CGImage,
        minAreaFraction: CGFloat = 0.0004,
        minDimension: Int = 10,
        mergeGap: Int = 2,
        padding: Int = 2
    ) -> [CGRect] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 1, height > 1 else { return [] }

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return [] }
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)

        let alphaThreshold: UInt8 = 16
        let colorTolerance = 48.0

        // Decide whether the sheet uses real transparency.
        var transparent = 0
        var sampled = 0
        let stepY = max(1, height / 256)
        let stepX = max(1, width / 256)
        var sy = 0
        while sy < height {
            var sx = 0
            while sx < width {
                if ptr[sy * bpr + sx * 4 + 3] < 200 { transparent += 1 }
                sampled += 1
                sx += stepX
            }
            sy += stepY
        }
        let useAlpha = sampled > 0 && Double(transparent) / Double(sampled) > 0.05

        // Background colour for opaque sheets = median-ish of the four corners.
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * bpr + x * 4
            return (Int(ptr[o]), Int(ptr[o + 1]), Int(ptr[o + 2]))
        }
        let corners = [rgb(1, 1), rgb(width - 2, 1), rgb(1, height - 2), rgb(width - 2, height - 2)]
        let bgR = corners.map { $0.0 }.sorted()[2]
        let bgG = corners.map { $0.1 }.sorted()[2]
        let bgB = corners.map { $0.2 }.sorted()[2]

        // Foreground mask.
        var fg = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let rowBase = y * bpr
            let maskBase = y * width
            for x in 0..<width {
                let o = rowBase + x * 4
                let a = ptr[o + 3]
                if useAlpha {
                    fg[maskBase + x] = a > alphaThreshold
                } else {
                    guard a > alphaThreshold else { continue }
                    let dr = Int(ptr[o]) - bgR
                    let dg = Int(ptr[o + 1]) - bgG
                    let db = Int(ptr[o + 2]) - bgB
                    let dist = (2 * dr * dr + 4 * dg * dg + 3 * db * db)
                    fg[maskBase + x] = Double(dist).squareRoot() > colorTolerance
                }
            }
        }

        // 8-connected component labelling via iterative BFS.
        var visited = [Bool](repeating: false, count: width * height)
        var boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
        var queue = [Int]()
        queue.reserveCapacity(4096)
        let total = width * height
        let minArea = max(4, Int(minAreaFraction * CGFloat(total)))

        for start in 0..<total {
            if !fg[start] || visited[start] { continue }
            visited[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            var minX = width, minY = height, maxX = 0, maxY = 0, area = 0
            while head < queue.count {
                let idx = queue[head]
                head += 1
                let cx = idx % width
                let cy = idx / width
                area += 1
                if cx < minX { minX = cx }
                if cx > maxX { maxX = cx }
                if cy < minY { minY = cy }
                if cy > maxY { maxY = cy }
                for dy in -1...1 {
                    let ny = cy + dy
                    if ny < 0 || ny >= height { continue }
                    let nRow = ny * width
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = cx + dx
                        if nx < 0 || nx >= width { continue }
                        let nIdx = nRow + nx
                        if fg[nIdx] && !visited[nIdx] {
                            visited[nIdx] = true
                            queue.append(nIdx)
                        }
                    }
                }
            }
            let w = maxX - minX + 1
            let h = maxY - minY + 1
            if area >= minArea && w >= minDimension && h >= minDimension {
                boxes.append((minX, minY, maxX, maxY))
            }
        }

        // Merge boxes whose padded extents touch (bridges anti-aliasing gaps and
        // fragmented sprites).
        var didMerge = true
        while didMerge {
            didMerge = false
            var out: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
            var used = [Bool](repeating: false, count: boxes.count)
            for i in 0..<boxes.count {
                if used[i] { continue }
                var a = boxes[i]
                used[i] = true
                for j in (i + 1)..<boxes.count where !used[j] {
                    let b = boxes[j]
                    if a.minX - mergeGap <= b.maxX && b.minX <= a.maxX + mergeGap
                        && a.minY - mergeGap <= b.maxY && b.minY <= a.maxY + mergeGap {
                        a = (min(a.minX, b.minX), min(a.minY, b.minY), max(a.maxX, b.maxX), max(a.maxY, b.maxY))
                        used[j] = true
                        didMerge = true
                    }
                }
                out.append(a)
            }
            boxes = out
        }

        // Split boxes that proximity-merging fused together: a box that is much
        // larger than the median along an axis AND has a fully-empty interior
        // gutter (no foreground) is really two adjacent sprites. Re-cut it at the
        // gutter. This recovers neighbours separated by small gaps without
        // un-merging genuine single-sprite fragments (which have no empty gutter).
        boxes = splitFusedBoxes(boxes, fg: fg, width: width, height: height, minDimension: minDimension)

        var rects = boxes.map { b -> CGRect in
            let x0 = max(0, b.minX - padding)
            let y0 = max(0, b.minY - padding)
            let x1 = min(width, b.maxX + 1 + padding)
            let y1 = min(height, b.maxY + 1 + padding)
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        // Row-major ordering (group into rows by vertical band, then left-to-right).
        if !rects.isEmpty {
            let heights = rects.map { $0.height }.sorted()
            let medianH = heights[heights.count / 2]
            let band = max(1, medianH * 0.7)
            rects.sort { lhs, rhs in
                let lr = Int(lhs.midY / band)
                let rr = Int(rhs.midY / band)
                if lr != rr { return lr < rr }
                return lhs.minX < rhs.minX
            }
        }

        return rects
    }

    /// Re-cuts proximity-merged boxes at fully-empty interior gutters when they
    /// are abnormally large relative to the median box. Operates in pixel space.
    private static func splitFusedBoxes(
        _ boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)],
        fg: [Bool],
        width: Int,
        height: Int,
        minDimension: Int
    ) -> [(minX: Int, minY: Int, maxX: Int, maxY: Int)] {
        guard boxes.count >= 2 else { return boxes }

        let widths = boxes.map { $0.maxX - $0.minX + 1 }.sorted()
        let heights = boxes.map { $0.maxY - $0.minY + 1 }.sorted()
        let medW = max(1, widths[widths.count / 2])
        let medH = max(1, heights[heights.count / 2])
        let wThreshold = Int(1.6 * Double(medW))
        let hThreshold = Int(1.6 * Double(medH))

        func colEmpty(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            var y = y0
            while y <= y1 {
                if fg[y * width + x] { return false }
                y += 1
            }
            return true
        }
        func rowEmpty(_ y: Int, _ x0: Int, _ x1: Int) -> Bool {
            let base = y * width
            var x = x0
            while x <= x1 {
                if fg[base + x] { return false }
                x += 1
            }
            return true
        }

        // Tight bounds of the foreground inside an axis-aligned sub-band.
        func tightVertical(x0: Int, x1: Int, y0: Int, y1: Int) -> (Int, Int)? {
            var lo = y1 + 1, hi = y0 - 1
            for y in y0...y1 where !rowEmpty(y, x0, x1) {
                if y < lo { lo = y }
                if y > hi { hi = y }
            }
            return lo <= hi ? (lo, hi) : nil
        }
        func tightHorizontal(x0: Int, x1: Int, y0: Int, y1: Int) -> (Int, Int)? {
            var lo = x1 + 1, hi = x0 - 1
            for x in x0...x1 where !colEmpty(x, y0, y1) {
                if x < lo { lo = x }
                if x > hi { hi = x }
            }
            return lo <= hi ? (lo, hi) : nil
        }

        func splitColumns(_ b: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> [(minX: Int, minY: Int, maxX: Int, maxY: Int)] {
            var runs: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
            var x = b.minX
            while x <= b.maxX {
                while x <= b.maxX && colEmpty(x, b.minY, b.maxY) { x += 1 }
                guard x <= b.maxX else { break }
                let startX = x
                while x <= b.maxX && !colEmpty(x, b.minY, b.maxY) { x += 1 }
                let endX = x - 1
                if endX - startX + 1 >= minDimension,
                   let (y0, y1) = tightVertical(x0: startX, x1: endX, y0: b.minY, y1: b.maxY) {
                    runs.append((startX, y0, endX, y1))
                }
            }
            return runs.count >= 2 ? runs : [b]
        }

        func splitRows(_ b: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> [(minX: Int, minY: Int, maxX: Int, maxY: Int)] {
            var runs: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
            var y = b.minY
            while y <= b.maxY {
                while y <= b.maxY && rowEmpty(y, b.minX, b.maxX) { y += 1 }
                guard y <= b.maxY else { break }
                let startY = y
                while y <= b.maxY && !rowEmpty(y, b.minX, b.maxX) { y += 1 }
                let endY = y - 1
                if endY - startY + 1 >= minDimension,
                   let (x0, x1) = tightHorizontal(x0: b.minX, x1: b.maxX, y0: startY, y1: endY) {
                    runs.append((x0, startY, x1, endY))
                }
            }
            return runs.count >= 2 ? runs : [b]
        }

        func splitBox(_ b: (minX: Int, minY: Int, maxX: Int, maxY: Int), _ depth: Int) -> [(minX: Int, minY: Int, maxX: Int, maxY: Int)] {
            guard depth < 5 else { return [b] }
            let w = b.maxX - b.minX + 1
            let h = b.maxY - b.minY + 1
            if w > wThreshold {
                let pieces = splitColumns(b)
                if pieces.count >= 2 { return pieces.flatMap { splitBox($0, depth + 1) } }
            }
            if h > hThreshold {
                let pieces = splitRows(b)
                if pieces.count >= 2 { return pieces.flatMap { splitBox($0, depth + 1) } }
            }
            return [b]
        }

        return boxes.flatMap { splitBox($0, 0) }
    }

    /// Restores original pixels back into the working image wherever the brush
    /// strokes / polygons / selection mask mark them. Used to undo over-removal
    /// from luma keying. `base` and `original` must share dimensions.
    static func restore(
        base: CGImage,
        original: CGImage,
        strokes: [[CGPoint]],
        polygons: [[PolygonVertex]],
        brushSize: CGFloat,
        brushShape: BrushShape = .circle,
        brushHardness: CGFloat = 1.0,
        feather: CGFloat = 0,
        selectionMask: CGImage? = nil
    ) throws -> CGImage {
        guard !strokes.isEmpty || !polygons.isEmpty || selectionMask != nil else {
            return base
        }

        let width = base.width
        let height = base.height
        guard let colorSpace = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PipelineError.renderFailed
        }

        // Weight buffer: 255 = take original, 0 = keep base.
        let weightPtr = try rasterizeRemovalBuffer(
            width: width, height: height,
            strokes: strokes, polygons: polygons,
            brushSize: brushSize, brushShape: brushShape,
            brushHardness: brushHardness, feather: feather,
            selectionMask: selectionMask
        )
        defer { weightPtr.deallocate() }

        func draw(_ image: CGImage) throws -> (UnsafeMutablePointer<UInt8>, Int, CGContext) {
            guard let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let data = ctx.data else { throw PipelineError.renderFailed }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (data.bindMemory(to: UInt8.self, capacity: height * ctx.bytesPerRow), ctx.bytesPerRow, ctx)
        }

        let (basePtr, baseBpr, outCtx) = try draw(base)
        let (origPtr, origBpr, origCtx) = try draw(original)

        // Both contexts must stay alive while we read/write through their pointers.
        return try withExtendedLifetime((outCtx, origCtx)) { () throws -> CGImage in
            // Premultiplied channels are linear in coverage, so a straight lerp on
            // all four channels is correct.
            for y in 0..<height {
                for x in 0..<width {
                    let w = Int(weightPtr[y * width + x])
                    guard w > 0 else { continue }
                    let bOff = y * baseBpr + x * 4
                    let oOff = y * origBpr + x * 4
                    let keep = 255 - w
                    for c in 0..<4 {
                        let blended = (Int(basePtr[bOff + c]) * keep + Int(origPtr[oOff + c]) * w) / 255
                        basePtr[bOff + c] = UInt8(max(0, min(255, blended)))
                    }
                }
            }

            guard let result = outCtx.makeImage() else { throw PipelineError.renderFailed }
            return result
        }
    }

    /// Background-eraser: within the painted brush/lasso/selection, removes only
    /// near-black pixels (luma below `threshold`, soft falloff over `softness`),
    /// keeping bright art. Gives spatial control over a luma key — paint the area
    /// you want cleaned and connected bright regions elsewhere are untouched.
    static func eraseBackground(
        cgImage base: CGImage,
        strokes: [[CGPoint]],
        polygons: [[PolygonVertex]],
        brushSize: CGFloat,
        brushShape: BrushShape = .circle,
        brushHardness: CGFloat = 1.0,
        feather: CGFloat = 0,
        threshold: CGFloat,
        softness: CGFloat,
        selectionMask: CGImage? = nil
    ) throws -> CGImage {
        guard !strokes.isEmpty || !polygons.isEmpty || selectionMask != nil else {
            return base
        }

        let width = base.width
        let height = base.height
        guard let colorSpace = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PipelineError.renderFailed
        }

        // Where the user painted (0 = untouched, 255 = full brush coverage).
        let coverage = try rasterizeRemovalBuffer(
            width: width, height: height,
            strokes: strokes, polygons: polygons,
            brushSize: brushSize, brushShape: brushShape,
            brushHardness: brushHardness, feather: feather,
            selectionMask: selectionMask
        )
        defer { coverage.deallocate() }

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else { throw PipelineError.renderFailed }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)

        let thresh = Float(threshold)
        let soft = max(1, Float(softness))

        for y in 0..<height {
            let row = y * bpr
            let covRow = y * width
            for x in 0..<width {
                let cov = coverage[covRow + x]
                guard cov > 0 else { continue }
                let off = row + x * 4
                let a = ptr[off + 3]
                guard a > 0 else { continue }

                // Un-premultiply to read the true colour, then its luma.
                let af = Float(a) / 255.0
                let r = Float(ptr[off]) / af
                let g = Float(ptr[off + 1]) / af
                let b = Float(ptr[off + 2]) / af
                let luma = 0.299 * r + 0.587 * g + 0.114 * b

                // 1 below threshold, 0 above threshold+softness, linear between.
                let darkWeight = max(0, min(1, (thresh + soft - luma) / soft))
                guard darkWeight > 0 else { continue }

                let removal = (Float(cov) / 255.0) * darkWeight
                let keep = 1.0 - removal
                ptr[off] = UInt8(max(0, min(255, Float(ptr[off]) * keep)))
                ptr[off + 1] = UInt8(max(0, min(255, Float(ptr[off + 1]) * keep)))
                ptr[off + 2] = UInt8(max(0, min(255, Float(ptr[off + 2]) * keep)))
                ptr[off + 3] = UInt8(max(0, min(255, Float(a) * keep)))
            }
        }

        guard let result = ctx.makeImage() else { throw PipelineError.renderFailed }
        return result
    }

    /// Crops the image to the tight bounding box of its non-transparent pixels.
    /// Returns the original image unchanged if it is fully transparent or already
    /// tight.
    static func trimTransparent(cgImage: CGImage, alphaThreshold: UInt8 = 2) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return cgImage }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return cgImage }
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowBase = y * bpr
            for x in 0..<width where ptr[rowBase + x * 4 + 3] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        guard maxX >= minX, maxY >= minY else { return cgImage }
        if minX == 0 && minY == 0 && maxX == width - 1 && maxY == height - 1 { return cgImage }

        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return cgImage.cropping(to: rect) ?? cgImage
    }

    static func magicWandMask(
        cgImage: CGImage,
        at normalizedPoint: CGPoint,
        tolerance: CGFloat,
        contiguous: Bool
    ) throws -> CGImage {
        let width = cgImage.width
        let height = cgImage.height

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PipelineError.renderFailed
        }

        guard let srcCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PipelineError.renderFailed }

        srcCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let srcData = srcCtx.data else { throw PipelineError.renderFailed }
        let srcBytesPerRow = srcCtx.bytesPerRow
        let srcPtr = srcData.bindMemory(to: UInt8.self, capacity: height * srcBytesPerRow)

        let sx = Int(normalizedPoint.x * CGFloat(width))
        let sy = Int((1.0 - normalizedPoint.y) * CGFloat(height))
        let cx = min(max(sx, 0), width - 1)
        let cy = min(max(sy, 0), height - 1)

        func pixelColor(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let off = y * srcBytesPerRow + x * 4
            return (srcPtr[off], srcPtr[off + 1], srcPtr[off + 2])
        }

        let seed = pixelColor(cx, cy)

        func colorDist(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> CGFloat {
            let dr = CGFloat(a.0) - CGFloat(b.0)
            let dg = CGFloat(a.1) - CGFloat(b.1)
            let db = CGFloat(a.2) - CGFloat(b.2)
            return sqrt(2 * dr * dr + 4 * dg * dg + 3 * db * db)
        }

        let threshold = min(max(tolerance, 0), 255)

        guard let maskCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw PipelineError.renderFailed }

        guard let maskData = maskCtx.data else { throw PipelineError.renderFailed }
        let maskBytesPerRow = maskCtx.bytesPerRow
        let maskPtr = maskData.bindMemory(to: UInt8.self, capacity: height * maskBytesPerRow)
        memset(maskPtr, 0, height * maskBytesPerRow)

        if contiguous {
            var queue = [(cx, cy)]
            var head = 0
            maskPtr[cy * maskBytesPerRow + cx] = 255

            while head < queue.count {
                let (qx, qy) = queue[head]; head += 1
                let neighbors = [(qx - 1, qy), (qx + 1, qy), (qx, qy - 1), (qx, qy + 1)]
                for (nx, ny) in neighbors {
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    guard maskPtr[ny * maskBytesPerRow + nx] == 0 else { continue }
                    let col = pixelColor(nx, ny)
                    if colorDist(seed, col) <= threshold {
                        maskPtr[ny * maskBytesPerRow + nx] = 255
                        queue.append((nx, ny))
                    }
                }
            }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    if colorDist(seed, pixelColor(x, y)) <= threshold {
                        maskPtr[y * maskBytesPerRow + x] = 255
                    }
                }
            }
        }

        guard let result = maskCtx.makeImage() else {
            throw PipelineError.renderFailed
        }
        return result
    }

    static func unionMask(existing: CGImage, with newMask: CGImage) throws -> CGImage {
        let w = existing.width; let h = existing.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(data: nil, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data,
              let eData = existing.dataProvider?.data,
              let nData = newMask.dataProvider?.data,
              let ePtr = CFDataGetBytePtr(eData),
              let nPtr = CFDataGetBytePtr(nData)
        else { throw PipelineError.renderFailed }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h)
        let eBytes = existing.bytesPerRow
        let nBytes = newMask.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let eOn = ePtr[y * eBytes + x] > 128
                let nOn = nPtr[y * nBytes + x] > 128
                ptr[y * w + x] = (eOn || nOn) ? 255 : 0
            }
        }
        guard let result = ctx.makeImage() else { throw PipelineError.renderFailed }
        return result
    }

    /// Builds a tight, bbox-sized RGBA image where the component pixels are opaque
    /// white and everything else is transparent — so overlays can show the actual
    /// shape being removed/restored instead of a plain rectangle. Same row
    /// convention as the source mask, so it aligns with the bbox overlay.
    static func maskShapeImage(mask: CGImage, boundingBox: CGRect) -> CGImage? {
        guard let md = mask.dataProvider?.data,
              let mp = CFDataGetBytePtr(md) else { return nil }
        let mbpr = mask.bytesPerRow
        let ox = Int(boundingBox.minX)
        let oy = Int(boundingBox.minY)
        let w = Int(boundingBox.width)
        let h = Int(boundingBox.height)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ), let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: h * bpr)
        memset(p, 0, h * bpr)
        for y in 0..<h {
            let my = oy + y
            if my < 0 || my >= mask.height { continue }
            let mRow = my * mbpr
            let oRow = y * bpr
            for x in 0..<w {
                let mx = ox + x
                if mx < 0 || mx >= mask.width { continue }
                if mp[mRow + mx] > 128 {
                    let off = oRow + x * 4
                    p[off] = 255; p[off + 1] = 255; p[off + 2] = 255; p[off + 3] = 255
                }
            }
        }
        return ctx.makeImage()
    }

    /// ORs many full-size grayscale masks into one, so a batch of detected spots
    /// can be removed in a single undoable step.
    static func combineMasks(_ masks: [CGImage]) -> CGImage? {
        guard let first = masks.first else { return nil }
        let w = first.width
        let h = first.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ), let data = ctx.data else { return nil }
        let outBpr = ctx.bytesPerRow
        let out = data.bindMemory(to: UInt8.self, capacity: h * outBpr)
        memset(out, 0, h * outBpr)
        for mask in masks {
            guard mask.width == w, mask.height == h,
                  let md = mask.dataProvider?.data,
                  let mp = CFDataGetBytePtr(md) else { continue }
            let mbpr = mask.bytesPerRow
            for y in 0..<h {
                let outRow = y * outBpr
                let mRow = y * mbpr
                for x in 0..<w where mp[mRow + x] > 128 {
                    out[outRow + x] = 255
                }
            }
        }
        return ctx.makeImage()
    }

    static func contourPath(from mask: CGImage) -> CGPath {
        let path = CGMutablePath()
        let w = mask.width; let h = mask.height
        guard let data = mask.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return path }
        let bytesPerRow = mask.bytesPerRow

        for y in 0..<h {
            for x in 0..<w {
                let isSet = ptr[y * bytesPerRow + x] > 128
                if !isSet { continue }
                let top = y == 0 || ptr[(y-1) * bytesPerRow + x] <= 128
                let bottom = y == h-1 || ptr[(y+1) * bytesPerRow + x] <= 128
                let left = x == 0 || ptr[y * bytesPerRow + (x-1)] <= 128
                let right = x == w-1 || ptr[y * bytesPerRow + (x+1)] <= 128

                let fx = CGFloat(x); let fy = CGFloat(y)
                let fw = CGFloat(w); let fh = CGFloat(h)
                let nx = fx / fw; let ny = 1.0 - fy / fh
                let nw = 1.0 / fw; let nh = 1.0 / fh

                if top {
                    path.move(to: CGPoint(x: nx, y: ny))
                    path.addLine(to: CGPoint(x: nx + nw, y: ny))
                }
                if bottom {
                    path.move(to: CGPoint(x: nx, y: ny + nh))
                    path.addLine(to: CGPoint(x: nx + nw, y: ny + nh))
                }
                if left {
                    path.move(to: CGPoint(x: nx, y: ny))
                    path.addLine(to: CGPoint(x: nx, y: ny + nh))
                }
                if right {
                    path.move(to: CGPoint(x: nx + nw, y: ny))
                    path.addLine(to: CGPoint(x: nx + nw, y: ny + nh))
                }
            }
        }
        return path
    }

    static func saveReplacingOriginal(
        image: CGImage,
        originalURL: URL,
        sourceProperties: CFDictionary?
    ) throws -> URL {
        let backupURL = makeBackupURL(for: originalURL)
        try FileManager.default.copyItem(at: originalURL, to: backupURL)

        let directory = originalURL.deletingLastPathComponent()
        let originalExtension = originalURL.pathExtension.isEmpty ? "png" : originalURL.pathExtension
        let tempName = ".\(originalURL.lastPathComponent).tmp-\(UUID().uuidString).\(originalExtension)"
        let tempURL = directory.appendingPathComponent(tempName)

        do {
            let data = try makeImageData(for: originalURL, from: image, sourceProperties: sourceProperties)
            try data.write(to: tempURL, options: .atomic)
            do {
                _ = try FileManager.default.replaceItemAt(
                    originalURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } catch {
                // Fallback for replaceItemAt failures on certain filesystems while preserving backup safety.
                try? FileManager.default.removeItem(at: originalURL)
                try FileManager.default.moveItem(at: tempURL, to: originalURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return backupURL
    }

    static func makeBackupURL(for originalURL: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())

        let ext = originalURL.pathExtension.isEmpty ? "png" : originalURL.pathExtension
        let name = originalURL.deletingPathExtension().lastPathComponent
        let directory = originalURL.deletingLastPathComponent()

        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let backupFile = "\(name).backup-\(stamp)\(suffix).\(ext)"
            let backupURL = directory.appendingPathComponent(backupFile)

            if !FileManager.default.fileExists(atPath: backupURL.path) {
                return backupURL
            }
        }

        let fallback = "\(name).backup-\(stamp)-\(UUID().uuidString.prefix(8)).\(ext)"
        return directory.appendingPathComponent(fallback)
    }

    static func makeImageData(
        for targetURL: URL,
        from image: CGImage,
        sourceProperties: CFDictionary?
    ) throws -> Data {
        let ext = targetURL.pathExtension.lowercased()
        let inferredType = UTType(filenameExtension: ext)

        if ext == "jpg" || ext == "jpeg" || inferredType?.conforms(to: .jpeg) == true {
            return try makeJPEGData(from: image, sourceProperties: sourceProperties)
        } else if ext == "webp" || inferredType?.conforms(to: .webP) == true {
            if let webpData = try? makeWebPData(from: image, sourceProperties: sourceProperties) {
                return webpData
            }
            return try makePNGData(from: image, sourceProperties: sourceProperties)
        } else {
            return try makePNGData(from: image, sourceProperties: sourceProperties)
        }
    }

    static func makeJPEGData(
        from image: CGImage,
        sourceProperties: CFDictionary?,
        compressionQuality: CGFloat = 0.92
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PipelineError.imageEncodingFailed
        }

        var outputProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]

        if let source = sourceProperties as? [CFString: Any] {
            if let dpiWidth = source[kCGImagePropertyDPIWidth] {
                outputProperties[kCGImagePropertyDPIWidth] = dpiWidth
            }
            if let dpiHeight = source[kCGImagePropertyDPIHeight] {
                outputProperties[kCGImagePropertyDPIHeight] = dpiHeight
            }
            if let jfifMeta = source[kCGImagePropertyJFIFDictionary] {
                outputProperties[kCGImagePropertyJFIFDictionary] = jfifMeta
            }
            if let exifMeta = source[kCGImagePropertyExifDictionary] {
                outputProperties[kCGImagePropertyExifDictionary] = exifMeta
            }
        }

        CGImageDestinationAddImage(
            destination,
            image,
            outputProperties as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw PipelineError.imageEncodingFailed
        }

        return data as Data
    }

    static func makeWebPData(
        from image: CGImage,
        sourceProperties: CFDictionary?,
        compressionQuality: CGFloat = 0.9
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.webP.identifier as CFString,
            1,
            nil
        ) else {
            throw PipelineError.imageEncodingFailed
        }

        var outputProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]

        if let source = sourceProperties as? [CFString: Any] {
            if let dpiWidth = source[kCGImagePropertyDPIWidth] {
                outputProperties[kCGImagePropertyDPIWidth] = dpiWidth
            }
            if let dpiHeight = source[kCGImagePropertyDPIHeight] {
                outputProperties[kCGImagePropertyDPIHeight] = dpiHeight
            }
        }

        CGImageDestinationAddImage(
            destination,
            image,
            outputProperties as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw PipelineError.imageEncodingFailed
        }

        return data as Data
    }

    static func makePNGData(from image: CGImage, sourceProperties: CFDictionary?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PipelineError.pngEncodingFailed
        }

        var outputProperties: [CFString: Any] = [:]

        if let source = sourceProperties as? [CFString: Any] {
            if let dpiWidth = source[kCGImagePropertyDPIWidth] {
                outputProperties[kCGImagePropertyDPIWidth] = dpiWidth
            }

            if let dpiHeight = source[kCGImagePropertyDPIHeight] {
                outputProperties[kCGImagePropertyDPIHeight] = dpiHeight
            }

            if let pngMeta = source[kCGImagePropertyPNGDictionary] {
                outputProperties[kCGImagePropertyPNGDictionary] = pngMeta
            }
        }

        CGImageDestinationAddImage(
            destination,
            image,
            outputProperties.isEmpty ? nil : outputProperties as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw PipelineError.pngEncodingFailed
        }

        return data as Data
    }
}
