import AppKit
import CoreGraphics
import Foundation

extension ImagePipeline {
    /// Detects regions the luma key (or erasing) cleared: enclosed transparent
    /// holes inside the asset, as well as edge-connected dark outlines, shadows,
    /// and crevices near the artwork that were opaque in the original image.
    static func detectRemovedSpots(
        processed: CGImage,
        original: CGImage,
        minSize: Int = 16,
        includeEdgeDetails: Bool = true,
        maxEdgeDistance: Int = 35
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

        let procCtx = try drawnContext(processed)
        let origCtx = try drawnContext(original)
        return try withExtendedLifetime((procCtx, origCtx)) { () throws -> [DarkSpot] in
            let procBpr = procCtx.bytesPerRow
            let procPtr = procCtx.data!.bindMemory(to: UInt8.self, capacity: height * procBpr)
            let origBpr = origCtx.bytesPerRow
            let origPtr = origCtx.data!.bindMemory(to: UInt8.self, capacity: height * origBpr)

            let total = width * height
            var isTransparent = [Bool](repeating: false, count: total)
            var wasOpaque = [Bool](repeating: false, count: total)
            var isOpaqueArt = [Bool](repeating: false, count: total)

            for y in 0..<height {
                let procRow = y * procBpr
                let origRow = y * origBpr
                let baseIdx = y * width
                for x in 0..<width {
                    let idx = baseIdx + x
                    let pA = procPtr[procRow + x * 4 + 3]
                    let oA = origPtr[origRow + x * 4 + 3]
                    isTransparent[idx] = pA < 128
                    wasOpaque[idx] = oA > 128
                    isOpaqueArt[idx] = pA >= 128
                }
            }

            // Candidate removed pixels: transparent now, but were opaque in original
            var isCandidate = [Bool](repeating: false, count: total)
            for i in 0..<total {
                isCandidate[i] = isTransparent[i] && wasOpaque[i]
            }

            // Flood-fill external background from borders through transparent pixels
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

            // Compute distance to nearest opaque art pixel using BFS
            var distToArt = [Int](repeating: Int.max, count: total)
            var artQueue = [Int]()
            artQueue.reserveCapacity(total / 8)

            for i in 0..<total where isOpaqueArt[i] {
                distToArt[i] = 0
                artQueue.append(i)
            }

            var artHead = 0
            let maxDist = maxEdgeDistance
            while artHead < artQueue.count {
                let idx = artQueue[artHead]; artHead += 1
                let d = distToArt[idx]
                if d >= maxDist { continue }

                let cx = idx % width
                let cy = idx / width

                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = cx + dx
                    let ny = cy + dy
                    if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
                    let nIdx = ny * width + nx
                    if distToArt[nIdx] > d + 1 {
                        distToArt[nIdx] = d + 1
                        artQueue.append(nIdx)
                    }
                }
            }

            // Ray enclosure test: detect pixels surrounded by art on 2+ opposing sides
            var isEnclosedCavity = [Bool](repeating: false, count: total)
            if includeEdgeDetails {
                for y in 0..<height {
                    for x in 0..<width {
                        let idx = y * width + x
                        guard isCandidate[idx] && isExternal[idx] else { continue }
                        guard distToArt[idx] <= maxDist + 15 else { continue }

                        // Check 4 directions for nearby art
                        var hitLeft = false, hitRight = false, hitUp = false, hitDown = false
                        let stepLimit = min(maxDist + 10, 45)

                        for step in 1...stepLimit {
                            if x - step >= 0 && isOpaqueArt[y * width + (x - step)] { hitLeft = true; break }
                        }
                        for step in 1...stepLimit {
                            if x + step < width && isOpaqueArt[y * width + (x + step)] { hitRight = true; break }
                        }
                        for step in 1...stepLimit {
                            if y - step >= 0 && isOpaqueArt[(y - step) * width + x] { hitUp = true; break }
                        }
                        for step in 1...stepLimit {
                            if y + step < height && isOpaqueArt[(y + step) * width + x] { hitDown = true; break }
                        }

                        let hits = (hitLeft ? 1 : 0) + (hitRight ? 1 : 0) + (hitUp ? 1 : 0) + (hitDown ? 1 : 0)
                        if (hitLeft && hitRight) || (hitUp && hitDown) || hits >= 3 {
                            isEnclosedCavity[idx] = true
                        }
                    }
                }
            }

            // Mark valid removed spot targets
            var isSpotPixel = [Bool](repeating: false, count: total)
            for i in 0..<total {
                guard isCandidate[i] else { continue }
                if !isExternal[i] {
                    // Enclosed hole inside artwork
                    isSpotPixel[i] = true
                } else if includeEdgeDetails {
                    // Edge-connected outline, shadow, or notch near artwork
                    if distToArt[i] <= maxDist || isEnclosedCavity[i] {
                        isSpotPixel[i] = true
                    }
                }
            }

            // Connected-component label spot pixels
            var visited = [Bool](repeating: false, count: total)
            var spots: [DarkSpot] = []
            var componentQueue = [Int]()
            componentQueue.reserveCapacity(4096)
            var spotIndex = 0

            for seed in 0..<total {
                if visited[seed] || !isSpotPixel[seed] { continue }
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

                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = cx + dx
                        let ny = cy + dy
                        if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
                        let nIdx = ny * width + nx
                        if !visited[nIdx] && isSpotPixel[nIdx] {
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
