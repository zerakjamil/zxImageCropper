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
            return "This MVP supports PNG files only."
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

    static func loadPNG(at url: URL) throws -> LoadedImage {
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
        guard let type = UTType(typeIdentifier), type.conforms(to: .png) else {
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
