import SwiftUI

struct CropCanvasView: View {
    let image: NSImage
    @Binding var cropRectNormalized: CGRect
    let aspectRatio: CGFloat?

    @State private var interaction: Interaction?
    @State private var pendingDrawStart: CGPoint?

    private enum Interaction {
        case move(startRect: CGRect)
        case resizeEdge(startRect: CGRect, edge: ResizeEdge)
        case resizeCorner(startRect: CGRect, corner: ResizeCorner)
        case draw(startPoint: CGPoint)
        case ignore
    }

    private enum ResizeEdge {
        case left
        case right
        case top
        case bottom
    }

    private enum ResizeCorner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private let drawActivationDistance: CGFloat = 8
    private let handleHitRadius: CGFloat = 16
    private let minCropDimension: CGFloat = 0.02

    var body: some View {
        GeometryReader { proxy in
            let imageFrame = fittedFrame(containerSize: proxy.size, imageSize: image.size)
            let cropFrame = viewRect(from: cropRectNormalized, imageFrame: imageFrame)

            ZStack(alignment: .topLeading) {
                Color(NSColor.controlBackgroundColor)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                Path { path in
                    path.addRect(imageFrame)
                    path.addRect(cropFrame)
                }
                .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))

                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: cropFrame.width, height: cropFrame.height)
                    .position(x: cropFrame.midX, y: cropFrame.midY)

                handle(at: CGPoint(x: cropFrame.minX, y: cropFrame.minY))
                handle(at: CGPoint(x: cropFrame.maxX, y: cropFrame.minY))
                handle(at: CGPoint(x: cropFrame.minX, y: cropFrame.maxY))
                handle(at: CGPoint(x: cropFrame.maxX, y: cropFrame.maxY))
                edgeHandle(at: CGPoint(x: cropFrame.midX, y: cropFrame.minY), horizontal: true)
                edgeHandle(at: CGPoint(x: cropFrame.midX, y: cropFrame.maxY), horizontal: true)
                edgeHandle(at: CGPoint(x: cropFrame.minX, y: cropFrame.midY), horizontal: false)
                edgeHandle(at: CGPoint(x: cropFrame.maxX, y: cropFrame.midY), horizontal: false)

                Text("Drag handles/sides to resize. Drag inside to move. Option+Drag outside to redraw.")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(dragGesture(imageFrame: imageFrame, cropFrame: cropFrame))
        }
    }

    private func handle(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 11, height: 11)
            .position(point)
            .allowsHitTesting(false)
    }

    private func edgeHandle(at point: CGPoint, horizontal: Bool) -> some View {
        Capsule()
            .fill(Color.white)
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: horizontal ? 20 : 8, height: horizontal ? 8 : 20)
            .position(point)
            .allowsHitTesting(false)
    }

    private func dragGesture(imageFrame: CGRect, cropFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if interaction == nil {
                    let startPoint = clamped(point: value.startLocation, inside: imageFrame)

                    if let corner = cornerHit(at: startPoint, cropFrame: cropFrame) {
                        interaction = .resizeCorner(startRect: cropRectNormalized, corner: corner)
                    } else if let edge = edgeHit(at: startPoint, cropFrame: cropFrame) {
                        interaction = .resizeEdge(startRect: cropRectNormalized, edge: edge)
                    } else if cropFrame.contains(startPoint) {
                        interaction = .move(startRect: cropRectNormalized)
                    } else if imageFrame.contains(startPoint) {
                        let optionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true

                        if optionPressed {
                            pendingDrawStart = normalizedPoint(from: startPoint, in: imageFrame)
                            interaction = .ignore
                        } else {
                            interaction = .ignore
                        }
                    } else {
                        return
                    }
                }

                guard let interaction else {
                    return
                }

                switch interaction {
                case .move(let startRect):
                    let dx = value.translation.width / imageFrame.width
                    let dy = value.translation.height / imageFrame.height
                    var moved = startRect.offsetBy(dx: dx, dy: dy)
                    moved.origin.x = min(max(0, moved.origin.x), 1 - moved.width)
                    moved.origin.y = min(max(0, moved.origin.y), 1 - moved.height)
                    cropRectNormalized = ImagePipeline.clampNormalizedRect(moved)

                case .resizeEdge(let startRect, let edge):
                    let current = normalizedPoint(
                        from: clamped(point: value.location, inside: imageFrame),
                        in: imageFrame
                    )

                    var resized = startRect

                    switch edge {
                    case .left:
                        let fixedMaxX = startRect.maxX
                        let newMinX = min(max(0, current.x), fixedMaxX - minCropDimension)
                        resized.origin.x = newMinX
                        resized.size.width = fixedMaxX - newMinX

                    case .right:
                        let fixedMinX = startRect.minX
                        let newMaxX = min(max(fixedMinX + minCropDimension, current.x), 1)
                        resized.size.width = newMaxX - fixedMinX

                    case .top:
                        let fixedMaxY = startRect.maxY
                        let newMinY = min(max(0, current.y), fixedMaxY - minCropDimension)
                        resized.origin.y = newMinY
                        resized.size.height = fixedMaxY - newMinY

                    case .bottom:
                        let fixedMinY = startRect.minY
                        let newMaxY = min(max(fixedMinY + minCropDimension, current.y), 1)
                        resized.size.height = newMaxY - fixedMinY
                    }

                    cropRectNormalized = ImagePipeline.clampNormalizedRect(resized)

                case .resizeCorner(let startRect, let corner):
                    let current = normalizedPoint(
                        from: clamped(point: value.location, inside: imageFrame),
                        in: imageFrame
                    )

                    var minX = startRect.minX
                    var maxX = startRect.maxX
                    var minY = startRect.minY
                    var maxY = startRect.maxY

                    switch corner {
                    case .topLeft:
                        minX = min(max(0, current.x), maxX - minCropDimension)
                        minY = min(max(0, current.y), maxY - minCropDimension)

                    case .topRight:
                        maxX = min(max(minX + minCropDimension, current.x), 1)
                        minY = min(max(0, current.y), maxY - minCropDimension)

                    case .bottomLeft:
                        minX = min(max(0, current.x), maxX - minCropDimension)
                        maxY = min(max(minY + minCropDimension, current.y), 1)

                    case .bottomRight:
                        maxX = min(max(minX + minCropDimension, current.x), 1)
                        maxY = min(max(minY + minCropDimension, current.y), 1)
                    }

                    let resized = CGRect(
                        x: minX,
                        y: minY,
                        width: maxX - minX,
                        height: maxY - minY
                    )

                    cropRectNormalized = ImagePipeline.clampNormalizedRect(resized)

                case .draw(let startPoint):
                    let currentPoint = normalizedPoint(
                        from: clamped(point: value.location, inside: imageFrame),
                        in: imageFrame
                    )

                    let proposed: CGRect

                    if let aspectRatio, aspectRatio > 0 {
                        proposed = aspectLockedRect(
                            start: startPoint,
                            current: currentPoint,
                            ratio: aspectRatio
                        )
                    } else {
                        proposed = CGRect(
                            x: min(startPoint.x, currentPoint.x),
                            y: min(startPoint.y, currentPoint.y),
                            width: abs(currentPoint.x - startPoint.x),
                            height: abs(currentPoint.y - startPoint.y)
                        )
                    }

                    cropRectNormalized = ImagePipeline.clampNormalizedRect(proposed)

                case .ignore:
                    if let drawStart = pendingDrawStart {
                        let currentPoint = normalizedPoint(
                            from: clamped(point: value.location, inside: imageFrame),
                            in: imageFrame
                        )

                        let drawDistance = hypot(
                            (currentPoint.x - drawStart.x) * imageFrame.width,
                            (currentPoint.y - drawStart.y) * imageFrame.height
                        )

                        if drawDistance >= drawActivationDistance {
                            self.interaction = .draw(startPoint: drawStart)
                        }
                    }
                }
            }
            .onEnded { _ in
                interaction = nil
                pendingDrawStart = nil
            }
    }

    private func cornerHit(at point: CGPoint, cropFrame: CGRect) -> ResizeCorner? {
        let corners: [(ResizeCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: cropFrame.minX, y: cropFrame.minY)),
            (.topRight, CGPoint(x: cropFrame.maxX, y: cropFrame.minY)),
            (.bottomLeft, CGPoint(x: cropFrame.minX, y: cropFrame.maxY)),
            (.bottomRight, CGPoint(x: cropFrame.maxX, y: cropFrame.maxY))
        ]

        for (corner, cornerPoint) in corners {
            if hypot(point.x - cornerPoint.x, point.y - cornerPoint.y) <= handleHitRadius {
                return corner
            }
        }

        return nil
    }

    private func edgeHit(at point: CGPoint, cropFrame: CGRect) -> ResizeEdge? {
        let cornerGuard = handleHitRadius * 0.9

        let leftZone = CGRect(
            x: cropFrame.minX - handleHitRadius,
            y: cropFrame.minY + cornerGuard,
            width: handleHitRadius * 2,
            height: max(0, cropFrame.height - cornerGuard * 2)
        )

        let rightZone = CGRect(
            x: cropFrame.maxX - handleHitRadius,
            y: cropFrame.minY + cornerGuard,
            width: handleHitRadius * 2,
            height: max(0, cropFrame.height - cornerGuard * 2)
        )

        let topZone = CGRect(
            x: cropFrame.minX + cornerGuard,
            y: cropFrame.minY - handleHitRadius,
            width: max(0, cropFrame.width - cornerGuard * 2),
            height: handleHitRadius * 2
        )

        let bottomZone = CGRect(
            x: cropFrame.minX + cornerGuard,
            y: cropFrame.maxY - handleHitRadius,
            width: max(0, cropFrame.width - cornerGuard * 2),
            height: handleHitRadius * 2
        )

        if leftZone.contains(point) {
            return .left
        }

        if rightZone.contains(point) {
            return .right
        }

        if topZone.contains(point) {
            return .top
        }

        if bottomZone.contains(point) {
            return .bottom
        }

        return nil
    }

    private func aspectLockedRect(start: CGPoint, current: CGPoint, ratio: CGFloat) -> CGRect {
        let signX: CGFloat = current.x >= start.x ? 1 : -1
        let signY: CGFloat = current.y >= start.y ? 1 : -1

        let maxWidth = signX > 0 ? (1 - start.x) : start.x
        let maxHeight = signY > 0 ? (1 - start.y) : start.y

        var width = abs(current.x - start.x)
        var height = abs(current.y - start.y)

        if width / max(height, 0.0001) > ratio {
            height = width / ratio
        } else {
            width = height * ratio
        }

        width = min(width, maxWidth)
        height = width / ratio

        if height > maxHeight {
            height = maxHeight
            width = height * ratio
        }

        let end = CGPoint(x: start.x + signX * width, y: start.y + signY * height)

        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func normalizedPoint(from point: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(0, (point.x - imageFrame.minX) / imageFrame.width), 1),
            y: min(max(0, (point.y - imageFrame.minY) / imageFrame.height), 1)
        )
    }

    private func viewRect(from normalizedRect: CGRect, imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + normalizedRect.minX * imageFrame.width,
            y: imageFrame.minY + normalizedRect.minY * imageFrame.height,
            width: normalizedRect.width * imageFrame.width,
            height: normalizedRect.height * imageFrame.height
        )
    }

    private func fittedFrame(containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let widthScale = containerSize.width / imageSize.width
        let heightScale = containerSize.height / imageSize.height
        let scale = min(widthScale, heightScale)

        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamped(point: CGPoint, inside rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
