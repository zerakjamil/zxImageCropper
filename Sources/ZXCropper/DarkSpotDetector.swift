import AppKit
import CoreGraphics
import Foundation

struct DarkSpot: Identifiable {
    let id: Int
    let boundingBox: CGRect
    let mask: CGImage
    /// Bbox-sized, transparent-background image of the actual region (for shape
    /// overlays). Nil only if it couldn't be built.
    let shapeImage: CGImage?
    let pixelCount: Int
}

extension ImagePipeline {
    /// Detects dark matte spots INSIDE the asset that were not removed by luma
    /// key (because they're not connected to the image borders).
    ///
    /// Algorithm:
    /// 1. Flood-fill from all borders through dark pixels (luma < threshold) →
    ///    marks the "external" background.
    /// 2. Connected-component label all remaining dark pixels that were NOT
    ///    reached by the border flood → each component is a dark spot.
    /// 3. Filter by minimum pixel count to drop noise.
    /// 4. Return each spot with its bounding box (pixel coords, top-left origin)
    ///    and a grayscale mask for click-to-remove.
    /// - Parameter includeBorderConnected: when `true`, also returns the
    ///   edge-connected dark regions — i.e. exactly what a luma key at the same
    ///   threshold would remove — so they can be previewed and removed piece by
    ///   piece instead of all at once.
    static func detectDarkSpots(
        cgImage: CGImage,
        threshold: CGFloat,
        minSize: Int = 16,
        includeBorderConnected: Bool = false
    ) throws -> [DarkSpot] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 1, height > 1 else { throw PipelineError.renderFailed }

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let srcCtx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw PipelineError.renderFailed }
        srcCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let srcData = srcCtx.data else { throw PipelineError.renderFailed }
        let bpr = srcCtx.bytesPerRow
        let ptr = srcData.bindMemory(to: UInt8.self, capacity: height * bpr)

        let thresh = Float(threshold)
        let total = width * height

        // Compute luma + dark mask.
        // A pixel is a "dark spot candidate" only if it's OPAQUE (alpha > 128)
        // AND its luma < threshold. After luma keying, transparent pixels have
        // RGB=(0,0,0) in premultiplied format — we must NOT detect those as spots.
        // The flood-fill from borders passes through both dark opaque pixels AND
        // already-transparent pixels (so it can reach inner spots through holes).
        var isDark = [Bool](repeating: false, count: total)
        var isPassable = [Bool](repeating: false, count: total)
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bpr + x * 4
                let a = ptr[off + 3]
                let isOpaque = a > 128
                let r = Float(ptr[off])
                let g = Float(ptr[off + 1])
                let b = Float(ptr[off + 2])
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                let isDarkPixel = lum < thresh
                isDark[y * width + x] = isDarkPixel && isOpaque
                // Flood can pass through dark opaque pixels OR transparent pixels
                isPassable[y * width + x] = (isDarkPixel && isOpaque) || !isOpaque
            }
        }

        // Flood-fill from borders through passable pixels → mark external. When
        // includeBorderConnected is set we leave `isExternal` all-false so the
        // labeller below also picks up the edge-connected (luma-removable) regions.
        var isExternal = [Bool](repeating: false, count: total)
        if !includeBorderConnected {
            var queue = [Int]()
            queue.reserveCapacity(total / 4)

            func enqueueExternal(_ x: Int, _ y: Int) {
                let idx = y * width + x
                if isExternal[idx] || !isPassable[idx] { return }
                isExternal[idx] = true
                queue.append(idx)
            }

            for x in 0..<width { enqueueExternal(x, 0); enqueueExternal(x, height - 1) }
            for y in 0..<height { enqueueExternal(0, y); enqueueExternal(width - 1, y) }

            var head = 0
            while head < queue.count {
                let idx = queue[head]; head += 1
                let cx = idx % width
                let cy = idx / width
                if cx > 0 { enqueueExternal(cx - 1, cy) }
                if cx < width - 1 { enqueueExternal(cx + 1, cy) }
                if cy > 0 { enqueueExternal(cx, cy - 1) }
                if cy < height - 1 { enqueueExternal(cx, cy + 1) }
            }
        }

        // Connected-component label remaining dark (not external) pixels
        var visited = [Bool](repeating: false, count: total)
        var spots: [DarkSpot] = []
        var componentQueue = [Int]()
        componentQueue.reserveCapacity(4096)
        var spotIndex = 0

        for seed in 0..<total {
            if visited[seed] || isExternal[seed] || !isDark[seed] { continue }
            visited[seed] = true
            componentQueue.removeAll(keepingCapacity: true)
            componentQueue.append(seed)
            var head2 = 0
            var minX = width, minY = height, maxX = 0, maxY = 0, count = 0
            var componentPixels: [(Int, Int)] = []

            while head2 < componentQueue.count {
                let idx = componentQueue[head2]; head2 += 1
                let cx = idx % width
                let cy = idx / width
                count += 1
                if cx < minX { minX = cx }
                if cx > maxX { maxX = cx }
                if cy < minY { minY = cy }
                if cy > maxY { maxY = cy }
                componentPixels.append((cx, cy))

                for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let nx = cx + dx
                    let ny = cy + dy
                    if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
                    let nIdx = ny * width + nx
                    if !visited[nIdx] && !isExternal[nIdx] && isDark[nIdx] {
                        visited[nIdx] = true
                        componentQueue.append(nIdx)
                    }
                }
            }

            guard count >= minSize else { continue }

            // Build mask for this component
            guard let grayCtx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let grayData = grayCtx.data else { continue }
            let grayBpr = grayCtx.bytesPerRow
            let grayPtr = grayData.bindMemory(to: UInt8.self, capacity: height * grayBpr)
            memset(grayPtr, 0, height * grayBpr)
            for (px, py) in componentPixels {
                grayPtr[py * grayBpr + px] = 255
            }
            guard let mask = grayCtx.makeImage() else { continue }

            // Bounding box in pixel coords (top-left origin for canvas overlay)
            let bbox = CGRect(
                x: minX, y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            )

            spots.append(DarkSpot(
                id: spotIndex,
                boundingBox: bbox,
                mask: mask,
                shapeImage: maskShapeImage(mask: mask, boundingBox: bbox),
                pixelCount: count
            ))
            spotIndex += 1
        }

        return spots
    }
}
