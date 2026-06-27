import AppKit
import CoreGraphics
import Foundation

/// Result of automatic foreground-shape detection.
///
/// `mask` is a full-size grayscale image (255 = subject / keep, 0 = background /
/// remove). The red preview overlay is built on demand from the (possibly
/// refined) mask via `keepMaskOverlay`. `boundingBox` is in pixel coordinates
/// with a top-left origin (matching the canvas overlay convention).
struct ShapeDetection {
    let mask: CGImage
    let boundingBox: CGRect
    let pixelCount: Int
}

extension ImagePipeline {
    /// Detects the main foreground shape and returns a mask that keeps the subject
    /// while dropping the surrounding background.
    ///
    /// Algorithm:
    /// 1. Classify every pixel as "background-like": transparent (when the source
    ///    already carries alpha) or close in colour to the image border. Border
    ///    colours are sampled into a small quantised palette so smooth gradient
    ///    backgrounds are still covered — a pixel is background when it is within
    ///    `tolerance` (weighted colour distance) of *any* palette entry.
    /// 2. Flood-fill those background pixels inward from all four borders. Only
    ///    background connected to the edge becomes "external".
    /// 3. The subject is everything the flood could NOT reach. This automatically
    ///    fills holes enclosed by the shape (e.g. a dark pocket inside the asset).
    /// 4. Optionally keep only the largest connected blob, dropping stray specks.
    ///
    /// - Parameters:
    ///   - tolerance: weighted colour-distance radius for "background-like". Larger
    ///     values eat more of a soft halo/glow; smaller values keep more of it.
    ///   - keepLargest: keep only the single biggest subject component.
    static func detectForegroundShape(
        cgImage: CGImage,
        tolerance: CGFloat,
        keepLargest: Bool = true
    ) throws -> ShapeDetection {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 1, height > 1 else { throw PipelineError.renderFailed }

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw PipelineError.renderFailed }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { throw PipelineError.renderFailed }
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)
        let total = width * height

        // Does the source already carry meaningful transparency? If so, alpha is a
        // far cleaner subject signal than colour keying.
        var transparentSamples = 0
        var sampled = 0
        let sampleStepX = max(1, width / 200)
        let sampleStepY = max(1, height / 200)
        var sampleY = 0
        while sampleY < height {
            var sampleX = 0
            while sampleX < width {
                if ptr[sampleY * bpr + sampleX * 4 + 3] < 40 { transparentSamples += 1 }
                sampled += 1
                sampleX += sampleStepX
            }
            sampleY += sampleStepY
        }
        let useAlpha = sampled > 0 && Double(transparentSamples) / Double(sampled) > 0.06

        // Opaque checkerboard / two-tone-grey background (baked-in transparency
        // pattern): key off the checker colours directly. Unlike the flood path
        // this removes *enclosed* checker regions (the empty centre of a wreath or
        // ring) instead of filling them, and ramps to soft alpha across glow edges.
        if !useAlpha,
           let checker = detectTwoToneGrayBackground(ptr: ptr, width: width, height: height, bpr: bpr, tolerance: tolerance) {
            return try checkerKeyDetection(
                ptr: ptr, width: width, height: height, bpr: bpr,
                tolerance: tolerance, keepLargest: keepLargest,
                c0: checker.0, c1: checker.1
            )
        }

        // Step 1: background-like classification.
        var isBackground = [Bool](repeating: false, count: total)

        if useAlpha {
            for y in 0..<height {
                let row = y * bpr
                let maskRow = y * width
                for x in 0..<width {
                    isBackground[maskRow + x] = ptr[row + x * 4 + 3] < 40
                }
            }
        } else {
            // Quantise border colours (5 bits/channel) into a frequency table.
            var counts: [Int: Int] = [:]
            func quant(_ r: Int, _ g: Int, _ b: Int) -> Int {
                ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            }
            func sampleBorder(_ x: Int, _ y: Int) {
                let o = y * bpr + x * 4
                guard ptr[o + 3] > 128 else { return } // ignore transparent border pixels
                counts[quant(Int(ptr[o]), Int(ptr[o + 1]), Int(ptr[o + 2])), default: 0] += 1
            }
            for x in 0..<width { sampleBorder(x, 0); sampleBorder(x, height - 1) }
            for y in 0..<height { sampleBorder(0, y); sampleBorder(width - 1, y) }

            // Keep the most common border colours (covers a gradient's range).
            let palette: [(r: Int, g: Int, b: Int)] = counts
                .sorted { $0.value > $1.value }
                .prefix(32)
                .map { key in
                    let k = key.key
                    return (((k >> 10) & 31) << 3 | 4, ((k >> 5) & 31) << 3 | 4, (k & 31) << 3 | 4)
                }

            // Fall back to a no-op detection if the border was fully transparent.
            guard !palette.isEmpty else {
                throw PipelineError.renderFailed
            }

            let threshold = Double(tolerance) * Double(tolerance)
            for y in 0..<height {
                let row = y * bpr
                let maskRow = y * width
                for x in 0..<width {
                    let o = row + x * 4
                    // Transparent pixels are always background.
                    if ptr[o + 3] < 40 {
                        isBackground[maskRow + x] = true
                        continue
                    }
                    let r = Int(ptr[o])
                    let g = Int(ptr[o + 1])
                    let b = Int(ptr[o + 2])
                    var best = Double.greatestFiniteMagnitude
                    for c in palette {
                        let dr = Double(r - c.r)
                        let dg = Double(g - c.g)
                        let db = Double(b - c.b)
                        let dist = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                        if dist < best { best = dist; if best <= threshold { break } }
                    }
                    isBackground[maskRow + x] = best <= threshold
                }
            }
        }

        // Step 2: flood the external background inward from every border pixel.
        var isExternal = [Bool](repeating: false, count: total)
        var queue = [Int]()
        queue.reserveCapacity(total / 4)
        func enqueueExternal(_ x: Int, _ y: Int) {
            let idx = y * width + x
            if isExternal[idx] || !isBackground[idx] { return }
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

        // Step 3 + 4: subject = not external; optionally keep the largest blob.
        var keep = [Bool](repeating: false, count: total)
        if keepLargest {
            var visited = [Bool](repeating: false, count: total)
            var best = [Int]()
            var component = [Int]()
            component.reserveCapacity(4096)
            for seed in 0..<total {
                if visited[seed] || isExternal[seed] { continue }
                visited[seed] = true
                component.removeAll(keepingCapacity: true)
                component.append(seed)
                var compHead = 0
                while compHead < component.count {
                    let idx = component[compHead]; compHead += 1
                    let cx = idx % width
                    let cy = idx / width
                    for dy in -1...1 {
                        let ny = cy + dy
                        if ny < 0 || ny >= height { continue }
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            let nx = cx + dx
                            if nx < 0 || nx >= width { continue }
                            let nIdx = ny * width + nx
                            if !visited[nIdx] && !isExternal[nIdx] {
                                visited[nIdx] = true
                                component.append(nIdx)
                            }
                        }
                    }
                }
                if component.count > best.count { best = component }
            }
            for idx in best { keep[idx] = true }
        } else {
            for i in 0..<total { keep[i] = !isExternal[i] }
        }

        var alphaBuf = [UInt8](repeating: 0, count: total)
        for i in 0..<total where keep[i] { alphaBuf[i] = 255 }
        return try buildMaskResult(alphaBuf, width: width, height: height)
    }

    // MARK: - Checkerboard background keying

    /// A premultiplied-RGBA colour as scaled doubles. Channels are pre-scaled by
    /// √2, 2, √3 so plain Euclidean distance in this space equals the editor's
    /// perceptual weighting 2·dr² + 4·dg² + 3·db².
    private typealias Scaled = (Double, Double, Double)

    @inline(__always)
    private static func scaledColor(_ r: Int, _ g: Int, _ b: Int) -> Scaled {
        (Double(r) * 1.4142135623730951, Double(g) * 2.0, Double(b) * 1.7320508075688772)
    }

    /// Squared distance from point `p` to the segment `a`–`b` in scaled colour
    /// space. Using the segment (not just the endpoints) means anti-aliased pixels
    /// straddling two checker cells still read as background.
    @inline(__always)
    private static func segmentDistanceSquared(_ p: Scaled, _ a: Scaled, _ b: Scaled) -> Double {
        let abx = b.0 - a.0, aby = b.1 - a.1, abz = b.2 - a.2
        let apx = p.0 - a.0, apy = p.1 - a.1, apz = p.2 - a.2
        let denom = abx * abx + aby * aby + abz * abz
        var t = denom > 0 ? (apx * abx + apy * aby + apz * abz) / denom : 0
        if t < 0 { t = 0 } else if t > 1 { t = 1 }
        let dx = apx - abx * t, dy = apy - aby * t, dz = apz - abz * t
        return dx * dx + dy * dy + dz * dz
    }

    /// Detects an opaque checkerboard / two-tone background by finding two distinct
    /// low-saturation grey levels that together cover most of the border. Returns
    /// their colours, or nil when the border isn't two-tone grey — so flat and
    /// gradient backgrounds keep using the flood path.
    ///
    /// ponytail: heuristic only (two grey clusters covering the border), no grid
    /// periodicity check — add one if a non-checker two-grey image false-positives.
    private static func detectTwoToneGrayBackground(
        ptr: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bpr: Int, tolerance: CGFloat
    ) -> ((Int, Int, Int), (Int, Int, Int))? {
        var counts: [Int: Int] = [:]
        @inline(__always) func quant(_ r: Int, _ g: Int, _ b: Int) -> Int {
            ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
        }
        var borderOpaque = 0
        @inline(__always) func sample(_ x: Int, _ y: Int) {
            let o = y * bpr + x * 4
            guard ptr[o + 3] > 128 else { return }
            borderOpaque += 1
            counts[quant(Int(ptr[o]), Int(ptr[o + 1]), Int(ptr[o + 2])), default: 0] += 1
        }
        for x in 0..<width { sample(x, 0); sample(x, height - 1) }
        for y in 0..<height { sample(0, y); sample(width - 1, y) }
        guard borderOpaque > 0, !counts.isEmpty else { return nil }

        func decode(_ k: Int) -> (Int, Int, Int) {
            (((k >> 10) & 31) << 3 | 4, ((k >> 5) & 31) << 3 | 4, (k & 31) << 3 | 4)
        }
        @inline(__always) func isGray(_ c: (Int, Int, Int)) -> Bool {
            max(c.0, max(c.1, c.2)) - min(c.0, min(c.1, c.2)) <= 40
        }

        let ranked = counts.sorted { $0.value > $1.value }.prefix(8).map { decode($0.key) }
        guard let c0 = ranked.first, isGray(c0) else { return nil }
        let s0 = scaledColor(c0.0, c0.1, c0.2)
        // Second tone: most common grey that is a clearly different shade from c0.
        guard let c1 = ranked.dropFirst().first(where: { c in
            guard isGray(c) else { return false }
            let d = segmentDistanceSquared(scaledColor(c.0, c.1, c.2), s0, s0)
            return d >= 20 * 20 && d <= 230 * 230
        }) else { return nil }
        let s1 = scaledColor(c1.0, c1.1, c1.2)

        // Most of the border must lie on/near the c0–c1 segment to call it two-tone.
        let coverSq = (Double(tolerance) * 1.5) * (Double(tolerance) * 1.5)
        var onSegment = 0
        @inline(__always) func tally(_ x: Int, _ y: Int) {
            let o = y * bpr + x * 4
            guard ptr[o + 3] > 128 else { return }
            let p = scaledColor(Int(ptr[o]), Int(ptr[o + 1]), Int(ptr[o + 2]))
            if segmentDistanceSquared(p, s0, s1) <= coverSq { onSegment += 1 }
        }
        for x in 0..<width { tally(x, 0); tally(x, height - 1) }
        for y in 0..<height { tally(0, y); tally(width - 1, y) }
        return Double(onSegment) / Double(borderOpaque) >= 0.80 ? (c0, c1) : nil
    }

    /// Keys an opaque checkerboard background to a soft keep mask. Every pixel's
    /// distance to the c0–c1 grey segment drives its alpha: ≤ `lo` → background,
    /// ≥ `hi` → full subject, ramped between. No flood/hole-fill, so an enclosed
    /// checker centre stays transparent.
    private static func checkerKeyDetection(
        ptr: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bpr: Int,
        tolerance: CGFloat, keepLargest: Bool,
        c0: (Int, Int, Int), c1: (Int, Int, Int)
    ) throws -> ShapeDetection {
        let total = width * height
        let s0 = scaledColor(c0.0, c0.1, c0.2)
        let s1 = scaledColor(c1.0, c1.1, c1.2)

        // Key on CHROMA: perpendicular distance to the grey axis (the line through
        // the two checker shades). Both shades sit *on* that axis, so a glow blended
        // over a light cell and over a dark cell land at the same chroma → the
        // checkerboard pattern collapses to one alpha and stops leaking through as
        // visible squares. Off-axis colour (blue/cyan/pink) keys in smoothly.
        let dx = s1.0 - s0.0, dy = s1.1 - s0.1, dz = s1.2 - s0.2
        let len = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard len > 1 else { return try buildMaskResult([UInt8](repeating: 0, count: total), width: width, height: height) }
        let ux = dx / len, uy = dy / len, uz = dz / len   // unit vector along grey axis

        // The two checker shades' luminances bound the background's brightness band.
        // A pixel darker than the darker shade is a real dark outline; one inside the
        // band is checker (cut unless coloured). Luminance is absolute (not signed
        // along an arbitrarily-ordered c0→c1 axis), so it can't mistake bright glow
        // over the light cells for a dark outline — which is what painted the squares.
        let darkBound = Double(min(c0.0 + c0.1 + c0.2, c1.0 + c1.1 + c1.2)) / 3
        let briteBound = Double(max(c0.0 + c0.1 + c0.2, c1.0 + c1.1 + c1.2)) / 3

        @inline(__always) func sample(_ o: Int) -> (chroma: Double, luma: Double) {
            let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
            let p = scaledColor(r, g, b)
            let vx = p.0 - s0.0, vy = p.1 - s0.1, vz = p.2 - s0.2
            let along = vx * ux + vy * uy + vz * uz          // distance along the axis
            let px = vx - ux * along, py = vy - uy * along, pz = vz - uz * along
            return ((px * px + py * py + pz * pz).squareRoot(), Double(r + g + b) / 3)
        }

        // Auto-calibrate the chroma floor from the background's own noise: the baked
        // checker isn't perfectly neutral, so sample the border (checker for a
        // centred asset), take a high percentile of its chroma, and key only clearly
        // above it. This is what removes the faint residual checker squares that a
        // fixed threshold leaves in the glow halo.
        var borderChroma: [Double] = []
        borderChroma.reserveCapacity(2 * (width + height))
        @inline(__always) func addBorder(_ x: Int, _ y: Int) {
            let o = (y * bpr) + x * 4
            if ptr[o + 3] > 128 { borderChroma.append(sample(o).chroma) }
        }
        for x in 0..<width { addBorder(x, 0); addBorder(x, height - 1) }
        for y in 0..<height { addBorder(0, y); addBorder(width - 1, y) }
        borderChroma.sort()
        let noiseFloor = borderChroma.isEmpty ? 0 : borderChroma[min(borderChroma.count - 1, Int(Double(borderChroma.count) * 0.9))]

        // A pixel is subject if it's off the grey axis (coloured) OR clearly outside
        // the checker's luma band (a dark outline below it, a bright glow/core above
        // it); checker pixels sit on the axis inside the band and key out. Chroma
        // alone can't do this: a baked checkerboard is achromatic, so over it a soft
        // glow's chroma swings with the cell underneath and paints faint squares —
        // judging luma against the band's edges is what keeps the cut clean.
        // ponytail: no per-cell background decontamination — too fragile on an
        // imperfect AI checker; this crisp key with a feathered edge is robust.
        // Chroma ramp: ≤ lo → background, ≥ hi → subject, soft between.
        let lo = max(noiseFloor * 1.6 + 10, Double(tolerance) * 0.95)
        let hi = lo + max(Double(tolerance) * 0.35, 16)
        let span = hi - lo
        let darkMargin = Double(tolerance) * 0.5   // luma below the darker shade to read as a dark outline
        // Bright glow/core clause: keep pixels clearly brighter than the lighter
        // checker shade. A bright subject (an explosion's white-cyan core, a hot
        // highlight) is near-neutral yet far brighter than the checker, so chroma
        // alone would cut it and leave parity-modulated squares where it thins. The
        // margin is wide so only *clearly* brighter pixels key in — a faint glow only
        // a little above the checker stays chroma-judged, which keeps soft rims clean.
        let briteMargin = Double(tolerance) * 1.5

        var alpha = [UInt8](repeating: 0, count: total)
        for y in 0..<height {
            let row = y * bpr
            let dst = y * width
            for x in 0..<width {
                let o = row + x * 4
                if ptr[o + 3] < 40 { continue } // already transparent → background
                let (chroma, luma) = sample(o)
                let s: Double
                if chroma >= hi || luma < darkBound - darkMargin || luma > briteBound + briteMargin {
                    s = 1                                     // off-axis colour, or far outside the checker's luma band → subject
                } else if chroma <= lo {
                    continue                                  // checker → transparent
                } else {
                    s = (chroma - lo) / span
                }
                alpha[dst + x] = s >= 1 ? 255 : UInt8(s * 255)
            }
        }

        if keepLargest { dropDisconnectedSpecks(&alpha, width: width, height: height) }
        return try buildMaskResult(alpha, width: width, height: height)
    }

    /// Keeps every solid blob within 2% of the largest, plus the soft halo
    /// connected to it; drops isolated specks. Generalises "keep largest" so a ring
    /// made of separate shards survives while stray dust is removed.
    private static func dropDisconnectedSpecks(_ alpha: inout [UInt8], width: Int, height: Int) {
        let total = width * height
        var comp = [Int32](repeating: -1, count: total)
        var areas: [Int] = []
        var stack: [Int] = []
        for s in 0..<total where alpha[s] > 128 && comp[s] < 0 {
            let id = Int32(areas.count)
            var area = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(s); comp[s] = id
            while let idx = stack.popLast() {
                area += 1
                let cx = idx % width, cy = idx / width
                for dy in -1...1 {
                    let ny = cy + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = cx + dx
                        if nx < 0 || nx >= width { continue }
                        let n = ny * width + nx
                        if alpha[n] > 128 && comp[n] < 0 { comp[n] = id; stack.append(n) }
                    }
                }
            }
            areas.append(area)
        }
        guard let maxArea = areas.max() else { return } // no solid core: keep soft glow as-is
        let minKeep = max(Int(Double(maxArea) * 0.02), 64)

        // Flood from kept cores through any non-trivial alpha to retain glow halos.
        var visited = [Bool](repeating: false, count: total)
        var queue: [Int] = []
        for i in 0..<total where comp[i] >= 0 && areas[Int(comp[i])] >= minKeep {
            visited[i] = true; queue.append(i)
        }
        var head = 0
        while head < queue.count {
            let idx = queue[head]; head += 1
            let cx = idx % width, cy = idx / width
            for dy in -1...1 {
                let ny = cy + dy
                if ny < 0 || ny >= height { continue }
                for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let nx = cx + dx
                    if nx < 0 || nx >= width { continue }
                    let n = ny * width + nx
                    if !visited[n] && alpha[n] > 8 { visited[n] = true; queue.append(n) }
                }
            }
        }
        for i in 0..<total where !visited[i] { alpha[i] = 0 }
    }

    /// Builds the grayscale keep-mask image + bounding box from a per-pixel alpha
    /// buffer (255 = keep, 0 = drop, intermediate = soft edge). Bounding box
    /// includes faint glow (alpha > 24); pixel count is the solid core (alpha > 128).
    private static func buildMaskResult(_ alpha: [UInt8], width: Int, height: Int) throws -> ShapeDetection {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { throw PipelineError.renderFailed }
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for y in 0..<height {
            let src = y * width
            let dst = y * bpr
            for x in 0..<width {
                let v = alpha[src + x]
                ptr[dst + x] = v
                if v > 24 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                if v > 128 { count += 1 }
            }
        }
        guard let mask = ctx.makeImage() else { throw PipelineError.renderFailed }
        let bbox = maxX >= minX
            ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            : .zero
        return ShapeDetection(mask: mask, boundingBox: bbox, pixelCount: count)
    }

    /// Keeps the subject defined by `keepMask` (255 = keep, 0 = remove) and makes
    /// everything else transparent. The mask can be feathered for soft, anti-
    /// aliased cutout edges. Premultiplied channels are scaled by the keep weight,
    /// which preserves premultiplication.
    static func applyKeepMask(
        cgImage: CGImage,
        keepMask: CGImage,
        feather: CGFloat
    ) throws -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        guard keepMask.width == width, keepMask.height == height,
              let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PipelineError.renderFailed
        }

        var working = keepMask
        if feather > 0.01 {
            working = blurGrayImage(keepMask, radius: feather) ?? keepMask
        }
        guard let keepData = working.dataProvider?.data,
              let keepPtr = CFDataGetBytePtr(keepData) else { throw PipelineError.renderFailed }
        let keepBpr = working.bytesPerRow

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outData = ctx.data else { throw PipelineError.renderFailed }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bpr = ctx.bytesPerRow
        let ptr = outData.bindMemory(to: UInt8.self, capacity: height * bpr)

        for y in 0..<height {
            let row = y * bpr
            let keepRow = y * keepBpr
            for x in 0..<width {
                let keep = Int(keepPtr[keepRow + x])
                if keep >= 255 { continue }
                let off = row + x * 4
                if keep == 0 {
                    ptr[off] = 0; ptr[off + 1] = 0; ptr[off + 2] = 0; ptr[off + 3] = 0
                    continue
                }
                ptr[off]     = UInt8((Int(ptr[off])     * keep) / 255)
                ptr[off + 1] = UInt8((Int(ptr[off + 1]) * keep) / 255)
                ptr[off + 2] = UInt8((Int(ptr[off + 2]) * keep) / 255)
                ptr[off + 3] = UInt8((Int(ptr[off + 3]) * keep) / 255)
            }
        }

        guard let result = ctx.makeImage() else { throw PipelineError.renderFailed }
        return result
    }

    // MARK: - Mask refinement

    /// Grows (radius > 0, dilate) or shrinks (radius < 0, erode) a binary keep mask
    /// using a separable square structuring element. Lets the user expand or trim
    /// the whole selection by a few pixels at a time.
    static func morphMask(_ mask: CGImage, radius: Int) -> CGImage? {
        guard radius != 0 else { return mask }
        let width = mask.width
        let height = mask.height
        guard width > 0, height > 0,
              let md = mask.dataProvider?.data,
              let mp = CFDataGetBytePtr(md) else { return nil }
        let mbpr = mask.bytesPerRow

        var src = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * mbpr
            let dst = y * width
            for x in 0..<width { src[dst + x] = mp[row + x] }
        }

        let r = abs(radius)
        let dilate = radius > 0
        var temp = [UInt8](repeating: 0, count: width * height)
        var out = [UInt8](repeating: 0, count: width * height)

        // Horizontal pass.
        for y in 0..<height {
            let base = y * width
            for x in 0..<width {
                var acc: UInt8 = dilate ? 0 : 255
                let x0 = max(0, x - r)
                let x1 = min(width - 1, x + r)
                var xi = x0
                while xi <= x1 {
                    let v = src[base + xi]
                    if dilate { if v > acc { acc = v } } else if v < acc { acc = v }
                    xi += 1
                }
                temp[base + x] = acc
            }
        }
        // Vertical pass.
        for x in 0..<width {
            for y in 0..<height {
                var acc: UInt8 = dilate ? 0 : 255
                let y0 = max(0, y - r)
                let y1 = min(height - 1, y + r)
                var yi = y0
                while yi <= y1 {
                    let v = temp[yi * width + x]
                    if dilate { if v > acc { acc = v } } else if v < acc { acc = v }
                    yi += 1
                }
                out[y * width + x] = acc
            }
        }

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height)
        out.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { ptr.update(from: base, count: width * height) }
        }
        return ctx.makeImage()
    }

    /// Paints a brush stroke into a keep mask: `add` includes the painted area in
    /// the subject (white), otherwise it excludes it (black). Reuses the editor's
    /// brush rasterizer so size/shape/hardness match the rest of the app.
    static func paintShapeMask(
        mask: CGImage,
        stroke: [CGPoint],
        brushSize: CGFloat,
        brushShape: BrushShape,
        brushHardness: CGFloat,
        add: Bool
    ) throws -> CGImage {
        let width = mask.width
        let height = mask.height
        guard width > 0, height > 0,
              let md = mask.dataProvider?.data,
              let mp = CFDataGetBytePtr(md) else { throw PipelineError.renderFailed }
        let mbpr = mask.bytesPerRow

        let coverage = try rasterizeRemovalBuffer(
            width: width, height: height,
            strokes: [stroke], polygons: [],
            brushSize: brushSize, brushShape: brushShape,
            brushHardness: brushHardness, feather: 0,
            selectionMask: nil
        )
        defer { coverage.deallocate() }

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { throw PipelineError.renderFailed }
        let out = data.bindMemory(to: UInt8.self, capacity: width * height)

        for y in 0..<height {
            let mRow = y * mbpr
            let oRow = y * width
            for x in 0..<width {
                let base = Int(mp[mRow + x])
                let cov = Int(coverage[oRow + x])
                if add {
                    out[oRow + x] = UInt8(max(base, cov))
                } else {
                    out[oRow + x] = UInt8(min(base, 255 - cov))
                }
            }
        }
        return ctx.makeImage() ?? mask
    }

    /// Tight bounding box (pixel coords, top-left origin) of a binary keep mask.
    static func maskBoundingBox(_ mask: CGImage) -> CGRect {
        let width = mask.width
        let height = mask.height
        guard let d = mask.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return .zero }
        let bpr = mask.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width where p[row + x] > 24 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        return maxX >= minX
            ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            : .zero
    }

    /// Full-size red-overlay source built from a keep mask (white subject on a
    /// transparent background). Used to refresh the canvas overlay after the mask
    /// is grown/shrunk or brush-refined.
    static func keepMaskOverlay(_ mask: CGImage) -> CGImage? {
        let width = mask.width
        let height = mask.height
        guard let md = mask.dataProvider?.data, let mp = CFDataGetBytePtr(md) else { return nil }
        let mbpr = mask.bytesPerRow
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)
        memset(ptr, 0, height * bpr)
        for y in 0..<height {
            let mRow = y * mbpr
            let row = y * bpr
            for x in 0..<width {
                let v = mp[mRow + x]
                if v == 0 { continue }
                // Premultiplied white graded by keep strength → soft red preview
                // that fades across feathered/glow edges instead of a hard cutoff.
                let off = row + x * 4
                ptr[off] = v; ptr[off + 1] = v; ptr[off + 2] = v; ptr[off + 3] = v
            }
        }
        return ctx.makeImage()
    }
}
