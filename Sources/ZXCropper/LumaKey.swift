import AppKit
import CoreGraphics
import Foundation

extension ImagePipeline {
    /// Removes matte-black background while preserving dark parts of the asset.
    ///
    /// Uses flood-fill from all border pixels: any near-black region connected
    /// to the image edges is background and becomes transparent. Dark regions
    /// inside the asset (shadows, outlines, black clothing) are unreachable
    /// from the borders through brighter asset pixels, so they are preserved.
    ///
    /// - Parameters:
    ///   - threshold: Luma values below this are "near-black" candidates (0-255).
    ///   - softness: Width of the soft falloff zone at the bg/asset boundary.
    ///   - feather: Post-processing blur radius for anti-aliased edges.
    static func lumaKey(
        cgImage: CGImage,
        threshold: CGFloat,
        softness: CGFloat,
        feather: CGFloat
    ) throws -> CGImage {
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

        // Step 1: Compute luma for each pixel.
        var luma = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bpr + x * 4
                let r = Float(ptr[off])
                let g = Float(ptr[off + 1])
                let b = Float(ptr[off + 2])
                luma[y * width + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        // Step 2: Flood-fill from all border pixels where luma < threshold.
        // This identifies the external background. Dark regions inside the
        // asset are not reached (surrounded by brighter pixels).
        var visited = [Bool](repeating: false, count: width * height)
        var queue = [Int]()
        queue.reserveCapacity(width * height / 4)

        func enqueueIfBlack(_ x: Int, _ y: Int) {
            let idx = y * width + x
            if visited[idx] { return }
            if luma[idx] < thresh {
                visited[idx] = true
                queue.append(idx)
            }
        }

        // Seed from all four borders.
        for x in 0..<width { enqueueIfBlack(x, 0); enqueueIfBlack(x, height - 1) }
        for y in 0..<height { enqueueIfBlack(0, y); enqueueIfBlack(width - 1, y) }

        // BFS through 4-connected near-black pixels.
        var head = 0
        while head < queue.count {
            let idx = queue[head]
            head += 1
            let cx = idx % width
            let cy = idx / width
            if cx > 0 { enqueueIfBlack(cx - 1, cy) }
            if cx < width - 1 { enqueueIfBlack(cx + 1, cy) }
            if cy > 0 { enqueueIfBlack(cx, cy - 1) }
            if cy < height - 1 { enqueueIfBlack(cx, cy + 1) }
        }

        // Step 3: Build raw alpha.
        // 0 for flood-filled (bg), 1 for not-reached (asset).
        // Non-flood-filled dark pixels are INSIDE the asset (protected by
        // the flood fill boundary) — they get full alpha regardless of luma.
        // Edge smoothing is handled by the blur step, not by luma falloff.
        var rawAlpha = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            rawAlpha[i] = visited[i] ? 0 : 1
        }

        // Step 4: Median filter to remove single-pixel spikes.
        let medianAlpha = medianFilter3x3Float(rawAlpha, width: width, height: height)

        // Step 5: Box blur for smooth edges.
        let blurRadius = max(1, Int(feather.rounded()))
        let smoothedAlpha = boxBlurFloat(medianAlpha, width: width, height: height, radius: blurRadius)

        // Step 6: Write alpha to grayscale image.
        let alphaImage = try writeAlphaToImageLuma(smoothedAlpha, width: width, height: height)

        // Step 7: Composite — output preserves original asset colors, only
        // alpha changes. No de-composite needed: with black bg,
        // C = alpha * A, so premultiplied output = C (already correct).
        return try compositeLumaKey(
            ptr: ptr, width: width, height: height, bpr: bpr,
            alphaImage: alphaImage,
            colorSpace: colorSpace
        )
    }

    private static func compositeLumaKey(
        ptr: UnsafeMutablePointer<UInt8>,
        width: Int, height: Int, bpr: Int,
        alphaImage: CGImage,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        guard let alphaData = alphaImage.dataProvider?.data,
              let alphaPtr = CFDataGetBytePtr(alphaData) else {
            throw PipelineError.renderFailed
        }
        let alphaBpr = alphaImage.bytesPerRow

        guard let outCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PipelineError.renderFailed }
        guard let outData = outCtx.data else { throw PipelineError.renderFailed }
        let outBpr = outCtx.bytesPerRow
        let outPtr = outData.bindMemory(to: UInt8.self, capacity: height * outBpr)

        for y in 0..<height {
            for x in 0..<width {
                let a = alphaPtr[y * alphaBpr + x]
                let outOff = y * outBpr + x * 4
                if a == 0 {
                    outPtr[outOff] = 0
                    outPtr[outOff + 1] = 0
                    outPtr[outOff + 2] = 0
                    outPtr[outOff + 3] = 0
                    continue
                }
                let off = y * bpr + x * 4
                let alphaF = Float(a) / 255.0
                // With black bg, C = alpha * A, so premultiplied output = C * (a/255) / (C_alpha)
                // But since the original is already opaque (alpha=255) with black bg baked in,
                // we just premultiply by the new alpha.
                outPtr[outOff] = UInt8(max(0, min(255, (Float(ptr[off]) * alphaF).rounded())))
                outPtr[outOff + 1] = UInt8(max(0, min(255, (Float(ptr[off + 1]) * alphaF).rounded())))
                outPtr[outOff + 2] = UInt8(max(0, min(255, (Float(ptr[off + 2]) * alphaF).rounded())))
                outPtr[outOff + 3] = a
            }
        }

        guard let result = outCtx.makeImage() else { throw PipelineError.renderFailed }
        return result
    }

    // MARK: - Shared smoothing helpers (Float-based for LumaKey)

    private static func writeAlphaToImageLuma(_ alpha: [Float], width: Int, height: Int) throws -> CGImage {
        guard let grayCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let grayData = grayCtx.data else { throw PipelineError.renderFailed }
        let grayBpr = grayCtx.bytesPerRow
        let grayPtr = grayData.bindMemory(to: UInt8.self, capacity: height * grayBpr)
        for y in 0..<height {
            for x in 0..<width {
                grayPtr[y * grayBpr + x] = UInt8(max(0, min(255, (alpha[y * width + x] * 255).rounded())))
            }
        }
        guard let image = grayCtx.makeImage() else { throw PipelineError.renderFailed }
        return image
    }

    static func medianFilter3x3Float(_ input: [Float], width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height)
        var window = [Float](repeating: 0, count: 9)
        for y in 0..<height {
            for x in 0..<width {
                var i = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = max(0, min(width - 1, x + dx))
                        let ny = max(0, min(height - 1, y + dy))
                        window[i] = input[ny * width + nx]
                        i += 1
                    }
                }
                window.sort()
                output[y * width + x] = window[4]
            }
        }
        return output
    }

    static func boxBlurFloat(_ input: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return input }
        let r = radius
        let window = r * 2 + 1

        var temp = [Float](repeating: 0, count: width * height)
        var output = [Float](repeating: 0, count: width * height)

        input.withUnsafeBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { tmp in
                for y in 0..<height {
                    let rowBase = y * width
                    var sum: Float = 0
                    for k in -r...r {
                        let xx = min(max(k, 0), width - 1)
                        sum += src[rowBase + xx]
                    }
                    for x in 0..<width {
                        tmp[rowBase + x] = sum / Float(window)
                        let addX = min(x + r + 1, width - 1)
                        let subX = max(x - r, 0)
                        sum += src[rowBase + addX] - src[rowBase + subX]
                    }
                }
            }
        }

        temp.withUnsafeBufferPointer { tmp in
            output.withUnsafeMutableBufferPointer { dst in
                for x in 0..<width {
                    var sum: Float = 0
                    for k in -r...r {
                        let yy = min(max(k, 0), height - 1)
                        sum += tmp[yy * width + x]
                    }
                    for y in 0..<height {
                        dst[y * width + x] = sum / Float(window)
                        let addY = min(y + r + 1, height - 1)
                        let subY = max(y - r, 0)
                        sum += tmp[addY * width + x] - tmp[subY * width + x]
                    }
                }
            }
        }

        return output
    }
}
