import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Vision

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

/// The subject's detected parts as editable pen paths (normalized 0…1, top-left
/// origin). `combinedOuterPath` is the full-logo outline that encloses every part;
/// `componentPaths` are the individual parts ordered largest-first.
struct DetectedPathSet {
    let combinedOuterPath: [PolygonVertex]
    let componentPaths: [[PolygonVertex]]
}

extension ImagePipeline {
    /// Detects the main foreground shape and returns a mask that keeps the subject
    /// while dropping the surrounding background.
    ///
    /// Algorithm:
    /// 1. Classify every pixel as "background-like": transparent (when the source
    ///    already carries alpha) or close in CIELAB colour to the image border.
    ///    Border colours are sampled into a small quantised palette so smooth
    ///    gradient backgrounds are still covered — a pixel is background when its
    ///    ΔE76 distance to *any* palette entry is within `deltaEThreshold(tolerance)`.
    /// 2. Flood-fill those background pixels inward from all four borders. Only
    ///    background connected to the edge becomes "external". The flood expands in
    ///    steps (T0, then 1.5·T0, then 2.25·T0 when a `subjectPrior` is present) so a
    ///    soft vignette gradient that drifts away from the sampled border palette is
    ///    fully keyed rather than leaving a ring of "almost background" pixels.
    /// 3. The subject is everything the flood could NOT reach. This automatically
    ///    fills holes enclosed by the shape (e.g. a dark pocket inside the asset).
    ///    A `subjectPrior` is an impassable wall: its pixels are never background,
    ///    never seeded, never enqueued, so they are always kept — the flood result
    ///    is implicitly the union of the prior and the keyed subject.
    /// 4. Optionally keep only the largest connected blob, dropping stray specks.
    ///
    /// - Parameters:
    ///   - tolerance: colour-distance radius for "background-like". Larger values
    ///     eat more of a soft halo/glow; smaller values keep more of it.
    ///   - keepLargest: keep only the single biggest subject component.
    ///   - subjectPrior: optional keep-mask (255 = subject) whose pixels are
    ///     protected from keying. Used to keep dark clothing/weapons that match a
    ///     dark background.
    /// - Throws: `PipelineError.renderFailed` when no background palette survives
    ///   or the kept fraction would be ≥ 99% (near-full frame — never a cutout).
    static func detectForegroundShape(
        cgImage: CGImage,
        tolerance: CGFloat,
        keepLargest: Bool = true,
        subjectPrior: CGImage? = nil
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

        // Subject prior: an impassable wall of pixels that are never background. When
        // present it both decontaminates the border palette (dark border-touching
        // clothing can't pollute it) and protects the subject from the flood.
        let priorSubject = buildPriorSubject(subjectPrior, width: width, height: height)

        // Background-like classification. A pixel is "background-like" if it can
        // seed the flood. The opaque path keys on CIELAB ΔE to the border palette;
        // the alpha path keys on the source's own transparency (the prior is ignored
        // there — alpha is authoritative).
        var isBackground = [Bool](repeating: false, count: total)
        var dist8 = [UInt8](repeating: 0, count: total)   // per-pixel min ΔE to palette (opaque path)
        var t0 = 0.0, t1 = 0.0, t2 = 0.0

        func backgroundAt(_ x: Int, _ y: Int, threshold: Double) -> Bool {
            if useAlpha { return ptr[y * bpr + x * 4 + 3] < 40 }
            let idx = y * width + x
            if let priorSubject, priorSubject[idx] { return false } // prior = subject, never bg
            if ptr[y * bpr + x * 4 + 3] < 40 { return true }       // transparent = bg
            return Double(dist8[idx]) <= threshold
        }

        if !useAlpha {
            // Quantise border colours (5 bits/channel) into a frequency table.
            var counts: [Int: Int] = [:]
            func quant(_ r: Int, _ g: Int, _ b: Int) -> Int {
                ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            }
            func sampleBorder(_ x: Int, _ y: Int) {
                let o = y * bpr + x * 4
                guard ptr[o + 3] > 128 else { return } // ignore transparent border pixels
                // Decontamination: a prior-subject border pixel is the character
                // touching the edge, NOT background — skip it.
                if let priorSubject, priorSubject[y * width + x] { return }
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

            // Fall back to a no-op detection if the border was fully transparent
            // (or the prior covered it entirely).
            guard !palette.isEmpty else {
                throw PipelineError.renderFailed
            }

            // CIELAB keying. Precompute the sRGB→linear table once, convert the
            // palette to LAB, then one full-res pass of per-pixel min ΔE76.
            var lin = [Double](repeating: 0, count: 256)
            for i in 0..<256 {
                let c = Double(i) / 255
                lin[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let paletteLab = palette.map { sRGBtoLab($0.r, $0.g, $0.b, lin: lin) }
            for y in 0..<height {
                let row = y * bpr
                let maskRow = y * width
                for x in 0..<width {
                    let o = row + x * 4
                    if ptr[o + 3] < 40 { continue } // transparent handled below
                    let pLab = sRGBtoLab(Int(ptr[o]), Int(ptr[o + 1]), Int(ptr[o + 2]), lin: lin)
                    var best = Double.greatestFiniteMagnitude
                    for q in paletteLab {
                        let de = deltaE76(pLab, q)
                        if de < best {
                            best = de
                            if best == 0 { break }
                        }
                    }
                    dist8[maskRow + x] = UInt8(min(best, 255))
                }
            }

            // Adaptive tolerance: T0 = slider mapping; T1 expands the flood a step
            // further so soft gradient/vignette pixels that drift past the sampled
            // border colours still key; T2 (only with a prior) pushes deeper because
            // the subject is prior-protected.
            t0 = Double(deltaEThreshold(fromTolerance: tolerance))
            t1 = t0 * 1.5
            t2 = priorSubject != nil ? t0 * 2.25 : t0
        }

        for y in 0..<height {
            let maskRow = y * width
            for x in 0..<width {
                isBackground[maskRow + x] = backgroundAt(x, y, threshold: t0)
            }
        }

        // Flood the external background inward from every border seed (prior pixels
        // are never isBackground, so they can never seed).
        var isExternal = [Bool](repeating: false, count: total)
        var queue = [Int]()
        queue.reserveCapacity(total / 4)
        func enqueue(_ x: Int, _ y: Int) {
            let idx = y * width + x
            if isExternal[idx] || !isBackground[idx] { return }
            isExternal[idx] = true
            queue.append(idx)
        }
        for x in 0..<width { enqueue(x, 0); enqueue(x, height - 1) }
        for y in 0..<height { enqueue(0, y); enqueue(width - 1, y) }
        var head = 0
        while head < queue.count {
            let idx = queue[head]; head += 1
            let cx = idx % width
            let cy = idx / width
            if cx > 0 { enqueue(cx - 1, cy) }
            if cx < width - 1 { enqueue(cx + 1, cy) }
            if cy > 0 { enqueue(cx, cy - 1) }
            if cy < height - 1 { enqueue(cx, cy + 1) }
        }

        // Stepwise expansion: grow the external region through pixels whose ΔE sits
        // between the current and next threshold. Each pass re-enqueues the frontier
        // and stops when it adds nothing. No-op on the alpha path (its classification
        // is threshold-independent, so nothing new qualifies).
        func expand(to threshold: Double) {
            var frontier = [Int]()
            for i in 0..<total where isExternal[i] {
                let cx = i % width, cy = i / width
                let checks = [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                for (nx, ny) in checks where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let n = ny * width + nx
                    if !isExternal[n] && backgroundAt(nx, ny, threshold: threshold) {
                        isExternal[n] = true
                        frontier.append(n)
                    }
                }
            }
            var fh = 0
            while fh < frontier.count {
                let idx = frontier[fh]; fh += 1
                let cx = idx % width, cy = idx / width
                let checks = [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                for (nx, ny) in checks where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let n = ny * width + nx
                    if !isExternal[n] && backgroundAt(nx, ny, threshold: threshold) {
                        isExternal[n] = true
                        frontier.append(n)
                    }
                }
            }
        }
        expand(to: t1)
        if !useAlpha, priorSubject != nil { expand(to: t2) }

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

        // Near-full guard (opaque path only): a mask covering ≥99% of the frame is a
        // failed key (whole canvas is "subject"), not a cutout — the caller degrades.
        // ponytail: alpha path exempt — there the mask faithfully mirrors the source
        // alpha and the upstream isUsableSubjectMask gate rejects near-full anyway.
        if !useAlpha {
            var keptCount = 0
            for v in keep where v { keptCount += 1 }
            if Double(keptCount) / Double(total) >= 0.99 {
                throw PipelineError.renderFailed
            }
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
        // ponytail: a subject smaller than the 64px dust floor must not be wiped.
        // The floor only makes sense when something bigger exists — when the whole
        // mask is below it, keep the largest component instead of zeroing everything.
        let minKeep = maxArea < 64 ? maxArea : max(Int(Double(maxArea) * 0.02), 64)

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

    // MARK: - Subject mask (tiered degradation ladder)

    /// Keep-mask with ALL subject components (no keep-largest trimming) for the
    /// multi-candidate flow. A strict degradation ladder — "first usable tier wins":
    ///
    /// 1a. Vision `VNGenerateForegroundInstanceMaskRequest` (macOS 14+).
    /// 1b. Attention-based saliency prior (all macOS 13+).
    /// 2.  CIELAB ΔE border flood-fill, prior-informed (saliency-protected subject
    ///     cannot be eaten by a dark background that matches its colours).
    /// 3.  The raw saliency mask, when the flood produced nothing.
    /// 4.  nil — graceful failure, never a full-frame mask, never a 4-corner contour.
    ///
    /// Every tier's output passes through `refineMask` (edge recovery → binary
    /// closing → speck drop) and the uniform `isUsableSubjectMask` gate.
    static func subjectMaskAll(cgImage: CGImage, tolerance: CGFloat) -> CGImage? {
        // Step 1a — Vision subject segmentation is the strongest signal on macOS 14+.
        if #available(macOS 14.0, *) {
            if let mask = try? foregroundInstanceMask(cgImage: cgImage) {
                let refined = refineMask(mask, source: cgImage)
                if isUsableSubjectMask(refined) { return refined }
            }
        }
        // Step 1b — saliency prior. Not returned directly yet; it feeds the flood.
        let prior = saliencySubjectMask(cgImage: cgImage)
        // Step 2 — LAB ΔE flood with the prior as an impassable subject wall.
        if let detection = try? detectForegroundShape(
            cgImage: cgImage, tolerance: tolerance, keepLargest: false, subjectPrior: prior
        ), detection.pixelCount > 0 {
            let refined = refineMask(detection.mask, source: cgImage)
            if isUsableSubjectMask(refined) { return refined }
        }
        // Step 2a — local Otsu on the central region. Catches starburst flares
        // whose rays touch the border (flood collapses full-frame), plus emissive
        // VFX where luminance thresholding isolates the core where the flood can't.
        if let local = localOtsuMask(cgImage: cgImage) {
            let refined = refineMask(local, source: cgImage)
            if isUsableSubjectMask(refined) { return refined }
        }
        // Step 3 — saliency alone (flood threw or emptied, e.g. the prior covered
        // the entire border so no background palette survived).
        if let prior {
            let refined = refineMask(prior, source: cgImage)
            if isUsableSubjectMask(refined) { return refined }
        }
        // Step 4 — nothing usable: nil, and the caller reports it. A full-frame
        // mask or 4-corner outline is NEVER emitted from this ladder.
        return nil
    }

    /// Vision `VNGenerateForegroundInstanceMaskRequest` output, converted into the
    /// app's keep-mask convention (255 = subject). Vision's learned model segments
    /// photographic content well but often returns the whole canvas as one instance
    /// for flat game assets — a degenerate case we detect and drop in favour of the
    /// flood-fill fallback. `nil` when the model found nothing usable.
    ///
    /// Layout notes (verified empirically): the returned CVPixelBuffer is
    /// `kCVPixelFormatType_OneComponent8` but not byte-per-pixel addressable, so it
    /// is rendered through CIContext into an RGBA8 CGImage whose R channel carries
    /// the luminance: 0 = subject, 255 = background. Invert for keep-mask polarity.
    /// The render is top-left origin, matching the source image and the app's mask
    /// convention — no vertical flip.
    @available(macOS 14.0, *)
    static func foregroundInstanceMask(cgImage: CGImage) throws -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }

        let index = IndexSet(integersIn: 0..<obs.allInstances.count)
        let buffer = try obs.generateScaledMaskForImage(forInstances: index, from: handler)
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return nil }

        let ci = CIImage(cvPixelBuffer: buffer)
        // Reuse the pipeline's single CIContext — it is thread-safe, and a fresh
        // one per call wastes a GPU/Metal stack.
        guard let rendered = ImagePipeline.context.createCGImage(
            ci, from: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ), let d = rendered.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }

        let bpr = rendered.bytesPerRow
        // Threshold so the soft feathered boundary becomes a crisp binary keep-mask,
        // then scan for a usable subject ratio (1%–99% keeps Vision's output).
        var kept = 0
        for y in 0..<h {
            let row = y * bpr
            for x in 0..<w where p[row + x * 4] < 128 { kept += 1 } // 0 luminance = subject
        }
        let total = w * h
        let ratio = Double(kept) / Double(total)
        guard ratio > 0.01, ratio < 0.99 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let out = ctx.data else { return nil }
        let outBpr = ctx.bytesPerRow
        let dst = out.bindMemory(to: UInt8.self, capacity: h * outBpr)
        for y in 0..<h {
            let row = y * bpr
            let dRow = y * outBpr
            for x in 0..<w {
                dst[dRow + x] = p[row + x * 4] < 128 ? 255 : 0
            }
        }
        return ctx.makeImage()
    }

    // MARK: - Saliency subject prior (Vision attention map)

    /// Converts a source image into a binary "subject prior" keep-mask using
    /// `VNGenerateAttentionBasedSaliencyImageRequest` (macOS 10.13+ — always
    /// available on the 13.0 minimum): the attention heat map is Otsu-thresholded,
    /// the largest central component is kept, and the result is upscaled to source
    /// resolution. Returns nil on flat assets / uniform attention (the kept-fraction
    /// gates reject them) — a caller treats nil as "no prior".
    static func saliencySubjectMask(cgImage: CGImage) -> CGImage? {
        let small = ImagePipeline.downscale(cgImage, maxEdge: 512)
        guard let luminance = saliencyMapLuminance(cgImage: small) else { return nil }
        guard let smallMask = saliencySubjectMask(luminance: luminance) else { return nil }
        // Nearest-neighbor upscale of the binary mask to full size — shape-lossless.
        return upscaleBinaryMask(smallMask, toWidth: cgImage.width, height: cgImage.height)
    }

    /// Attention heat map of `cgImage` as a grayscale CGImage (bright = salient),
    /// same size as the input. Renders the Vision `pixelBuffer` (inherited from
    /// `VNPixelBufferObservation`) through the pipeline's shared CIContext. Returns
    /// nil on any failure — Vision saliency is best-effort.
    private static func saliencyMapLuminance(cgImage: CGImage) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNSaliencyImageObservation else { return nil }
        let buffer = obs.pixelBuffer
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let rendered = ImagePipeline.context.createCGImage(
            ci, from: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { return nil }
        return rendered
    }

    /// Pure, Vision-free binarization of a saliency luminance buffer into a subject
    /// keep-mask (255 = subject; HIGH saliency = subject). Reads the R channel of an
    /// RGBA image (or the byte of a grayscale one), applies an optional vertical
    /// flip (orientation escape hatch), Otsu-thresholds, keeps the largest central
    /// component, and gates the kept fraction to a sane range. Returns nil when the
    /// map is empty or covers (almost) the whole frame.
    static func saliencySubjectMask(luminance: CGImage, flipY: Bool = false) -> CGImage? {
        let width = luminance.width
        let height = luminance.height
        guard width > 1, height > 1,
              let d = luminance.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        let bpr = luminance.bytesPerRow
        let hasAlpha = luminance.alphaInfo != .none
        let total = width * height

        var hist = [Int](repeating: 0, count: 256)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width {
                let off = row + x * (hasAlpha ? 4 : 1)
                let v = Int(p[off])
                hist[min(max(v, 0), 255)] += 1
            }
        }
        let t = otsuThreshold(histogram: hist, total: total)
        var subject = [Bool](repeating: false, count: total)
        for y in 0..<height {
            let row = y * bpr
            let sy = flipY ? (height - 1 - y) : y
            for x in 0..<width {
                let off = row + x * (hasAlpha ? 4 : 1)
                let v = Int(p[off])
                // Strictly-above: Otsu's class-2 is the salient minority. The
                // threshold lands on a histogram mode, so v >= t would keep the
                // whole frame when Otsu picks t = 0 for a bright-spot-on-dark map.
                subject[sy * width + x] = v > t
            }
        }
        var keptCount = 0
        for v in subject where v { keptCount += 1 }
        let fraction = Double(keptCount) / Double(total)
        guard fraction > 0.01, fraction < 0.98 else { return nil }

        // Largest central component: prefer a component whose centroid sits inside
        // the central 50% box, else the globally largest one.
        let minArea = max(16, total / 600)
        let components = connectedComponents(fg: subject, width: width, height: height, minArea: minArea)
        guard !components.isEmpty else { return nil }
        let cxLo = width / 4, cxHi = (3 * width) / 4
        let cyLo = height / 4, cyHi = (3 * height) / 4
        let central = components.first { comp -> Bool in
            var sx = 0, sy = 0
            for i in comp { sx += i % width; sy += i / width }
            let cx = sx / comp.count, cy = sy / comp.count
            return cx >= cxLo && cx <= cxHi && cy >= cyLo && cy <= cyHi
        } ?? components[0]
        let compFraction = Double(central.count) / Double(total)
        guard compFraction > 0.01, compFraction < 0.98 else { return nil }

        var keep = [UInt8](repeating: 0, count: total)
        for i in central { keep[i] = 255 }
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { return nil }
        let dst = data.bindMemory(to: UInt8.self, capacity: total)
        for i in 0..<total { dst[i] = keep[i] }
        return ctx.makeImage()
    }

    /// Nearest-neighbor upscale of a small binary keep-mask to `toWidth × height`.
    /// Binary masks are shape-lossless under NN upscale (no smoothing to invent).
    private static func upscaleBinaryMask(_ mask: CGImage, toWidth: Int, height: Int) -> CGImage? {
        let sw = mask.width, sh = mask.height
        guard sw > 0, sh > 0, toWidth >= sw, height >= sh,
              let d = mask.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return mask }
        let bpr = mask.bytesPerRow
        guard let ctx = CGContext(
            data: nil, width: toWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: toWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { return mask }
        let dst = data.bindMemory(to: UInt8.self, capacity: toWidth * height)
        for y in 0..<height {
            let sy = min(sh - 1, (y * sh) / height)
            for x in 0..<toWidth {
                let sx = min(sw - 1, (x * sw) / toWidth)
                dst[y * toWidth + x] = p[sy * bpr + sx]
            }
        }
        return ctx.makeImage()
    }

    // MARK: - Shared image statistics (Otsu, CIELAB, usability)

    /// Otsu threshold (argmax between-class variance) over a 0…255 histogram.
    /// Class 1 = values ≤ t. Returns 128 for a degenerate (empty or single-valued)
    /// histogram — callers' kept-fraction gates reject such output anyway.
    static func otsuThreshold(histogram: [Int], total: Int) -> Int {
        guard total > 0, histogram.count == 256 else { return 128 }
        var sum = 0
        for (i, c) in histogram.enumerated() { sum += i * c }
        var sumB = 0
        var wB = 0
        var bestT = 128
        var bestVar = -1.0
        for t in 0...255 {
            let wF = histogram[t]
            if wF == 0 { continue }
            wB += wF
            sumB += t * wF
            let wFCount = total - wB
            if wB == 0 || wFCount == 0 { continue }
            let muB = Double(sumB) / Double(wB)
            let muF = Double(sum - sumB) / Double(wFCount)
            let variance = Double(wB) * Double(wFCount) * (muB - muF) * (muB - muF)
            if variance > bestVar { bestVar = variance; bestT = t }
        }
        return bestVar >= 0 ? bestT : 128
    }

    /// Slider tolerance → CIELAB ΔE keying threshold. The old weighted-RGB threshold
    /// (tolerance² in 2dr²+4dg²+3db²) was direction-dependent — roughly ΔE 8
    /// achromatic to ΔE 35 chromatic at the default 60. 0.375 lands on the midpoint
    /// (ΔE 22.5 at default) so the slider's default keeps equivalent behavior while
    /// the range stays meaningful. Floor 4.0 keeps the slider from ever being a
    /// no-op key.
    static func deltaEThreshold(fromTolerance tolerance: CGFloat) -> CGFloat {
        max(4.0, tolerance * 0.375)
    }

    /// sRGB (0…255) → CIELAB (D65), using the shared sRGB→linear table.
    private static func sRGBtoLab(_ r: Int, _ g: Int, _ b: Int, lin: [Double]) -> (l: Double, a: Double, b: Double) {
        let rl = lin[min(max(r, 0), 255)]
        let gl = lin[min(max(g, 0), 255)]
        let bl = lin[min(max(b, 0), 255)]
        let x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        let fy = f(y / yn)
        let l = 116 * fy - 16
        let a = 500 * (f(x / xn) - fy)
        let b = 200 * (fy - f(z / zn))
        return (l, a, b)
    }

    /// CIEDE2000 is overkill; ΔE76 (Euclidean in LAB) is the perceptual key.
    private static func deltaE76(_ p: (Double, Double, Double), _ q: (Double, Double, Double)) -> Double {
        let dl = p.0 - q.0, da = p.1 - q.1, db = p.2 - q.2
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// Expands a (possibly downscaled) subject prior to a full-resolution [Bool]
    /// keep set. A 3×3 max-window upscale acts as a one-prior-pixel dilation so thin
    /// border-touching parts (hair, a staff tip) are never missed. Returns nil when
    /// the prior is absent or unreadable — the caller treats it as "no prior".
    static func buildPriorSubject(_ prior: CGImage?, width: Int, height: Int) -> [Bool]? {
        guard let prior, prior.width > 0, prior.height > 0,
              let d = prior.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        let pw = prior.width, ph = prior.height, pbpr = prior.bytesPerRow
        var out = [Bool](repeating: false, count: width * height)
        // The 3x3 max-window below doubles as a one-prior-pixel dilation in the
        // same-size case (the live flow), so thin border-touching parts the prior
        // only partially covers stay protected instead of being flood-eaten.
        for y in 0..<height {
            let by = min(ph - 1, (y * ph) / height)
            let y0 = max(0, by - 1), y1 = min(ph - 1, by + 1)
            for x in 0..<width {
                let bx = min(pw - 1, (x * pw) / width)
                let x0 = max(0, bx - 1), x1 = min(pw - 1, bx + 1)
                var hit = false
                for yy in y0...y1 {
                    let row = yy * pbpr
                    for xx in x0...x1 where p[row + xx] > 127 { hit = true; break }
                    if hit { break }
                }
                if hit { out[y * width + x] = true }
            }
        }
        return out
    }

    /// Uniform gate for a tier's output: the kept fraction (bytes > 127) must be in
    /// (minRatio, maxRatio) — rejects both empty masks and near-full-frame masks, so
    /// no branch of the ladder can ever emit a full-frame outline.
    static func isUsableSubjectMask(_ mask: CGImage, minRatio: Double = 0.01, maxRatio: Double = 0.99) -> Bool {
        let w = mask.width, h = mask.height
        guard w > 0, h > 0, let d = mask.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return false }
        let bpr = mask.bytesPerRow
        var kept = 0
        for y in 0..<h {
            let row = y * bpr
            for x in 0..<w where p[row + x] > 127 { kept += 1 }
        }
        let ratio = Double(kept) / Double(w * h)
        return ratio > minRatio && ratio < maxRatio
    }

    // MARK: - Morphological & Sobel refinement (Tier 3)

    /// Box dilation (radius r → (2r+1)² window, circular mask dx²+dy² ≤ r²). OOB = 0
    /// (background), so the mask never grows past the frame. r=1 is 8-connectivity,
    /// matching `connectedComponents`.
    static func binaryDilate(_ inBuf: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        let total = width * height
        var out = [UInt8](repeating: 0, count: total)
        guard radius >= 0 else { return inBuf }
        if radius == 0 { return inBuf }
        let r2 = radius * radius
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                var hit = false
                for yy in y0...y1 {
                    let dy = yy - y
                    let row = yy * width
                    for xx in x0...x1 {
                        let dx = xx - x
                        if dx * dx + dy * dy <= r2 && inBuf[row + xx] > 127 { hit = true; break }
                    }
                    if hit { break }
                }
                if hit { out[y * width + x] = 255 }
            }
        }
        return out
    }

    /// Box erosion — the inverse of `binaryDilate` with the same kernel.
    static func binaryErode(_ inBuf: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        let total = width * height
        var out = [UInt8](repeating: 0, count: total)
        guard radius >= 0 else { return inBuf }
        if radius == 0 { return inBuf }
        let r2 = radius * radius
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                var hit = true
                for yy in y0...y1 {
                    let dy = yy - y
                    let row = yy * width
                    for xx in x0...x1 {
                        let dx = xx - x
                        if dx * dx + dy * dy <= r2 && inBuf[row + xx] <= 127 { hit = false; break }
                    }
                    if !hit { break }
                }
                if hit { out[y * width + x] = 255 }
            }
        }
        return out
    }

    /// Morphological closing = dilation then erosion. Closes sub-2r interior seams
    /// (arm–torso) without moving the outer silhouette.
    static func binaryClose(_ inBuf: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        binaryErode(binaryDilate(inBuf, width: width, height: height, radius: radius),
                    width: width, height: height, radius: radius)
    }

    /// Sobel gradient magnitude on the source's Rec.601 luminance, row-major [Float]
    /// (0 at the frame border). Strong edges are where a character silhouette really
    /// lives — used to re-attach thin strands the flood ate.
    private static func sobelMagnitude(rgba: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bpr: Int) -> [Float] {
        let total = width * height
        var lum = [UInt8](repeating: 0, count: total)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width {
                let o = row + x * 4
                let r = Int(rgba[o]), g = Int(rgba[o + 1]), b = Int(rgba[o + 2])
                lum[y * width + x] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
            }
        }
        var mag = [Float](repeating: 0, count: total)
        for y in 1..<(height - 1) {
            let r = y * width
            let r0 = r - width, r2 = r + width
            for x in 1..<(width - 1) {
                let tl = Int(lum[r0 + x - 1]), tm = Int(lum[r0 + x]), tr = Int(lum[r0 + x + 1])
                let ml = Int(lum[r + x - 1]), mr = Int(lum[r + x + 1])
                let bl = Int(lum[r2 + x - 1]), bm = Int(lum[r2 + x]), br = Int(lum[r2 + x + 1])
                let gx = Float(tr + 2 * mr + br - tl - 2 * ml - bl)
                let gy = Float(bl + 2 * bm + br - tl - 2 * tm - tr)
                mag[r + x] = (gx * gx + gy * gy).squareRoot()
            }
        }
        return mag
    }

    /// Re-attaches the outermost ring of a mask onto strong edges: each iteration
    /// sets a background pixel to subject iff it is a strong-edge pixel 4-adjacent to
    /// a current subject pixel. Re-snapshots each iteration, so a 1-iteration pass
    /// recovers the exact 1px outer ring without drifting the bounding box.
    private static func edgeAnchoredRecover(mask: [UInt8], edge: [Bool], width: Int, height: Int, iters: Int) -> [UInt8] {
        var out = mask
        for _ in 0..<iters {
            let snap = out
            var changed = false
            for y in 0..<height {
                let r = y * width
                for x in 0..<width {
                    let idx = r + x
                    if snap[idx] > 127 || !edge[idx] { continue }
                    let adjacent = (x > 0 && snap[idx - 1] > 127)
                        || (x < width - 1 && snap[idx + 1] > 127)
                        || (y > 0 && snap[idx - width] > 127)
                        || (y < height - 1 && snap[idx + width] > 127)
                    if adjacent { out[idx] = 255; changed = true }
                }
            }
            if !changed { break }
        }
        return out
    }

    /// Uniform post-processing for whatever mask wins the ladder: Sobel edge-anchored
    /// recovery → morphological closing → speck drop → rebuild. Every step degrades
    /// gracefully (a failure keeps the previous buffer), so this never fails on a
    /// valid input. Returns the (possibly unchanged) mask.
    private static func refineMask(_ mask: CGImage, source: CGImage) -> CGImage {
        guard let d = mask.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return mask }
        let width = mask.width, height = mask.height
        let bpr = mask.bytesPerRow
        let total = width * height
        var buf = [UInt8](repeating: 0, count: total)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width { buf[y * width + x] = p[row + x] }
        }

        // 1. Edge-anchored recovery: pull the outer ring back onto crisp silhouette
        //    edges (hair strands, thin clothing lines) that keying dropped.
        if let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            // Draw the source into a full-res RGBA context (it may be a different
            // size to the mask) then read luminance for the Sobel pass.
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let rgba = ctx.data {
                let srcBpr = ctx.bytesPerRow
                let srcPtr = rgba.bindMemory(to: UInt8.self, capacity: height * srcBpr)
                let mag = sobelMagnitude(rgba: srcPtr, width: width, height: height, bpr: srcBpr)
                // Adaptive edge threshold: Otsu on a coarse magnitude histogram, with
                // a floor so flat backgrounds never count as edges.
                var hist = [Int](repeating: 0, count: 256)
                var mTotal = 0
                for m in mag where m > 0 {
                    hist[min(Int(m / 6.0), 255)] += 1
                    mTotal += 1
                }
                let tau = max(otsuThreshold(histogram: hist, total: mTotal) * 6, 32)
                var edge = [Bool](repeating: false, count: total)
                for i in 0..<total where mag[i] >= Float(tau) { edge[i] = true }
                buf = edgeAnchoredRecover(mask: buf, edge: edge, width: width, height: height, iters: 1)
            }
        }

        // 2. Morphological closing — closes the dominant 1–2px anti-aliased seam
        //    (arm–torso) while the capped radius (≤2) can never merge characters a
        //    real gap apart.
        let closeRadius = max(1, min(2, Int(sqrt(CGFloat(max(width, height))) / 24.0)))
        buf = binaryClose(buf, width: width, height: height, radius: closeRadius)

        // 3. Drop isolated specks (reuses the existing checkerboard helper).
        dropDisconnectedSpecks(&buf, width: width, height: height)

        guard let rebuilt = try? buildMaskResult(buf, width: width, height: height) else { return mask }
        return rebuilt.mask
    }

    // MARK: - Contour extraction & simplification

    /// Ordered boundary of the largest connected subject region in a keep mask, as
    /// pixel-space points (top-left origin). Each point is a foreground pixel
    /// touching background (Moore-neighbour trace). The mask is thresholded at 128.
    static func contourPoints(from mask: CGImage) -> [CGPoint] {
        let width = mask.width
        let height = mask.height
        guard width > 1, height > 1,
              let d = mask.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return [] }
        let bpr = mask.bytesPerRow
        let total = width * height
        var fg = [Bool](repeating: false, count: total)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width where p[row + x] > 127 { fg[y * width + x] = true }
        }
        return contourPoints(fromFG: fg, width: width, height: height)
    }

    /// Same as `contourPoints(from:)` but over a precomputed boolean mask.
    private static func contourPoints(fromFG fg: [Bool], width: Int, height: Int) -> [CGPoint] {
        let total = width * height
        var subjectCount = 0
        for v in fg where v { subjectCount += 1 }
        // Degenerate: subject is (practically) the whole canvas — a failed key, not a
        // cutout. A 4-corner full-frame rectangle is NEVER a valid contour, so return
        // empty and let the caller degrade (report, try a lower tier, show nothing).
        if subjectCount >= Int(Double(total) * 0.99) {
            return []
        }
        guard let largest = largestComponent(fg: fg, width: width, height: height),
              largest.count > 0 else { return [] }

        func isFg(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && largest[y * width + x]
        }

        // Corner-space boundary edges: pixel (x,y) occupies corners (x,y)…(x+1,y+1).
        // A side is on the boundary when the pixel across it is background. Sides
        // are directed clockwise in y-down space (top E, right S, bottom W, left N),
        // so following `next` walks a closed loop. Each corner keeps one outgoing
        // edge (last write wins).
        // ponytail: two foreground pixels meeting only at a point (checkerboard
        // corner) fold into a single outgoing arc — the loop stays closed, the
        // notch just loses a pixel of detail. Hand-verified on L-shape notches and
        // vertical bars; outer-loop selection by largest |shoelace area| is robust
        // to the resulting tiny artifacts.
        let cw = width + 1, ch = height + 1
        var next = [Int](repeating: -1, count: cw * ch)
        func ci(_ x: Int, _ y: Int) -> Int { y * cw + x }
        for y in 0..<height {
            for x in 0..<width where largest[y * width + x] {
                if !isFg(x, y - 1) { next[ci(x, y)] = ci(x + 1, y) }            // top E
                if !isFg(x, y + 1) { next[ci(x + 1, y + 1)] = ci(x, y + 1) }    // bottom W
                if !isFg(x - 1, y) { next[ci(x, y + 1)] = ci(x, y) }            // left N
                if !isFg(x + 1, y) { next[ci(x + 1, y)] = ci(x + 1, y + 1) }    // right S
            }
        }

        // Walk every cycle (consuming edges as we go) and keep the one with the
        // largest |shoelace area| — the outer boundary; hole loops wind the other
        // way and are smaller.
        var best: [(Int, Int)] = []
        var bestArea: CGFloat = 0
        for start in next.indices where next[start] != -1 {
            var loop: [(Int, Int)] = []
            var c = start
            while true {
                loop.append((c % cw, c / cw))
                let n = next[c]
                next[c] = -1 // consume so each edge is walked once
                if n == start || n == -1 { break }
                c = n
            }
            var area: CGFloat = 0
            for i in 0..<loop.count {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                area += CGFloat(a.0) * CGFloat(b.1) - CGFloat(b.0) * CGFloat(a.1)
            }
            if abs(area) > bestArea { bestArea = abs(area); best = loop }
        }
        // Fix A: reject by EXTENT, not just pixel count. A hollow border ring/frame
        // has tiny AREA but full-frame extent — its largest loop is the canvas
        // rectangle, which RDP collapses straight back into the forbidden 4-corner
        // full-frame outline. Detect it by: the loop spans the whole canvas AND the
        // subject hugs the canvas perimeter (a real silhouette that fills the frame
        // keeps most of its pixels off the edge). The shoelace area itself is not a
        // reliable coverage measure — the boundary walk can wind, inflating it.
        if best.isEmpty { return [] }
        var bMinX = width, bMinY = height, bMaxX = 0, bMaxY = 0
        for (px, py) in best {
            bMinX = min(bMinX, px); bMinY = min(bMinY, py)
            bMaxX = max(bMaxX, px); bMaxY = max(bMaxY, py)
        }
        if bMinX == 0 && bMinY == 0 && bMaxX == width && bMaxY == height {
            var edgePixels = 0
            for y in 0..<height {
                let row = y * width
                for x in 0..<width where largest[row + x] {
                    if x == 0 || x == width - 1 || y == 0 || y == height - 1 { edgePixels += 1 }
                }
            }
            if Double(edgePixels) * 2 >= Double(subjectCount) {
                return []
            }
        }
        guard best.count >= 3 else { return [] }
        return best.map { CGPoint(x: CGFloat($0.0), y: CGFloat($0.1)) }
    }

    /// Marks the single largest 8-connected foreground component.
    private static func largestComponent(fg: [Bool], width: Int, height: Int) -> [Bool]? {
        guard let biggest = connectedComponents(fg: fg, width: width, height: height, minArea: 1).first else {
            return nil
        }
        var marks = [Bool](repeating: false, count: fg.count)
        for i in biggest { marks[i] = true }
        return marks
    }

    /// All 8-connected foreground components as `[Int]` row-major pixel indices,
    /// largest first, dropping any component smaller than `minArea`.
    private static func connectedComponents(fg: [Bool], width: Int, height: Int, minArea: Int) -> [[Int]] {
        let total = fg.count
        var visited = [Bool](repeating: false, count: total)
        var components: [[Int]] = []
        var stack: [Int] = []
        for seed in fg.indices where fg[seed] && !visited[seed] {
            visited[seed] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            var head = 0
            while head < stack.count {
                let idx = stack[head]
                head += 1
                let cx = idx % width, cy = idx / width
                for dy in -1...1 {
                    let ny = cy + dy
                    guard ny >= 0 && ny < height else { continue }
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = cx + dx
                        guard nx >= 0 && nx < width else { continue }
                        let n = ny * width + nx
                        if fg[n] && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            if stack.count >= minArea { components.append(stack) }
        }
        return components.sorted { $0.count > $1.count }
    }

    /// Ramer–Douglas–Peucker on an open polyline (keeps both endpoints).
    static func rdpSimplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let a = points[0], b = points[points.count - 1]
        var maxDist: CGFloat = 0
        var idx = 0
        for i in 1..<(points.count - 1) {
            let d = pointLineDistance(points[i], a, b)
            if d > maxDist { maxDist = d; idx = i }
        }
        guard maxDist > epsilon else { return [a, b] }
        let left = rdpSimplify(Array(points[0...idx]), epsilon: epsilon)
        let right = rdpSimplify(Array(points[idx...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    /// RDP for a closed ring: split at the pair of most-distant points, simplify
    /// each half as an open polyline, then join back into one closed loop.
    static func rdpSimplifyClosed(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        let n = points.count
        guard n > 3 else { return points }
        var farIdx = 0
        var farDist: CGFloat = -1
        for i in 1..<n {
            let d = (points[i].x - points[0].x) * (points[i].x - points[0].x)
                + (points[i].y - points[0].y) * (points[i].y - points[0].y)
            if d > farDist { farDist = d; farIdx = i }
        }
        guard farDist > 0.25 else { return points } // degenerate: all points coincide
        let a = rdpSimplify(Array(points[0...farIdx]), epsilon: epsilon)
        let b = rdpSimplify(Array(points[farIdx...n - 1]) + [points[0]], epsilon: epsilon)
        var ring = a.dropLast() + b
        ring.removeLast() // b's trailing copy of points[0] duplicates a[0]
        return Array(ring)
    }

    private static func pointLineDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return sqrt((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)) }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        let cx = a.x + t * dx, cy = a.y + t * dy
        return sqrt((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy))
    }

    /// Simplifies a mask's boundary to `maxPoints` (or fewer): runs RDP with an
    /// ever-growing tolerance until the budget is met, so simple shapes collapse to
    /// their corners while complex silhouettes keep more detail. Returns normalized
    /// points (0…1, top-left origin) ready for pen-vertex anchors.
    static func simplifiedPenContour(from mask: CGImage, maxPoints: Int) -> [CGPoint] {
        let width = mask.width
        let height = mask.height
        let pts = contourPoints(from: mask)
        guard !pts.isEmpty else { return [] }
        return simplifyRing(pts, maxPoints: maxPoints, width: width, height: height)
    }

    /// RDP-simplifies a closed pixel-space ring down to `maxPoints` (or fewer) and
    /// normalizes to 0…1. Shared budget loop behind `simplifiedPenContour` and the
    /// multi-candidate extractor.
    private static func simplifyRing(_ ring: [CGPoint], maxPoints: Int, width: Int, height: Int) -> [CGPoint] {
        var pts = ring
        if pts.count > maxPoints {
            // Dynamic RDP tolerance: scale with canvas size so a 1000px silhouette
            // keeps real contour detail (ε 3px) while a 200px one still smooths
            // (ε 0.6px → floored to 1). Never over-simplify into a box.
            var epsilon: CGFloat = max(CGFloat(max(width, height)) * 0.003, 1.0)
            var guardCount = 0
            while pts.count > maxPoints && guardCount < 30 {
                pts = rdpSimplifyClosed(pts, epsilon: epsilon)
                epsilon *= 1.5
                guardCount += 1
            }
        }
        // RDP over two open halves can collapse a thin ring (a 1px blade, a hair
        // strand) to a 2-point chord — not a closed outline, and penPathSet would
        // silently drop the part. A solid ring's raw boundary always has >= 4 points,
        // so fall back to an even sample of it (still within the point budget).
        if pts.count < 3, ring.count >= 4 {
            let k = max(3, min(maxPoints, ring.count))
            let step = CGFloat(ring.count) / CGFloat(k)
            pts = (0..<k).map { ring[Int(CGFloat($0) * step)] }
        }
        let w = CGFloat(width), h = CGFloat(height)
        return pts.map { CGPoint(x: $0.x / w, y: $0.y / h) }
    }

    /// Convex hull (monotone chain) of a point set, counter-clockwise. Returns nil
    /// for fewer than 3 distinct points.
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint]? {
        let pts = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard pts.count >= 3 else { return nil }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        return hull.count >= 3 ? hull : nil
    }

    // MARK: - Multi-candidate path detection

    /// Detects every connected subject component and returns it as a candidate pen
    /// path, plus a combined full-logo outline. Candidate order:
    /// 1. Combined outer path — the single component's own outline when there is
    ///    only one (keeps its concavity), otherwise the convex hull of every
    ///    component's boundary.
    /// 2…n. Individual components, largest area first.
    ///
    /// Runs the subject detector (Vision on macOS 14+, else the border flood-fill)
    /// then extracts the parts. Returns nil when nothing usable is detected.
    static func detectPenPathSet(cgImage: CGImage, tolerance: CGFloat) -> DetectedPathSet? {
        guard let mask = subjectMaskAll(cgImage: cgImage, tolerance: tolerance) else { return nil }
        return penPathSet(fromMask: mask)
    }

    /// Multi-contour extraction over an already-computed keep mask. Split out from
    /// `detectPenPathSet` so tests can feed a deterministic flood-fill mask instead
    /// of Vision's learned (and sometimes surprising) subject segmentation.
    static func penPathSet(fromMask mask: CGImage) -> DetectedPathSet? {
        let width = mask.width
        let height = mask.height
        guard width > 1, height > 1,
              let d = mask.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        let bpr = mask.bytesPerRow
        let total = width * height
        var fg = [Bool](repeating: false, count: total)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width where p[row + x] > 127 { fg[y * width + x] = true }
        }

        // Drop specks too small to be a real part (also keeps the candidate list sane).
        let minArea = max(16, total / 600)
        let components = connectedComponents(fg: fg, width: width, height: height, minArea: minArea)
        guard !components.isEmpty else { return nil }

        var componentPaths: [[PolygonVertex]] = []
        var boundaryPoints: [CGPoint] = []
        for component in components {
            var sub = [Bool](repeating: false, count: total)
            for idx in component { sub[idx] = true }
            let ring = contourPoints(fromFG: sub, width: width, height: height)
            guard ring.count >= 3 else { continue }
            let normalized = simplifyRing(ring, maxPoints: 80, width: width, height: height)
            guard normalized.count >= 3 else { continue }
            // Only a usable component contributes to the combined hull, so the
            // "Full Logo" outline never encloses a region with no selectable part.
            boundaryPoints.append(contentsOf: ring)
            componentPaths.append(normalized.map { PolygonVertex(anchor: $0, controlIn: nil, controlOut: nil) })
        }
        guard !componentPaths.isEmpty else { return nil }

        let combined: [PolygonVertex]
        if componentPaths.count == 1 {
            combined = componentPaths[0]
        } else if let hull = convexHull(boundaryPoints), hull.count >= 3 {
            let normalized = simplifyRing(hull, maxPoints: 80, width: width, height: height)
            combined = normalized.map { PolygonVertex(anchor: $0, controlIn: nil, controlOut: nil) }
        } else {
            combined = componentPaths[0]
        }

        return DetectedPathSet(combinedOuterPath: combined, componentPaths: componentPaths)
    }

    // MARK: - Game Asset & VFX Contour Engine

    /// Generates 3 candidate pen paths for game assets, VFX flares, glowing icons,
    /// and translucent shapes:
    ///   1. Core object contour (tight) — the solid emissive centre.
    ///   2. Outer glow / aura path — encloses the full soft glow / translucent edge.
    ///   3. Smooth convex hull — encloses all spikes, wing tips, and flare points.
    ///
    /// For transparent PNGs the candidates come from alpha-only extraction; for
    /// opaque glow images the existing subject mask is reused with radial luminance
    /// falloff to locate the solid core. Returns nil when no usable 3-candidate set
    /// can be produced.
    static func detectGameAssetVFXPaths(cgImage: CGImage, tolerance: CGFloat) -> [[PolygonVertex]]? {
        let width = cgImage.width, height = cgImage.height
        guard width > 1, height > 1 else { return nil }

        // Alpha asset path — the alpha channel is authoritative.
        if hasSignificantAlpha(cgImage) { return alphaVFXPaths(cgImage: cgImage) }

        // Opaque path: reuse the existing subject detection and generate 3 candidates.
        guard let mask = subjectMaskAll(cgImage: cgImage, tolerance: tolerance) else { return nil }
        let w = mask.width, h = mask.height
        guard w > 1, h > 1 else { return nil }

        // Candidate 2: outer glow = the mask contour itself.
        let glowRing = contourPoints(from: mask)
        guard glowRing.count >= 3 else { return nil }
        let glowPath = simplifyRing(glowRing, maxPoints: 80, width: w, height: h)
        guard glowPath.count >= 3 else { return nil }

        // Candidate 1: core via radial luminance falloff, or erosion fallback.
        let coreRing = radialLuminanceCore(source: cgImage, subjectMask: mask, outerGlowRing: glowRing)
            ?? erodeToCore(mask, width: w, height: h)
        guard let coreRing, coreRing.count >= 3 else { return nil }
        let corePath = simplifyRing(coreRing, maxPoints: 80, width: w, height: h)
        guard corePath.count >= 3 else { return nil }

        // Candidate 3: convex hull of the raw glow boundary.
        var hullPath = glowPath
        if let hull = convexHull(glowRing) {
            let hullN = simplifyRing(hull, maxPoints: 80, width: w, height: h)
            if hullN.count >= 3 { hullPath = hullN }
        }

        let toVerts: ([CGPoint]) -> [PolygonVertex] = { $0.map { PolygonVertex(anchor: $0, controlIn: nil, controlOut: nil) } }
        // ponytail: both alpha and opaque paths produce candidates in the same order
        // (core, outer-glow, hull) so the caller always presents them identically.
        return [toVerts(corePath), toVerts(glowPath), toVerts(hullPath)]
    }

    /// Returns true when more than 1% of sampled pixels carry semi-transparent
    /// alpha (< 250 out of 255). Stratified sampling for speed.
    private static func hasSignificantAlpha(_ cgImage: CGImage) -> Bool {
        guard let d = cgImage.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return false }
        let bpr = cgImage.bytesPerRow, w = cgImage.width, h = cgImage.height
        let step = max(4, min(w, h) / 60)
        var semi = 0, total = 0
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                if p[y * bpr + x * 4 + 3] < 250 { semi += 1 }
                total += 1
            }
        }
        return total > 0 && Double(semi) / Double(total) > 0.01
    }

    /// Generates 3 candidates from the alpha channel: core (α > 0.50), full glow
    /// (α > 0.05), and convex hull of the full glow.
    private static func alphaVFXPaths(cgImage: CGImage) -> [[PolygonVertex]]? {
        let w = cgImage.width, h = cgImage.height
        guard let coreMask = alphaKeepMask(cgImage: cgImage, threshold: 127),
              let glowMask = alphaKeepMask(cgImage: cgImage, threshold: 12) else { return nil }

        let coreRing = contourPoints(from: coreMask)
        let glowRing = contourPoints(from: glowMask)
        guard coreRing.count >= 3, glowRing.count >= 3 else { return nil }

        let corePath = simplifyRing(coreRing, maxPoints: 80, width: w, height: h)
        let glowPath = simplifyRing(glowRing, maxPoints: 80, width: w, height: h)
        guard corePath.count >= 3, glowPath.count >= 3 else { return nil }

        var hullPath = glowPath
        if let hull = convexHull(glowRing) {
            let hullN = simplifyRing(hull, maxPoints: 80, width: w, height: h)
            if hullN.count >= 3 { hullPath = hullN }
        }

        let toVerts: ([CGPoint]) -> [PolygonVertex] = { $0.map { PolygonVertex(anchor: $0, controlIn: nil, controlOut: nil) } }
        return [toVerts(corePath), toVerts(glowPath), toVerts(hullPath)]
    }

    /// Builds a binary keep-mask (255 = keep) from the alpha channel of `cgImage`.
    private static func alphaKeepMask(cgImage: CGImage, threshold: Int) -> CGImage? {
        let w = cgImage.width, h = cgImage.height
        guard let d = cgImage.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        let bpr = cgImage.bytesPerRow
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { return nil }
        let dst = data.bindMemory(to: UInt8.self, capacity: h * w)
        for y in 0..<h {
            let row = y * bpr
            for x in 0..<w { dst[y * w + x] = p[row + x * 4 + 3] > threshold ? 255 : 0 }
        }
        return ctx.makeImage()
    }

    /// Finds the solid core boundary of a glowing object by casting rays from the
    /// mask centroid outward and locating the steepest negative luminance drop along
    /// each ray. Returns a raw pixel-space ring, or nil when too few rays yield a
    /// convincing core boundary (the caller falls back to `erodeToCore`).
    ///
    /// For a glowing icon / VFX flare the luminance profile from centre → edge is
    /// [bright plateau → steep drop → soft glow → background]. The drop is the
    /// solid object's edge; the soft glow beyond is the visible aura.
    ///
    /// ponytail: uses the outer glow ring to locate the mask edge for each ray,
    /// samples luminance at ~10 intervals between centroid and that edge, and picks
    /// the steepest negative 2-point slope. A minimum slope of -1 prevents picking
    /// up flat-region noise; rays where no convincing drop exists fall back to a
    /// fixed fraction (0.6× mask-edge distance) of the centroid-to-edge span.
    private static func radialLuminanceCore(source: CGImage, subjectMask: CGImage, outerGlowRing: [CGPoint]) -> [CGPoint]? {
        let width = source.width, height = source.height
        guard width > 1, height > 1 else { return nil }

        // Source luminance.
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)

        var lum = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width {
                let o = row + x * 4
                let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
                lum[y * width + x] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
            }
        }

        // Compute mask centroid.
        guard let md = subjectMask.dataProvider?.data, let mp = CFDataGetBytePtr(md) else { return nil }
        let mbpr = subjectMask.bytesPerRow
        var sx = 0, sy = 0, scount = 0
        for y in 0..<min(height, subjectMask.height) {
            let row = y * mbpr
            for x in 0..<min(width, subjectMask.width) where mp[row + x] > 127 {
                sx += x; sy += y; scount += 1
            }
        }
        guard scount > 0 else { return nil }
        let cx = CGFloat(sx) / CGFloat(scount)
        let cy = CGFloat(sy) / CGFloat(scount)

        // Build a direction→mask-boundary-distance map from the outer-glow ring:
        // for each ray angle, find the intersection of the ray from centroid with
        // the glow ring. This is the mask edge for that ray.
        let numRays = 120
        var ringDist = [CGFloat](repeating: 0, count: numRays)
        for ri in 0..<numRays {
            let angle = 2.0 * Double.pi * Double(ri) / Double(numRays)
            let dx = cos(angle), dy = sin(angle)
            var bestDist = CGFloat.greatestFiniteMagnitude
            for p in outerGlowRing {
                let vx = p.x - cx, vy = p.y - cy
                let proj = vx * CGFloat(dx) + vy * CGFloat(dy)
                if proj <= 0 { continue } // behind centroid
                let perpDist = abs(vx * CGFloat(-dy) + vy * CGFloat(dx))
                if perpDist < 2.0, proj < bestDist { bestDist = proj }
            }
            ringDist[ri] = bestDist < CGFloat.greatestFiniteMagnitude ? bestDist : 0
        }

        // Walk each ray from centroid outward, find steepest negative 2-point slope.
        var boundaryPts = [CGPoint]()
        let minSlope: Double = -1.0 // below this is a real drop
        for ri in 0..<numRays where ringDist[ri] > 3 {
            let angle = 2.0 * Double.pi * Double(ri) / Double(numRays)
            let dx = cos(angle), dy = sin(angle)
            let endT = max(3, Int(ringDist[ri]) + 3) // a few px past mask edge

            var bestSlope = 0.0
            var bestT: Int? = nil
            var prevLum = -1

            for t in 0..<endT {
                let tx = Int(cx + CGFloat(t) * dx), ty = Int(cy + CGFloat(t) * dy)
                guard tx >= 0, tx < width, ty >= 0, ty < height else { break }
                let curLum = Int(lum[ty * width + tx])
                if prevLum >= 0 {
                    let slope = Double(curLum - prevLum)
                    if slope < bestSlope { bestSlope = slope; bestT = t }
                }
                prevLum = curLum
            }

            let hitT: Int
            if let bestT, bestSlope < minSlope {
                hitT = bestT
            } else {
                // No convincing drop — use a fraction of the mask-edge distance.
                hitT = Int(CGFloat(endT) * 0.55)
            }
            let px = cx + CGFloat(hitT) * dx
            let py = cy + CGFloat(hitT) * dy
            if px >= 0, px <= CGFloat(width), py >= 0, py <= CGFloat(height) {
                boundaryPts.append(CGPoint(x: px, y: py))
            }
        }

        guard boundaryPts.count >= 3 else { return nil }
        return boundaryPts
    }

    /// Fallback core extraction: binary-erode the mask until at most ~70 % of the
    /// original subject area remains, then contour-trace. Used when radial luminance
    /// falloff doesn't produce a convincing core (e.g. flat-colour logo on opaque).
    private static func erodeToCore(_ mask: CGImage, width: Int, height: Int) -> [CGPoint]? {
        guard let d = mask.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        let bpr = mask.bytesPerRow
        let total = width * height
        var buf = [UInt8](repeating: 0, count: total)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width { buf[y * width + x] = p[row + x] }
        }
        let origCount = buf.filter { $0 > 127 }.count
        guard origCount > 10 else { return nil }
        let target = Int(Double(origCount) * 0.70)

        var radius = 1
        while radius <= 6 {
            let eroded = binaryErode(buf, width: width, height: height, radius: radius)
            let kept = eroded.filter { $0 > 127 }.count
            if kept <= target || kept < 10 { break }
            radius += 1
        }
        let eroded = radius == 1 ? buf : binaryErode(buf, width: width, height: height, radius: max(1, radius - 1))
        return contourPoints(fromFG: eroded.map { $0 > 127 }, width: width, height: height)
    }

    /// Local Otsu / adaptive thresholding focused on the central ~60% region of the
    /// image. Computes a luminance Otsu threshold within the centered crop, then
    /// applies it globally to produce a keep-mask. Catches starburst flares and
    /// central-emitter VFX where the flood path fails because rays touch the canvas
    /// border.
    ///
    /// ponytail: no sliding window or multi-region analysis. A single Otsu on the
    /// central crop recovers the core starburst emblem, which is the only pattern
    /// that matters here — full-frame flood collapse from border-touching rays.
    private static func localOtsuMask(cgImage: CGImage) -> CGImage? {
        let width = cgImage.width, height = cgImage.height
        guard width > 40, height > 40 else { return nil }

        // Build full-size luminance buffer once, then compute Otsu on the centre crop.
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bpr)

        var lum = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width {
                let o = row + x * 4
                let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
                lum[y * width + x] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
            }
        }

        // Central 60 % crop for Otsu statistics.
        let cx = width / 2, cy = height / 2
        let cropW = Int(CGFloat(width) * 0.6), cropH = Int(CGFloat(height) * 0.6)
        let ox = cx - cropW / 2, oy = cy - cropH / 2
        guard cropW > 10, cropH > 10 else { return nil }

        var hist = [Int](repeating: 0, count: 256)
        var localTotal = 0
        for y in oy..<(oy + cropH) {
            guard y >= 0, y < height else { continue }
            for x in ox..<(ox + cropW) {
                guard x >= 0, x < width else { continue }
                let v = Int(lum[y * width + x])
                hist[min(max(v, 0), 255)] += 1
                localTotal += 1
            }
        }
        guard localTotal > 0 else { return nil }
        let t = otsuThreshold(histogram: hist, total: localTotal)
        // Otsu class-2 = brighter pixels (v > t). For a starburst on dark bg the
        // bright pixels are the core emblem — exactly what we want.

        var keep = [UInt8](repeating: 0, count: width * height)
        for i in 0..<width * height where Int(lum[i]) > t { keep[i] = 255 }
        guard let result = try? buildMaskResult(keep, width: width, height: height) else { return nil }
        return isUsableSubjectMask(result.mask) ? result.mask : nil
    }
}
