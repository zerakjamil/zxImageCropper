import SwiftUI

final class PanState {
    var baseFrame: CGRect = .zero
    var containerSize: CGSize = .zero
    var panOffset: CGSize = .zero
    var zoomScale: CGFloat = 1.0
    var onPanOffsetChange: ((CGSize) -> Void)?

    // Live pen-tool state for the key-event monitor (avoids stale closure captures).
    var isPolygonMode = false
    var polygonVertexCount = 0
    var onPolygonComplete: (() -> Void)?
    var onPolygonRemoveLast: (() -> Void)?
    var onPolygonCancel: (() -> Void)?
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
    let penShape: PenShape
    let onEraseShape: (CGRect, Bool) -> Void
    let polygonVertices: [PolygonVertex]
    let onPolygonVertex: (PolygonVertex) -> Void
    let onPolygonComplete: () -> Void
    let onPolygonRemoveLast: () -> Void
    let onPolygonCancel: () -> Void
    let onMoveVertex: (Int, CGPoint) -> Void
    let onCurveSegment: (Int, CGPoint) -> Void
    let onFinalizeCurveSegment: (Int, CGPoint) -> Void
    let onInsertVertex: (Int, CGPoint) -> Void
    let penSmooth: Bool
    let isWandMode: Bool
    let wandContourPath: CGPath?
    let onWandClick: (CGPoint, Bool) -> Void
    let onWandInvert: () -> Void
    let isSliceMode: Bool
    let sliceRows: Int
    let sliceColumns: Int
    let sliceAutoDetect: Bool
    let detectedBoxes: [CGRect]
    let panOffset: CGSize
    let onPanOffsetChange: (CGSize) -> Void
    let onZoomToScale: (CGFloat, CGSize) -> Void
    let darkSpotBoxes: [CGRect]
    let darkSpotShapes: [NSImage?]
    let onDarkSpotClick: (Int) -> Void
    let isSpriteBoxEditMode: Bool
    let onSpriteBoxesChanged: ([CGRect]) -> Void
    let isRestoreMode: Bool
    let removedSpotBoxes: [CGRect]
    let removedSpotShapes: [NSImage?]
    let onRemovedSpotClick: (Int) -> Void
    let originalImage: NSImage?
    let livePreviewImage: NSImage?
    let pixelSize: CGSize
    let onSelectTool: (Int) -> Void

    @State private var interaction: Interaction?
    @State private var shapeDragRect: CGRect?
    @State private var hoverLocation: CGPoint?
    @State private var showOriginal = false
    @State private var scrollMonitor: Any?
    @State private var pinchAnchorScale: CGFloat?
    @State private var pendingDrawStart: CGPoint?
    @State private var isHoldingZ = false
    @State private var penDrag: PenDragTarget?
    @State private var penDragMoved = false
    @State private var handEventMonitor: Any?
    @State private var panState = PanState()
    @State private var isMiddleDragging = false
    @State private var selectedSpriteBox: Int? = nil
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

    private enum PenDragTarget: Equatable {
        case anchor(Int)
        case segment(Int)
        case pendingAnchor
    }

    private let drawActivationDistance: CGFloat = 8
    private let handleHitRadius: CGFloat = 16
    private let minCropDimension: CGFloat = 0.02

    var body: some View {
        GeometryReader { proxy in
            let baseFrame = fittedFrame(containerSize: proxy.size, imageSize: image.size)
            let imageFrame = applyZoom(base: baseFrame, containerSize: proxy.size)
            let cropFrame = viewRect(from: cropRectNormalized, imageFrame: imageFrame)
            let displayImage = showOriginal ? (originalImage ?? image) : (livePreviewImage ?? image)

            ZStack(alignment: .topLeading) {
                Color(NSColor.controlBackgroundColor)

                // Checkerboard so real transparency is visible behind the asset.
                CheckerboardView()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .allowsHitTesting(false)

                Image(nsImage: displayImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                if showOriginal {
                    badge("Original", color: .black.opacity(0.7))
                        .position(x: imageFrame.minX + 44, y: imageFrame.minY + 16)
                        .allowsHitTesting(false)
                } else if livePreviewImage != nil {
                    badge("Live Luma preview", color: .blue.opacity(0.8))
                        .position(x: imageFrame.minX + 70, y: imageFrame.minY + 16)
                        .allowsHitTesting(false)
                }

                if !isSliceMode {
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

                    if !isEraseMode && !isRestoreMode && !isPolygonMode && !isWandMode,
                       let dims = cropDimensionText {
                        badge(dims, color: .accentColor.opacity(0.9))
                            .position(
                                x: cropFrame.minX + 40,
                                y: max(imageFrame.minY + 12, cropFrame.minY - 12)
                            )
                            .allowsHitTesting(false)
                    }
                }

                if isSliceMode {
                    if sliceAutoDetect {
                        if isSpriteBoxEditMode {
                            spriteBoxEditOverlay(imageFrame: imageFrame)
                        } else {
                            sliceAutoOverlay(imageFrame: imageFrame)
                        }
                    } else {
                        sliceGridOverlay(imageFrame: imageFrame)
                    }
                }

                if isEraseMode || isRestoreMode {
                    eraseStrokeOverlay(imageFrame: imageFrame)
                }

                if isPolygonMode, penShape == .free, !polygonVertices.isEmpty {
                    polygonOverlay(imageFrame: imageFrame, containerSize: proxy.size)
                }

                if isPolygonMode, penShape != .free, let sr = shapeDragRect {
                    shapePreview(rect: sr, imageFrame: imageFrame)
                }

                if isWandMode, let path = wandContourPath {
                    wandMarchingAnts(path: path, imageFrame: imageFrame)
                }

                if !darkSpotBoxes.isEmpty {
                    darkSpotOverlay(imageFrame: imageFrame)
                }

                if !removedSpotBoxes.isEmpty {
                    removedSpotOverlay(imageFrame: imageFrame)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                case .ended:
                    hoverLocation = nil
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                if isWandMode && wandContourPath != nil {
                    Button("Invert Selection") { onWandInvert() }
                }
            }
            .gesture(dragGesture(imageFrame: imageFrame, cropFrame: cropFrame, baseFrame: baseFrame, containerSize: proxy.size), including: isPolygonMode || isWandMode || isSliceMode ? .none : .gesture)
            .gesture(polygonTapGesture(imageFrame: imageFrame), including: (isPolygonMode && penShape == .free) ? .gesture : .none)
            .gesture(shapeDragGesture(imageFrame: imageFrame), including: (isPolygonMode && penShape != .free) ? .gesture : .none)
            .gesture(wandTapGesture(imageFrame: imageFrame), including: isWandMode ? .gesture : .none)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        let anchorScale = pinchAnchorScale ?? zoomScale
                        if pinchAnchorScale == nil { pinchAnchorScale = zoomScale }
                        let target = min(max(anchorScale * value, 1.0), 10.0)
                        let anchor = hoverLocation ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        zoomAnchored(
                            newScale: target, anchor: anchor,
                            base: baseFrame, container: proxy.size,
                            currentScale: zoomScale, currentPan: panOffset
                        )
                    }
                    .onEnded { _ in pinchAnchorScale = nil }
            )
            .onChange(of: panOffset) { panState.panOffset = $0 }
            .onChange(of: zoomScale) { panState.zoomScale = $0 }
            .onChange(of: isPolygonMode) { panState.isPolygonMode = $0 }
            .onChange(of: polygonVertices.count) { panState.polygonVertexCount = $0 }
            .onChange(of: image.size) { _ in
                panState.baseFrame = fittedFrame(containerSize: panState.containerSize, imageSize: image.size)
            }
            .onChange(of: proxy.size) { newSize in
                panState.containerSize = newSize
                panState.baseFrame = fittedFrame(containerSize: newSize, imageSize: image.size)
            }
            .onAppear {
                panState.onPanOffsetChange = onPanOffsetChange
                panState.containerSize = proxy.size
                panState.baseFrame = baseFrame
                panState.panOffset = panOffset
                panState.zoomScale = zoomScale
                panState.isPolygonMode = isPolygonMode
                panState.polygonVertexCount = polygonVertices.count
                panState.onPolygonComplete = onPolygonComplete
                panState.onPolygonRemoveLast = onPolygonRemoveLast
                panState.onPolygonCancel = onPolygonCancel
                if let existing = handEventMonitor {
                    NSEvent.removeMonitor(existing)
                }
                handEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    // Track the Z key (keyCode 6) for hold-to-pan.
                    if event.keyCode == 6 {
                        isHoldingZ = event.type == .keyDown
                        return event
                    }

                    // Hold backslash (keyCode 42) to compare against the original —
                    // but never while a text field is being edited.
                    if event.keyCode == 42, !isTextFieldFocused() {
                        showOriginal = event.type == .keyDown
                        return nil
                    }

                    // Tool hotkeys 1–5, unless a text field is being edited.
                    if event.type == .keyDown, !isTextFieldFocused() {
                        let toolMap: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5]
                        if let tool = toolMap[event.keyCode] {
                            onSelectTool(tool)
                            return nil
                        }
                    }

                    let ps = panState

                    // Pen-tool keyboard shortcuts, only while drawing a path and not
                    // editing text.
                    guard event.type == .keyDown, !isTextFieldFocused(),
                          ps.isPolygonMode, ps.polygonVertexCount > 0 else {
                        return event
                    }

                    switch event.keyCode {
                    case 36, 76: // Return / keypad Enter
                        if ps.polygonVertexCount >= 3 {
                            ps.onPolygonComplete?()
                            return nil
                        }
                        return event
                    case 51, 117: // Delete (Backspace) / Forward Delete
                        ps.onPolygonRemoveLast?()
                        return nil
                    case 53: // Escape
                        ps.onPolygonCancel?()
                        return nil
                    default:
                        return event
                    }
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

                if let existing = scrollMonitor {
                    NSEvent.removeMonitor(existing)
                }
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
                    // Only zoom when the cursor is over the canvas; otherwise let
                    // the sidebar scroll normally.
                    guard let anchor = hoverLocation else { return event }
                    let dy = event.scrollingDeltaY
                    guard dy != 0 else { return event }
                    let ps = panState
                    let factor: CGFloat = dy > 0 ? 1.08 : (1.0 / 1.08)
                    let target = min(max(ps.zoomScale * factor, 1.0), 10.0)
                    if abs(target - ps.zoomScale) < 0.0001 { return nil }
                    zoomAnchored(
                        newScale: target, anchor: anchor,
                        base: ps.baseFrame, container: ps.containerSize,
                        currentScale: ps.zoomScale, currentPan: ps.panOffset
                    )
                    return nil
                }
            }
            .onDisappear {
                if let monitor = handEventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                if let monitor = middleMouseMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                if let monitor = scrollMonitor {
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
                    } else if (isEraseMode || isRestoreMode) && imageFrame.contains(startPoint) {
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

                    if let ratio = normalizedAspectRatio {
                        cropRectNormalized = ImagePipeline.clampNormalizedRect(
                            aspectEdgeRect(start: startRect, edge: edge, cursor: current, ratio: ratio)
                        )
                        return
                    }

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

                    if let ratio = normalizedAspectRatio {
                        cropRectNormalized = ImagePipeline.clampNormalizedRect(
                            aspectCornerRect(start: startRect, corner: corner, cursor: current, ratio: ratio)
                        )
                        return
                    }

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

                    if let ratio = normalizedAspectRatio {
                        proposed = aspectLockedRect(
                            start: startPoint,
                            current: currentPoint,
                            ratio: ratio
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

    /// The crop aspect ratio expressed in normalized (0...1) space. `aspectRatio`
    /// is a pixel ratio (1:1 = a real square), so it is scaled by the image's
    /// pixel aspect so locked crops are correct on non-square images.
    private var normalizedAspectRatio: CGFloat? {
        guard let aspectRatio, aspectRatio > 0, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return aspectRatio * (pixelSize.height / pixelSize.width)
    }

    /// Aspect-locked corner resize: the opposite corner stays pinned and the box
    /// grows/shrinks toward the cursor while keeping `ratio`.
    private func aspectCornerRect(start: CGRect, corner: ResizeCorner, cursor: CGPoint, ratio: CGFloat) -> CGRect {
        let anchorX: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? start.maxX : start.minX
        let anchorY: CGFloat = (corner == .topLeft || corner == .topRight) ? start.maxY : start.minY
        let signX: CGFloat = (corner == .topRight || corner == .bottomRight) ? 1 : -1
        let signY: CGFloat = (corner == .bottomLeft || corner == .bottomRight) ? 1 : -1

        var w = abs(cursor.x - anchorX)
        var h = abs(cursor.y - anchorY)
        if w / max(h, 0.0001) > ratio { h = w / ratio } else { w = h * ratio }

        let maxW = signX > 0 ? (1 - anchorX) : anchorX
        let maxH = signY > 0 ? (1 - anchorY) : anchorY
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        w = max(w, minCropDimension)
        h = max(h, minCropDimension)

        let x = signX > 0 ? anchorX : anchorX - w
        let y = signY > 0 ? anchorY : anchorY - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Aspect-locked edge resize: the opposite edge stays pinned, the dragged axis
    /// drives the size, and the perpendicular axis grows symmetrically from the
    /// box centre while keeping `ratio`.
    private func aspectEdgeRect(start: CGRect, edge: ResizeEdge, cursor: CGPoint, ratio: CGFloat) -> CGRect {
        switch edge {
        case .left, .right:
            let anchorX = edge == .left ? start.maxX : start.minX
            let signX: CGFloat = edge == .left ? -1 : 1
            var w = abs(cursor.x - anchorX)
            var h = w / ratio
            let maxW = signX > 0 ? (1 - anchorX) : anchorX
            if w > maxW { w = maxW; h = w / ratio }
            if h > 1 { h = 1; w = h * ratio }
            w = max(w, minCropDimension)
            h = max(h, minCropDimension)
            let x = signX > 0 ? anchorX : anchorX - w
            let y = min(max(0, start.midY - h / 2), 1 - h)
            return CGRect(x: x, y: y, width: w, height: h)
        case .top, .bottom:
            let anchorY = edge == .top ? start.maxY : start.minY
            let signY: CGFloat = edge == .top ? -1 : 1
            var h = abs(cursor.y - anchorY)
            var w = h * ratio
            let maxH = signY > 0 ? (1 - anchorY) : anchorY
            if h > maxH { h = maxH; w = h * ratio }
            if w > 1 { w = 1; h = w / ratio }
            w = max(w, minCropDimension)
            h = max(h, minCropDimension)
            let y = signY > 0 ? anchorY : anchorY - h
            let x = min(max(0, start.midX - w / 2), 1 - w)
            return CGRect(x: x, y: y, width: w, height: h)
        }
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

        let padding: CGFloat = 24
        let targetWidth = max(containerSize.width - padding * 2, 10)
        let targetHeight = max(containerSize.height - padding * 2, 10)

        let widthScale = targetWidth / imageSize.width
        let heightScale = targetHeight / imageSize.height
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
        // Refine brush is colour-coded: green adds to the selection, red removes.
        let strokeTint: Color = .red

        ForEach(Array(eraseStrokes.enumerated()), id: \.offset) { _, stroke in
            strokePath(stroke, imageFrame: imageFrame)
                .stroke(strokeTint.opacity(0.55), style: style)
        }

        if !currentEraseStroke.isEmpty {
            strokePath(currentEraseStroke, imageFrame: imageFrame)
                .stroke(strokeTint.opacity(0.7), style: style)
        }
    }

    @ViewBuilder
    private func sliceGridOverlay(imageFrame: CGRect) -> some View {
        let rows = max(1, sliceRows)
        let columns = max(1, sliceColumns)

        Path { path in
            // Outer border.
            path.addRect(imageFrame)

            // Interior vertical lines.
            if columns > 1 {
                for c in 1..<columns {
                    let x = imageFrame.minX + imageFrame.width * CGFloat(c) / CGFloat(columns)
                    path.move(to: CGPoint(x: x, y: imageFrame.minY))
                    path.addLine(to: CGPoint(x: x, y: imageFrame.maxY))
                }
            }

            // Interior horizontal lines.
            if rows > 1 {
                for r in 1..<rows {
                    let y = imageFrame.minY + imageFrame.height * CGFloat(r) / CGFloat(rows)
                    path.move(to: CGPoint(x: imageFrame.minX, y: y))
                    path.addLine(to: CGPoint(x: imageFrame.maxX, y: y))
                }
            }
        }
        .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func sliceAutoOverlay(imageFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(detectedBoxes.enumerated()), id: \.offset) { index, box in
                let rect = viewRect(from: box, imageFrame: imageFrame)
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .position(x: rect.minX + 11, y: rect.minY + 9)
            }
        }
        .allowsHitTesting(false)
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

    private func spriteBoxEditOverlay(imageFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(detectedBoxes.enumerated()), id: \.offset) { index, box in
                SpriteBoxView(
                    index: index,
                    normalizedBox: box,
                    imageFrame: imageFrame,
                    isSelected: selectedSpriteBox == index,
                    onTap: { selectedSpriteBox = index },
                    onMove: { newBox in
                        var boxes = detectedBoxes
                        if index < boxes.count {
                            boxes[index] = newBox
                            onSpriteBoxesChanged(boxes)
                        }
                    },
                    onResize: { newBox in
                        var boxes = detectedBoxes
                        if index < boxes.count {
                            boxes[index] = newBox
                            onSpriteBoxesChanged(boxes)
                        }
                    },
                    onDelete: {
                        var boxes = detectedBoxes
                        if index < boxes.count {
                            boxes.remove(at: index)
                            selectedSpriteBox = nil
                            onSpriteBoxesChanged(boxes)
                        }
                    },
                    onSplit: { horizontal in
                        var boxes = detectedBoxes
                        if index < boxes.count {
                            let b = boxes[index]
                            let firstBox: CGRect
                            let secondBox: CGRect
                            if horizontal {
                                firstBox = CGRect(x: b.origin.x, y: b.origin.y, width: b.width / 2, height: b.height)
                                secondBox = CGRect(x: b.midX, y: b.origin.y, width: b.width / 2, height: b.height)
                            } else {
                                firstBox = CGRect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height / 2)
                                secondBox = CGRect(x: b.origin.x, y: b.midY, width: b.width, height: b.height / 2)
                            }
                            boxes.remove(at: index)
                            boxes.insert(secondBox, at: index)
                            boxes.insert(firstBox, at: index)
                            onSpriteBoxesChanged(boxes)
                        }
                    }
                )
            }
        }
    }

    private func darkSpotOverlay(imageFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(darkSpotBoxes.enumerated()), id: \.offset) { index, box in
                let rect = viewRect(from: box, imageFrame: imageFrame)
                Button {
                    onDarkSpotClick(index)
                } label: {
                    spotShape(index: index, shapes: darkSpotShapes, rect: rect, tint: .red)
                }
                .buttonStyle(.plain)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private func removedSpotOverlay(imageFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(removedSpotBoxes.enumerated()), id: \.offset) { index, box in
                let rect = viewRect(from: box, imageFrame: imageFrame)
                Button {
                    onRemovedSpotClick(index)
                } label: {
                    spotShape(index: index, shapes: removedSpotShapes, rect: rect, tint: .green)
                }
                .buttonStyle(.plain)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// Renders the actual region shape (tinted, semi-transparent) so it's obvious
    /// exactly what will be removed/restored. Falls back to a boxed outline if the
    /// shape image is missing.
    @ViewBuilder
    private func spotShape(index: Int, shapes: [NSImage?], rect: CGRect, tint: Color) -> some View {
        if index < shapes.count, let shape = shapes[index] {
            Image(nsImage: shape)
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .colorMultiply(tint)
                .opacity(0.6)
                .contentShape(Rectangle())
        } else {
            Rectangle()
                .fill(tint.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(tint, lineWidth: 1.5))
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    private var cropDimensionText: String? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let rect = ImagePipeline.clampNormalizedRect(cropRectNormalized)
        let w = Int((rect.width * pixelSize.width).rounded())
        let h = Int((rect.height * pixelSize.height).rounded())
        return "\(w) × \(h) px"
    }

    /// Cursor-anchored zoom: the image-space point under `anchor` stays under the
    /// cursor after rescaling. `currentScale`/`currentPan` are passed explicitly
    /// so this works from the long-lived scroll-wheel event monitor.
    private func zoomAnchored(
        newScale: CGFloat,
        anchor: CGPoint,
        base: CGRect,
        container: CGSize,
        currentScale: CGFloat,
        currentPan: CGSize
    ) {
        let curW = base.width * currentScale
        let curH = base.height * currentScale
        guard curW > 0, curH > 0 else { return }
        let curMinX = base.midX - curW / 2 + currentPan.width
        let curMinY = base.midY - curH / 2 + currentPan.height
        let nx = (anchor.x - curMinX) / curW
        let ny = (anchor.y - curMinY) / curH
        var panX = anchor.x - nx * base.width * newScale - (base.midX - base.width * newScale / 2)
        var panY = anchor.y - ny * base.height * newScale - (base.midY - base.height * newScale / 2)
        let overX = max(0, (base.width * newScale - container.width) / 2)
        let overY = max(0, (base.height * newScale - container.height) / 2)
        panX = min(max(panX, -overX), overX)
        panY = min(max(panY, -overY), overY)
        onZoomToScale(newScale, CGSize(width: panX, height: panY))
    }

    private func isTextFieldFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText
    }

    /// Drag a bounding box to cut a clean rectangle/ellipse. Shift constrains to a
    /// perfect square/circle (in pixels, so it's correct on non-square images).
    private func shapeDragGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = normalizedPoint(from: clamped(point: value.startLocation, inside: imageFrame), in: imageFrame)
                var current = normalizedPoint(from: clamped(point: value.location, inside: imageFrame), in: imageFrame)

                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
                   pixelSize.width > 0, pixelSize.height > 0 {
                    // Equal pixel extents → true square/circle.
                    let dxPix = abs(current.x - start.x) * pixelSize.width
                    let dyPix = abs(current.y - start.y) * pixelSize.height
                    let s = max(dxPix, dyPix)
                    let nW = s / pixelSize.width
                    let nH = s / pixelSize.height
                    current = CGPoint(
                        x: start.x + (current.x < start.x ? -nW : nW),
                        y: start.y + (current.y < start.y ? -nH : nH)
                    )
                }

                shapeDragRect = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
            }
            .onEnded { _ in
                if let r = shapeDragRect, r.width > 0.005, r.height > 0.005 {
                    onEraseShape(r, penShape == .ellipse)
                }
                shapeDragRect = nil
            }
    }

    @ViewBuilder
    private func shapePreview(rect: CGRect, imageFrame: CGRect) -> some View {
        let vr = viewRect(from: rect, imageFrame: imageFrame)
        Group {
            if penShape == .ellipse {
                Ellipse().fill(Color.teal.opacity(0.15))
                    .frame(width: vr.width, height: vr.height)
                    .position(x: vr.midX, y: vr.midY)
                Ellipse().stroke(Color.teal, lineWidth: 2)
                    .frame(width: vr.width, height: vr.height)
                    .position(x: vr.midX, y: vr.midY)
            } else {
                Rectangle().fill(Color.teal.opacity(0.15))
                    .frame(width: vr.width, height: vr.height)
                    .position(x: vr.midX, y: vr.midY)
                Rectangle().stroke(Color.teal, lineWidth: 2)
                    .frame(width: vr.width, height: vr.height)
                    .position(x: vr.midX, y: vr.midY)
            }
        }
        .allowsHitTesting(false)
    }

    private func polygonTapGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startPoint = clamped(point: value.startLocation, inside: imageFrame)
                let currentNorm = normalizedPoint(
                    from: clamped(point: value.location, inside: imageFrame),
                    in: imageFrame
                )

                if penDrag == nil {
                    // What did we grab? An anchor dot (to move), a segment (to curve),
                    // or empty space (a pending new point / close-on-release).
                    if let i = anchorHitTest(at: startPoint, imageFrame: imageFrame) {
                        penDrag = .anchor(i)
                    } else if let seg = segmentHitTest(at: startPoint, imageFrame: imageFrame) {
                        penDrag = .segment(seg)
                    } else {
                        penDrag = .pendingAnchor
                    }
                    penDragMoved = false
                    return
                }

                let dragDistance = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                )
                if dragDistance >= 3 {
                    penDragMoved = true
                }

                switch penDrag {
                case .anchor(let i):
                    onMoveVertex(i, currentNorm)
                case .segment(let i):
                    // Manual arc-drag only in non-smooth mode (smooth auto-curves).
                    if !penSmooth {
                        onCurveSegment(i, currentNorm)
                    }
                case .pendingAnchor, .none:
                    break
                }
            }
            .onEnded { value in
                defer {
                    penDrag = nil
                    penDragMoved = false
                }
                guard imageFrame.contains(value.startLocation) else { return }
                let startPoint = clamped(point: value.startLocation, inside: imageFrame)

                // A segment was actually dragged (not just tapped): commit the exact
                // circular arc now — cheap live preview during the drag, exact
                // multi-piece fit on release (see finalizeCurveSegment).
                if penDragMoved, case .segment(let i) = penDrag {
                    let releasePoint = clamped(point: value.location, inside: imageFrame)
                    let releaseNorm = normalizedPoint(from: releasePoint, in: imageFrame)
                    onFinalizeCurveSegment(i, releaseNorm)
                    return
                }

                guard !penDragMoved else { return }

                // A plain tap: on the first dot it closes the path; on empty space it
                // adds a new point.
                switch penDrag {
                case .anchor(0) where polygonVertices.count >= 3:
                    onPolygonComplete()
                case .segment(let i):
                    // A tap on the line adds a refinement point there (drag curves it).
                    let norm = normalizedPoint(from: startPoint, in: imageFrame)
                    onInsertVertex(i, norm)
                case .pendingAnchor:
                    let norm = normalizedPoint(from: startPoint, in: imageFrame)
                    onPolygonVertex(PolygonVertex(anchor: norm, controlIn: nil, controlOut: nil))
                default:
                    break
                }
            }
    }

    /// Index of the anchor dot under the point, if any.
    private func anchorHitTest(at screenPt: CGPoint, imageFrame: CGRect) -> Int? {
        let radius: CGFloat = 11
        for i in polygonVertices.indices {
            let vp = viewPoint(from: polygonVertices[i].anchor, imageFrame: imageFrame)
            if hypot(screenPt.x - vp.x, screenPt.y - vp.y) <= radius {
                return i
            }
        }
        return nil
    }

    /// Index of the segment (the line/curve between two adjacent dots) under the
    /// point, if any. Segments are sampled so curved edges are hit accurately.
    private func segmentHitTest(at screenPt: CGPoint, imageFrame: CGRect) -> Int? {
        let count = polygonVertices.count
        guard count >= 2 else { return nil }
        let threshold: CGFloat = 11
        var bestIdx: Int?
        var bestDist = threshold

        for i in 0..<count {
            let next = (i + 1) % count
            // Skip the duplicate closing edge when there are only two points.
            if next == 0 && count < 3 { continue }

            let a = viewPoint(from: polygonVertices[i].anchor, imageFrame: imageFrame)
            let b = viewPoint(from: polygonVertices[next].anchor, imageFrame: imageFrame)
            let c1 = polygonVertices[i].controlOut.map { viewPoint(from: $0, imageFrame: imageFrame) } ?? a
            let c2 = polygonVertices[next].controlIn.map { viewPoint(from: $0, imageFrame: imageFrame) } ?? b

            let samples = 18
            for s in 0...samples {
                let t = CGFloat(s) / CGFloat(samples)
                let p = cubicPoint(a, c1, c2, b, t)
                let d = hypot(screenPt.x - p.x, screenPt.y - p.y)
                if d < bestDist {
                    bestDist = d
                    bestIdx = i
                }
            }
        }
        return bestIdx
    }

    /// Evaluate a cubic Bézier at parameter t.
    private func cubicPoint(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let w0 = mt * mt * mt
        let w1 = 3 * mt * mt * t
        let w2 = 3 * mt * t * t
        let w3 = t * t * t
        return CGPoint(
            x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x,
            y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y
        )
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
                    let c1 = verts[i].controlOut.map { viewPoint(from: $0, imageFrame: imageFrame) }
                    let c2 = verts[next].controlIn.map { viewPoint(from: $0, imageFrame: imageFrame) }
                    if c1 != nil || c2 != nil {
                        path.addCurve(
                            to: to,
                            control1: c1 ?? anchors[i],
                            control2: c2 ?? to
                        )
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
        }

        // "Drag to curve" affordance: a small hollow dot at the middle of each
        // segment. Only shown in manual mode (smooth mode auto-curves).
        if verts.count >= 2 && !penSmooth {
            ForEach(0..<verts.count, id: \.self) { i in
                let next = (i + 1) % verts.count
                if !(next == 0 && verts.count < 3) {
                    let a = anchors[i]
                    let b = anchors[next]
                    let c1 = verts[i].controlOut.map { viewPoint(from: $0, imageFrame: imageFrame) } ?? a
                    let c2 = verts[next].controlIn.map { viewPoint(from: $0, imageFrame: imageFrame) } ?? b
                    let mid = cubicPoint(a, c1, c2, b, 0.5)
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .overlay(Circle().stroke(Color.teal, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .position(mid)
                }
            }
        }

        // Anchor knobs (teal styling preserved).
        ForEach(Array(anchors.enumerated()), id: \.offset) { _, pt in
            Circle()
                .fill(Color.teal)
                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                .frame(width: 10, height: 10)
                .position(pt)
        }
    }
}

enum SpriteBoxEdge {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
}

struct SpriteBoxView: View {
    let index: Int
    let normalizedBox: CGRect
    let imageFrame: CGRect
    let isSelected: Bool
    let onTap: () -> Void
    let onMove: (CGRect) -> Void
    let onResize: (CGRect) -> Void
    let onDelete: () -> Void
    let onSplit: (Bool) -> Void

    // The box captured when a drag begins. All move/resize math is relative to
    // this fixed start, so the box follows the cursor exactly (no compounding).
    @State private var dragStartBox: CGRect?
    private let handleSize: CGFloat = 8

    var body: some View {
        let rect = CGRect(
            x: imageFrame.minX + normalizedBox.origin.x * imageFrame.width,
            y: imageFrame.minY + normalizedBox.origin.y * imageFrame.height,
            width: normalizedBox.width * imageFrame.width,
            height: normalizedBox.height * imageFrame.height
        )

        ZStack(alignment: .topLeading) {
            // Fill + border
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.accentColor.opacity(0.08))
                .frame(width: rect.width, height: rect.height)
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? Color.accentColor : Color.accentColor.opacity(0.5),
                                lineWidth: isSelected ? 2 : 1.5)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isSelected { onTap() }
                            let start = dragStartBox ?? normalizedBox
                            if dragStartBox == nil { dragStartBox = normalizedBox }
                            let dx = imageFrame.width > 0 ? value.translation.width / imageFrame.width : 0
                            let dy = imageFrame.height > 0 ? value.translation.height / imageFrame.height : 0
                            var b = start
                            b.origin.x = max(0, min(1 - start.width, start.origin.x + dx))
                            b.origin.y = max(0, min(1 - start.height, start.origin.y + dy))
                            onMove(b)
                        }
                        .onEnded { _ in dragStartBox = nil }
                )
                .contextMenu {
                    Button("Delete Box") { onDelete() }
                    Button("Split Horizontal") { onSplit(true) }
                    Button("Split Vertical") { onSplit(false) }
                }

            // Label — local coordinates (0,0) = top-left of box
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(isSelected ? Color.red.opacity(0.85) : Color.accentColor.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .position(x: 11, y: 9)
                .allowsHitTesting(false)

            // Handles — local coordinates relative to the box's own frame
            if isSelected {
                handleView(edge: .left, at: CGPoint(x: 0, y: rect.height / 2))
                handleView(edge: .right, at: CGPoint(x: rect.width, y: rect.height / 2))
                handleView(edge: .top, at: CGPoint(x: rect.width / 2, y: 0))
                handleView(edge: .bottom, at: CGPoint(x: rect.width / 2, y: rect.height))
                handleView(edge: .topLeft, at: CGPoint(x: 0, y: 0))
                handleView(edge: .topRight, at: CGPoint(x: rect.width, y: 0))
                handleView(edge: .bottomLeft, at: CGPoint(x: 0, y: rect.height))
                handleView(edge: .bottomRight, at: CGPoint(x: rect.width, y: rect.height))
            }
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .position(x: rect.midX, y: rect.midY)
    }

    private func handleView(edge: SpriteBoxEdge, at pos: CGPoint) -> some View {
        Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: handleSize, height: handleSize)
            .position(pos)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartBox ?? normalizedBox
                        if dragStartBox == nil { dragStartBox = normalizedBox }
                        onResize(resizedBox(start: start, edge: edge, translation: value.translation))
                    }
                    .onEnded { _ in dragStartBox = nil }
            )
    }

    private func resizedBox(start: CGRect, edge: SpriteBoxEdge, translation: CGSize) -> CGRect {
        let dx = imageFrame.width > 0 ? translation.width / imageFrame.width : 0
        let dy = imageFrame.height > 0 ? translation.height / imageFrame.height : 0
        let minSize: CGFloat = 0.01
        var b = start

        switch edge {
        case .left:
            let newMinX = max(0, min(start.maxX - minSize, start.origin.x + dx))
            b.origin.x = newMinX
            b.size.width = start.maxX - newMinX
        case .right:
            b.size.width = max(minSize, min(1 - start.origin.x, start.width + dx))
        case .top:
            let newMinY = max(0, min(start.maxY - minSize, start.origin.y + dy))
            b.origin.y = newMinY
            b.size.height = start.maxY - newMinY
        case .bottom:
            b.size.height = max(minSize, min(1 - start.origin.y, start.height + dy))
        case .topLeft:
            let newMinX = max(0, min(start.maxX - minSize, start.origin.x + dx))
            let newMinY = max(0, min(start.maxY - minSize, start.origin.y + dy))
            b.origin.x = newMinX
            b.size.width = start.maxX - newMinX
            b.origin.y = newMinY
            b.size.height = start.maxY - newMinY
        case .topRight:
            let newMinY = max(0, min(start.maxY - minSize, start.origin.y + dy))
            b.size.width = max(minSize, min(1 - start.origin.x, start.width + dx))
            b.origin.y = newMinY
            b.size.height = start.maxY - newMinY
        case .bottomLeft:
            let newMinX = max(0, min(start.maxX - minSize, start.origin.x + dx))
            b.origin.x = newMinX
            b.size.width = start.maxX - newMinX
            b.size.height = max(minSize, min(1 - start.origin.y, start.height + dy))
        case .bottomRight:
            b.size.width = max(minSize, min(1 - start.origin.x, start.width + dx))
            b.size.height = max(minSize, min(1 - start.origin.y, start.height + dy))
        }
        return b
    }
}

/// Lightweight checkerboard so real transparency reads correctly in the canvas
/// and preview.
struct CheckerboardView: View {
    var square: CGFloat = 10
    var light = Color(white: 0.30)
    var dark = Color(white: 0.22)

    var body: some View {
        Canvas { context, size in
            let cols = Int((size.width / square).rounded(.up))
            let rows = Int((size.height / square).rounded(.up))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            guard cols > 0, rows > 0 else { return }
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 1 {
                    let rect = CGRect(
                        x: CGFloat(col) * square,
                        y: CGFloat(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(dark))
                }
            }
        }
        .drawingGroup()
    }
}
