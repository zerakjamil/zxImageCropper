import AppKit
import CoreGraphics
import Foundation

extension ImagePipeline {
    /// Detects regions the luma key (or erasing) wrongly cleared: enclosed
    /// transparent holes inside the asset that were opaque in the original.
    ///
    /// Mirror image of `detectDarkSpots`:
    /// 1. Flood-fill from all borders through transparent pixels → external
    ///    background (the part we meant to remove).
    /// 2. Connected-component label transparent pixels NOT reached from the
    ///    border — those are holes punched inside the asset.
    /// 3. Keep components that were opaque in the original (so we have something
    ///    to restore) and are above the minimum size.
    ///
    /// Holes that connect to the border through a thin channel are treated as
    /// background and skipped — use the Restore brush for those.
    static func detectRemovedSpots(
        processed: CGImage,
        original: CGImage,
        minSize: Int = 16
    ) throws -> [DarkSpot] {
        let width = processed.width
        let height = processed.height
        guard width > 1, height > 1,
              original.width == width, original.height == height else {
            throw PipelineError.renderFailed
        }

        func drawnContext(_ image: CGImage) throws -> CGContext {
            guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { throw PipelineError.renderFailed }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard ctx.data != nil else { throw PipelineError.renderFailed }
            return ctx
        }

        // The contexts must outlive every read through their data pointers, so the
        // whole computation runs inside withExtendedLifetime.
        let procCtx = try drawnContext(processed)
        let origCtx = try drawnContext(original)
        return try withExtendedLifetime((procCtx, origCtx)) { () throws -> [DarkSpot] in
        let procBpr = procCtx.bytesPerRow
        let procPtr = procCtx.data!.bindMemory(to: UInt8.self, capacity: height * procBpr)
        let origBpr = origCtx.bytesPerRow
        let origPtr = origCtx.data!.bindMemory(to: UInt8.self, capacity: height * origBpr)

        let total = width * height
        // Transparent now; opaque in the original = a candidate "removed" pixel.
        var isTransparent = [Bool](repeating: false, count: total)
        var wasOpaque = [Bool](repeating: false, count: total)
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                isTransparent[idx] = procPtr[y * procBpr + x * 4 + 3] < 128
                wasOpaque[idx] = origPtr[y * origBpr + x * 4 + 3] > 128
            }
        }

        // Flood-fill external background through transparent pixels.
        var isExternal = [Bool](repeating: false, count: total)
        var queue = [Int]()
        queue.reserveCapacity(total / 4)
        func enqueueExternal(_ x: Int, _ y: Int) {
            let idx = y * width + x
            if isExternal[idx] || !isTransparent[idx] { return }
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

        // Label enclosed transparent components.
        var visited = [Bool](repeating: false, count: total)
        var spots: [DarkSpot] = []
        var componentQueue = [Int]()
        componentQueue.reserveCapacity(4096)
        var spotIndex = 0

        for seed in 0..<total {
            if visited[seed] || isExternal[seed] || !isTransparent[seed] { continue }
            visited[seed] = true
            componentQueue.removeAll(keepingCapacity: true)
            componentQueue.append(seed)
            var head2 = 0
            var minX = width, minY = height, maxX = 0, maxY = 0, count = 0, opaqueCount = 0
            var pixels: [(Int, Int)] = []

            while head2 < componentQueue.count {
                let idx = componentQueue[head2]; head2 += 1
                let cx = idx % width
                let cy = idx / width
                count += 1
                if wasOpaque[idx] { opaqueCount += 1 }
                if cx < minX { minX = cx }
                if cx > maxX { maxX = cx }
                if cy < minY { minY = cy }
                if cy > maxY { maxY = cy }
                pixels.append((cx, cy))

                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = cx + dx
                    let ny = cy + dy
                    if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
                    let nIdx = ny * width + nx
                    if !visited[nIdx] && !isExternal[nIdx] && isTransparent[nIdx] {
                        visited[nIdx] = true
                        componentQueue.append(nIdx)
                    }
                }
            }

            // Require both a minimum size and that most of it was real asset.
            guard count >= minSize, opaqueCount * 2 >= count else { continue }

            guard let grayCtx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let grayData = grayCtx.data else { continue }
            let grayBpr = grayCtx.bytesPerRow
            let grayPtr = grayData.bindMemory(to: UInt8.self, capacity: height * grayBpr)
            memset(grayPtr, 0, height * grayBpr)
            for (px, py) in pixels {
                grayPtr[py * grayBpr + px] = 255
            }
            guard let mask = grayCtx.makeImage() else { continue }

            let bbox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
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
}
