import SwiftUI

final class PanState {
    var baseFrame: CGRect = .zero
    var containerSize: CGSize = .zero
    var panOffset: CGSize = .zero
    var zoomScale: CGFloat = 1.0
    var onPanOffsetChange: ((CGSize) -> Void)?
}

struct CropCanvasView: View {
    let image: NSImage
    @Binding var cropRectNormalized: CGRect
    let aspectRatio: CGFloat?
    let isEraseMode: Bool
    let eraseStrokes: [[CGPoint]]
    let currentEraseStroke: [CGPoint]
    let eraseBrushSize: CGFloat
    let eraseBrushShape: BrushShape
    let zoomScale: CGFloat
    let onErasePoint: (CGPoint) -> Void
    let onEraseEnd: () -> Void
    let isPolygonMode: Bool
    let polygonVertices: [PolygonVertex]
    let onPolygonVertex: (PolygonVertex) -> Void
    let onPolygonComplete: () -> Void
    let onSegmentCurve: (Int, CGPoint) -> Void
    let onMoveVertex: (Int, CGPoint) -> Void
    let isWandMode: Bool
    let wandContourPath: CGPath?
    let onWandClick: (CGPoint, Bool) -> Void
    let onWandInvert: () -> Void
    let panOffset: CGSize
    let onPanOffsetChange: (CGSize) -> Void
    let onZoomToScale: (CGFloat, CGSize) -> Void

    @State private var interaction: Interaction?
    @State private var pendingDrawStart: CGPoint?
    @State private var isHoldingZ = false
    @State private var draggingVertexIndex: Int?
    @State private var handEventMonitor: Any?
    @State private var panState = PanState()
    @State private var isMiddleDragging = false
    @State private var middleDragStartPan = CGSize.zero
    @State private var middleDragStartLocation = CGPoint.zero
    @State private var middleMouseMonitor: Any?

    private enum Interaction {
        case move(startRect: CGRect)
        case resizeEdge(startRect: CGRect, edge: ResizeEdge)
        case resizeCorner(startRect: CGRect, corner: ResizeCorner)
        case draw(startPoint: CGPoint)
        case erase
        case pan(startOffset: CGSize)
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
            let baseFrame = fittedFrame(containerSize: proxy.size, imageSize: image.size)
            let imageFrame = applyZoom(base: baseFrame, containerSize: proxy.size)
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

                if isEraseMode {
                    eraseStrokeOverlay(imageFrame: imageFrame)
                }

                if isPolygonMode, !polygonVertices.isEmpty {
                    polygonOverlay(imageFrame: imageFrame, containerSize: proxy.size)
                }

                if isWandMode, let path = wandContourPath {
                    wandMarchingAnts(path: path, imageFrame: imageFrame)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .contextMenu {
                if isWandMode && wandContourPath != nil {
                    Button("Invert Selection") { onWandInvert() }
                }
            }
            .gesture(dragGesture(imageFrame: imageFrame, cropFrame: cropFrame, baseFrame: baseFrame, containerSize: proxy.size), including: isPolygonMode || isWandMode ? .none : .gesture)
            .gesture(polygonTapGesture(imageFrame: imageFrame), including: isPolygonMode ? .gesture : .none)
            .gesture(wandTapGesture(imageFrame: imageFrame), including: isWandMode ? .gesture : .none)
            .onChange(of: panOffset) { panState.panOffset = $0 }
            .onChange(of: zoomScale) { panState.zoomScale = $0 }
            .onChange(of: image.size) { _ in
                panState.baseFrame = fittedFrame(containerSize: panState.containerSize, imageSize: image.size)
            }
            .onAppear {
                panState.onPanOffsetChange = onPanOffsetChange
                panState.containerSize = proxy.size
                panState.baseFrame = baseFrame
                panState.panOffset = panOffset
                panState.zoomScale = zoomScale
                if let existing = handEventMonitor {
                    NSEvent.removeMonitor(existing)
                }
                handEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    guard event.keyCode == 6 else { return event }
                    isHoldingZ = event.type == .keyDown
                    return event
                }

                if let existing = middleMouseMonitor {
                    NSEvent.removeMonitor(existing)
                }
                middleMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { event in
                    guard event.buttonNumber == 2 || event.buttonNumber == 0 else { return event }

                    let ps = panState

                    switch event.type {
                    case .otherMouseDown:
                        isMiddleDragging = true
                        middleDragStartPan = ps.panOffset
                        middleDragStartLocation = event.locationInWindow
                        return nil
                    case .otherMouseDragged:
                        guard isMiddleDragging else { return event }
                        let dx = event.locationInWindow.x - middleDragStartLocation.x
                        let dy = -(event.locationInWindow.y - middleDragStartLocation.y)
                        let proposed = CGSize(
                            width: middleDragStartPan.width + dx,
                            height: middleDragStartPan.height + dy
                        )
                        let overX = max(0, (ps.baseFrame.width * ps.zoomScale - ps.containerSize.width) / 2)
                        let overY = max(0, (ps.baseFrame.height * ps.zoomScale - ps.containerSize.height) / 2)
                        let clamped = CGSize(
                            width: min(max(proposed.width, -overX), overX),
                            height: min(max(proposed.height, -overY), overY)
                        )
                        if clamped != ps.panOffset {
                            ps.onPanOffsetChange?(clamped)
                        }
                        middleDragStartLocation = event.locationInWindow
                        middleDragStartPan = clamped
                        return nil
                    case .otherMouseUp:
                        isMiddleDragging = false
                        return nil
                    default:
                        return event
                    }
                }
            }
            .onDisappear {
                if let monitor = handEventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                if let monitor = middleMouseMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
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

    private func dragGesture(imageFrame: CGRect, cropFrame: CGRect, baseFrame: CGRect, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if interaction == nil {
                    let event = NSApp.currentEvent
                    let isDoubleClick = event?.type == .leftMouseDown && (event?.clickCount ?? 0) >= 2

                    if isDoubleClick && imageFrame.contains(value.startLocation) {
                        let norm = normalizedPoint(
                            from: clamped(point: value.startLocation, inside: imageFrame),
                            in: imageFrame
                        )
                        let newZoom = min(zoomScale * 2.0, 10.0)
                        let newPan = CGSize(
                            width: -(norm.x - 0.5) * baseFrame.width * newZoom,
                            height: -(norm.y - 0.5) * baseFrame.height * newZoom
                        )
                        onZoomToScale(newZoom, newPan)
                        return
                    }

                    let startPoint = clamped(point: value.startLocation, inside: imageFrame)

                    if isHoldingZ && imageFrame.contains(startPoint) {
                        interaction = .pan(startOffset: panOffset)
                    } else if isEraseMode && imageFrame.contains(startPoint) {
                        let norm = normalizedPoint(from: startPoint, in: imageFrame)
                        onErasePoint(norm)
                        interaction = .erase
                    } else if zoomScale > 1.001 && imageFrame.contains(startPoint)
                                && !cropFrame.contains(startPoint)
                                && cornerHit(at: startPoint, cropFrame: cropFrame) == nil
                                && edgeHit(at: startPoint, cropFrame: cropFrame) == nil {
                        interaction = .pan(startOffset: panOffset)
                    } else if let corner = cornerHit(at: startPoint, cropFrame: cropFrame) {
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

                case .erase:
                    let currentPoint = normalizedPoint(
                        from: clamped(point: value.location, inside: imageFrame),
                        in: imageFrame
                    )
                    onErasePoint(currentPoint)

                case .pan(let startOffset):
                    let clamped = clampedPanOffset(
                        CGSize(
                            width: startOffset.width + value.translation.width,
                            height: startOffset.height + value.translation.height
                        ),
                        baseFrame: baseFrame,
                        containerSize: containerSize
                    )
                    if clamped != panOffset {
                        onPanOffsetChange(clamped)
                    }

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
                if case .erase = interaction {
                    onEraseEnd()
                }
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

    private func applyZoom(base: CGRect, containerSize: CGSize) -> CGRect {
        let scaled = CGRect(
            x: base.midX - base.width * zoomScale / 2,
            y: base.midY - base.height * zoomScale / 2,
            width: base.width * zoomScale,
            height: base.height * zoomScale
        )
        return CGRect(
            x: scaled.origin.x + panOffset.width,
            y: scaled.origin.y + panOffset.height,
            width: scaled.width,
            height: scaled.height
        )
    }

    private func clampedPanOffset(_ proposed: CGSize, baseFrame: CGRect, containerSize: CGSize) -> CGSize {
        let scaledW = baseFrame.width * zoomScale
        let scaledH = baseFrame.height * zoomScale
        let overX = max(0, (scaledW - containerSize.width) / 2)
        let overY = max(0, (scaledH - containerSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -overX), overX),
            height: min(max(proposed.height, -overY), overY)
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

    @ViewBuilder
    private func eraseStrokeOverlay(imageFrame: CGRect) -> some View {
        let scale = imageFrame.width / image.size.width
        let brushViewSize = eraseBrushSize * scale
        let lineCap: CGLineCap = eraseBrushShape == .square ? .square : .round
        let lineJoin: CGLineJoin = eraseBrushShape == .square ? .miter : .round
        let style = StrokeStyle(lineWidth: brushViewSize, lineCap: lineCap, lineJoin: lineJoin)

        ForEach(Array(eraseStrokes.enumerated()), id: \.offset) { _, stroke in
            strokePath(stroke, imageFrame: imageFrame)
                .stroke(Color.red.opacity(0.55), style: style)
        }

        if !currentEraseStroke.isEmpty {
            strokePath(currentEraseStroke, imageFrame: imageFrame)
                .stroke(Color.red.opacity(0.7), style: style)
        }
    }

    private func strokePath(_ stroke: [CGPoint], imageFrame: CGRect) -> Path {
        Path { path in
            guard let first = stroke.first else { return }
            path.move(to: viewPoint(from: first, imageFrame: imageFrame))
            for point in stroke.dropFirst() {
                path.addLine(to: viewPoint(from: point, imageFrame: imageFrame))
            }
        }
    }

    private func viewPoint(from normalizedPoint: CGPoint, imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + normalizedPoint.x * imageFrame.width,
            y: imageFrame.minY + normalizedPoint.y * imageFrame.height
        )
    }

    private func wandTapGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard imageFrame.contains(value.startLocation) else { return }
                let norm = normalizedPoint(
                    from: clamped(point: value.startLocation, inside: imageFrame),
                    in: imageFrame
                )
                let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                onWandClick(norm, shiftHeld)
            }
    }

    private func wandMarchingAnts(path: CGPath, imageFrame: CGRect) -> some View {
        var transform = CGAffineTransform(scaleX: imageFrame.width, y: imageFrame.height)
            .translatedBy(x: imageFrame.minX / imageFrame.width, y: imageFrame.minY / imageFrame.height)
        let scaled = path.copy(using: &transform)

        return TimelineView(.periodic(from: .now, by: 0.08)) { context in
            let phase = (context.date.timeIntervalSinceReferenceDate * 10)
                .truncatingRemainder(dividingBy: 8)
            if let sp = scaled {
                Path(sp)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [4, 4], dashPhase: phase))
                Path(sp)
                    .stroke(Color.black, style: StrokeStyle(lineWidth: 2, dash: [4, 4], dashPhase: phase + 4))
                    .opacity(0.7)
            }
        }
    }

    private func polygonTapGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let idx = draggingVertexIndex else {
                    let point = clamped(point: value.startLocation, inside: imageFrame)
                    if imageFrame.contains(point),
                       let (hitIdx, _) = vertexHit(at: point, imageFrame: imageFrame) {
                        draggingVertexIndex = hitIdx
                    }
                    return
                }
                let point = clamped(point: value.location, inside: imageFrame)
                guard imageFrame.contains(point) else { return }
                onMoveVertex(idx, normalizedPoint(from: point, in: imageFrame))
            }
            .onEnded { value in
                let wasDraggingVertex = draggingVertexIndex != nil
                draggingVertexIndex = nil
                if wasDraggingVertex { return }
                guard imageFrame.contains(value.startLocation) else { return }
                let point = clamped(point: value.startLocation, inside: imageFrame)

                if polygonVertices.count >= 3 {
                    let firstView = viewPoint(from: polygonVertices[0].anchor, imageFrame: imageFrame)
                    if hypot(point.x - firstView.x, point.y - firstView.y) < 8 {
                        onPolygonComplete()
                        return
                    }
                }

                if polygonVertices.count >= 2 {
                    if let segIdx = segmentMidpointHit(at: point, imageFrame: imageFrame) {
                        let dragNorm = normalizedPoint(
                            from: clamped(point: value.location, inside: imageFrame),
                            in: imageFrame
                        )
                        let p0 = polygonVertices[segIdx].anchor
                        let p1 = polygonVertices[(segIdx + 1) % polygonVertices.count].anchor
                        let control = CGPoint(
                            x: 2 * dragNorm.x - (p0.x + p1.x) / 2,
                            y: 2 * dragNorm.y - (p0.y + p1.y) / 2
                        )
                        onSegmentCurve(segIdx, control)
                        return
                    }
                }

                let norm = normalizedPoint(from: point, in: imageFrame)
                onPolygonVertex(PolygonVertex(anchor: norm, segmentControl: nil))
            }
    }

    private func vertexHit(at screenPt: CGPoint, imageFrame: CGRect) -> (Int, CGPoint)? {
        for i in polygonVertices.indices {
            let vp = viewPoint(from: polygonVertices[i].anchor, imageFrame: imageFrame)
            if hypot(screenPt.x - vp.x, screenPt.y - vp.y) < 6 {
                return (i, polygonVertices[i].anchor)
            }
        }
        return nil
    }

    private func segmentMidpointHit(at screenPt: CGPoint, imageFrame: CGRect) -> Int? {
        let count = polygonVertices.count
        for i in 0..<count {
            let a = viewPoint(from: polygonVertices[i].anchor, imageFrame: imageFrame)
            let b = viewPoint(from: polygonVertices[(i + 1) % count].anchor, imageFrame: imageFrame)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if hypot(screenPt.x - mid.x, screenPt.y - mid.y) < 6 {
                return i
            }
        }
        return nil
    }

    @ViewBuilder
    private func polygonOverlay(imageFrame: CGRect, containerSize: CGSize) -> some View {
        let verts = polygonVertices
        let anchors = verts.map { viewPoint(from: $0.anchor, imageFrame: imageFrame) }
        let canClose = verts.count >= 3

        if verts.count >= 2 {
            let polygonPath = Path { path in
                path.move(to: anchors[0])
                for i in 0..<verts.count {
                    let next = (i + 1) % verts.count
                    let to = anchors[next]
                    if let cp = verts[i].segmentControl {
                        path.addQuadCurve(to: to, control: viewPoint(from: cp, imageFrame: imageFrame))
                    } else {
                        path.addLine(to: to)
                    }
                }
                path.closeSubpath()
            }

            Group {
                if canClose {
                    polygonPath.fill(Color.teal.opacity(0.15))
                }
                polygonPath.stroke(Color.teal, lineWidth: 2)
                    .opacity(canClose ? 1.0 : 0.5)
            }

            ForEach(0..<verts.count, id: \.self) { i in
                let a = anchors[i]
                let b = anchors[(i + 1) % verts.count]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let hasCurve = verts[i].segmentControl != nil
                Circle()
                    .fill(hasCurve ? Color.orange : Color.orange.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .position(mid)
            }
        }

        ForEach(Array(anchors.enumerated()), id: \.offset) { _, pt in
            Circle()
                .fill(Color.teal)
                .frame(width: 7, height: 7)
                .position(pt)
        }
    }
}
