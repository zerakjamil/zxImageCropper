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
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Image file not found."
        case .permissionDenied:
            return "Permission denied. Grant folder access and try again."
        case .unsupportedFormat:
            return "Supports PNG and WebP files only."
        case .unableToLoadImage:
            return "Unable to load the source image."
        case .renderFailed:
            return "Failed to process the image."
        case .pngEncodingFailed:
            return "Failed to encode PNG output."
        }
    }
}

struct LoadedImage {
    let url: URL
    let cgImage: CGImage
    let sourceProperties: CFDictionary?
}

enum ImagePipeline {
    private static let context = CIContext(options: [.cacheIntermediates: false])

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
        guard let type = UTType(typeIdentifier),
              type.conforms(to: .png) || type.conforms(to: .webP) else {
            throw PipelineError.unsupportedFormat
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PipelineError.unableToLoadImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)

        return LoadedImage(url: url, cgImage: image, sourceProperties: properties)
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
        selectionMask: CGImage? = nil
    ) throws -> CGImage {
        guard !strokes.isEmpty || !polygons.isEmpty || selectionMask != nil else {
            return cgImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let halfBrush = brushSize / 2.0

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PipelineError.renderFailed
        }

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
        ctx.setBlendMode(.clear)

        if let mask = selectionMask {
            guard let maskData = mask.dataProvider?.data,
                  let srcData = ctx.data,
                  let maskPtr = CFDataGetBytePtr(maskData) else { throw PipelineError.renderFailed }
            let maskBytesPerRow = mask.bytesPerRow
            let ctxBytesPerRow = ctx.bytesPerRow
            let pixelPtr = srcData.bindMemory(to: UInt8.self, capacity: height * ctxBytesPerRow)
            for y in 0..<height {
                for x in 0..<width {
                    if maskPtr[y * maskBytesPerRow + x] > 128 {
                        let off = y * ctxBytesPerRow + x * 4
                        pixelPtr[off + 3] = 0
                    }
                }
            }
        }

        let lineCap: CGLineCap = brushShape == .square ? .square : .round
        let lineJoin: CGLineJoin = brushShape == .square ? .miter : .round

        for stroke in strokes {
            guard !stroke.isEmpty else { continue }

            ctx.setLineWidth(brushSize)
            ctx.setLineCap(lineCap)
            ctx.setLineJoin(lineJoin)

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
                    ctx.fill(rect)
                } else {
                    ctx.fillEllipse(in: rect)
                }
            } else {
                ctx.beginPath()
                let first = stroke[0]
                ctx.move(to: CGPoint(
                    x: first.x * CGFloat(width),
                    y: (1.0 - first.y) * CGFloat(height)
                ))
                for point in stroke.dropFirst() {
                    ctx.addLine(to: CGPoint(
                        x: point.x * CGFloat(width),
                        y: (1.0 - point.y) * CGFloat(height)
                    ))
                }
                ctx.strokePath()
            }
        }

        for polygon in polygons {
            guard polygon.count >= 3 else { continue }

            ctx.beginPath()
            ctx.move(to: cgPoint(polygon[0].anchor, width: width, height: height))

            for i in 0..<polygon.count {
                let next = (i + 1) % polygon.count
                let to = cgPoint(polygon[next].anchor, width: width, height: height)

                if let cp = polygon[i].segmentControl {
                    ctx.addQuadCurve(to: to, control: cgPoint(cp, width: width, height: height))
                } else {
                    ctx.addLine(to: to)
                }
            }

            ctx.closePath()
            ctx.fillPath()
        }

        guard let result = ctx.makeImage() else {
            throw PipelineError.renderFailed
        }

        return result
    }

    private static func cgPoint(_ norm: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: norm.x * CGFloat(width), y: (1.0 - norm.y) * CGFloat(height))
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
        let tempName = ".\(originalURL.lastPathComponent).tmp-\(UUID().uuidString).png"
        let tempURL = directory.appendingPathComponent(tempName)

        do {
            let data = try makePNGData(from: image, sourceProperties: sourceProperties)
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

    private static func makeBackupURL(for originalURL: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())

        let name = originalURL.deletingPathExtension().lastPathComponent
        let directory = originalURL.deletingLastPathComponent()

        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let backupFile = "\(name).backup-\(stamp)\(suffix).png"
            let backupURL = directory.appendingPathComponent(backupFile)

            if !FileManager.default.fileExists(atPath: backupURL.path) {
                return backupURL
            }
        }

        let fallback = "\(name).backup-\(stamp)-\(UUID().uuidString.prefix(8)).png"
        return directory.appendingPathComponent(fallback)
    }

    private static func makePNGData(from image: CGImage, sourceProperties: CFDictionary?) throws -> Data {
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
