import AppKit
import Foundation
import SwiftUI

enum BrushShape: String, CaseIterable {
    case circle = "Circle"
    case square = "Square"
}

/// Pen region-drawing mode: freehand bezier dots, or drag-to-cut geometric shapes.
enum PenShape: String, CaseIterable {
    case free = "Free"
    case rectangle = "Rect"
    case ellipse = "Ellipse"
}

struct PolygonVertex: Equatable {
    var anchor: CGPoint
    var controlIn: CGPoint?
    var controlOut: CGPoint?
}

final class EditorViewModel: ObservableObject {
    @Published var sourceImage: NSImage?
    @Published var originalImage: NSImage?
    @Published var previewImage: NSImage?
    @Published var cropRectNormalized: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @Published var selectedAspectPreset: AspectPreset = .free
    @Published var resizeWidth: String = ""
    @Published var resizeHeight: String = ""
    @Published var autoSizeToCrop = true
    @Published var fileName: String = ""
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var isSaving = false
    @Published var isRenderingPreview = false
    @Published var isRunningShellAction = false
    @Published var lastShellCommandOutput: String = ""
    @Published var needsPersistentFolderAccess = false
    @Published var pendingAccessFolderName = ""
    @Published var isEraseMode = false
    @Published var isRestoreMode = false
    @Published var eraseBrushSize: CGFloat = 20
    @Published var eraseBrushHardness: CGFloat = 1.0
    @Published var eraseFeather: CGFloat = 0
    @Published var brushShape: BrushShape = .circle
    /// When true, the Brush/Pen tools remove only near-black background (using the
    /// Luma Key threshold/softness) within the painted area, keeping bright art.
    @Published var eraseBackgroundOnly = false
    @Published var currentEraseStroke: [CGPoint] = []
    @Published var zoomScale: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    @Published var isPolygonMode = false
    @Published var penShape: PenShape = .free
    @Published var polygonVertices: [PolygonVertex] = []
    @Published var isWandMode = false
    @Published var wandTolerance: CGFloat = 32
    @Published var wandContiguous = true
    @Published var wandSelectionMask: CGImage?
    @Published var wandContourPath: CGPath?
    @Published var isRunningWand = false
    @Published var isSliceMode = false
    @Published var sliceRows: String = "4"
    @Published var sliceColumns: String = "4"
    @Published var sliceAutoDetect = false
    @Published var spritePadding: String = "2"
    @Published var spriteMinSize: String = "16"
    @Published var spriteGap: String = "2"
    @Published var detectedSpriteBoxes: [CGRect] = []
    @Published var isDetectingSprites = false
    @Published var isRunningLumaKey = false
    @Published var lumaKeyThreshold: CGFloat = 30
    @Published var lumaKeySoftness: CGFloat = 20
    @Published var lumaKeyFeather: CGFloat = 2
    @Published var lumaLivePreview: NSImage?
    @Published var isDetectingDarkSpots = false
    @Published var detectedDarkSpots: [DarkSpot] = [] {
        didSet { darkSpotShapes = detectedDarkSpots.map(Self.shapeNSImage) }
    }
    /// Shape overlays (transparent-bg region images) aligned 1:1 with `detectedDarkSpots`.
    private(set) var darkSpotShapes: [NSImage?] = []
    @Published var darkSpotMinSize: String = "16"
    /// When true, Detect Dark Spots also returns the edge-connected regions a luma
    /// key would remove (so they can be taken out selectively instead of all at once).
    @Published var darkSpotIncludeEdges = false
    @Published var isDetectingRemovedSpots = false
    @Published var detectedRemovedSpots: [DarkSpot] = [] {
        didSet { removedSpotShapes = detectedRemovedSpots.map(Self.shapeNSImage) }
    }
    /// Shape overlays aligned 1:1 with `detectedRemovedSpots`.
    private(set) var removedSpotShapes: [NSImage?] = []
    @Published var removedSpotMinSize: String = "16"
    // Smart Cutout: detect the main shape, preview it in red, refine it, then cut
    // everything around it away onto a transparent background.
    @Published var isDetectingShape = false
    @Published var shapeTolerance: CGFloat = 60
    @Published var shapeEdgeFeather: CGFloat = 2
    @Published var shapeKeepLargest = true
    /// Auto-run Detect Shape whenever a new image is opened.
    @Published var autoDetectShapeOnOpen = true
    /// Refine brush active — paint to add to / remove from the red selection.
    @Published var isShapeRefineMode = false
    /// Refine brush mode: true paints the shape in (include), false paints it out.
    @Published var shapeRefineAdd = false
    /// Full-size red-overlay source (white subject on transparent bg) shown in the
    /// canvas while a shape detection is active. Nil when there's no detection.
    @Published var shapeOverlayImage: NSImage?
    /// The editable full-size keep mask (255 = subject). Source of truth for the
    /// overlay and for Extract; mutated by expand/shrink and the refine brush.
    private var shapeWorkingMask: CGImage?
    private var shapeMaskUndoStack: [CGImage] = []
    private var shapeMaskRedoStack: [CGImage] = []
    @Published var isSpriteBoxEditMode = false
    /// Number of bake operations currently in flight. Gates undo/redo/save so the
    /// snapshot history can't be mutated underneath an outstanding bake.
    @Published private(set) var inFlightEdits = 0

    // Quality-of-life toggles.
    @Published var trimOnSave = false
    @Published var snapPowerOfTwo = false
    @Published var exportAtlas = false

    var hasWandSelection: Bool {
        wandSelectionMask != nil
    }

    private let launchImagePath: String?
    private var erasedCGImage: CGImage?

    /// Serial queue that owns the baking pipeline so destructive ops chain in
    /// order instead of racing. `pipelineImage` is only touched on this queue and
    /// mirrors `erasedCGImage`, so each op composes on the previous op's result.
    private let editQueue = DispatchQueue(label: "com.zxcropper.edit", qos: .userInitiated)
    private var pipelineImage: CGImage?

    /// Snapshot history of the baked processed image (`erasedCGImage`). Every
    /// destructive op (erase, pen, wand, luma key, dark-spot removal, restore)
    /// bakes into this image and pushes the previous state so Cmd+Z works
    /// uniformly across all of them.
    private var imageUndoStack: [CGImage?] = []
    private var imageRedoStack: [CGImage?] = []
    private let maxHistory = 12

    var hasEdits: Bool {
        erasedCGImage != nil
    }

    var isDrawingPolygon: Bool {
        !polygonVertices.isEmpty
    }

    var canUndo: Bool {
        (isDrawingPolygon && !vertexUndoStack.isEmpty)
            || canUndoShapeMask
            || (inFlightEdits == 0 && !imageUndoStack.isEmpty)
    }

    var canRedo: Bool {
        (isDrawingPolygon && !vertexRedoStack.isEmpty)
            || canRedoShapeMask
            || (inFlightEdits == 0 && !imageRedoStack.isEmpty)
    }

    private var vertexUndoStack: [[PolygonVertex]] = []
    private var vertexRedoStack: [[PolygonVertex]] = []
    private var loadedImage: LoadedImage?
    private var previewGeneration = 0
    private var lumaPreviewGeneration = 0
    private var shapeDetectionGeneration = 0
    private var pendingImageURLForAccess: URL?

    init(imagePath: String?) {
        launchImagePath = imagePath
        _ = PermissionAccessManager.shared
    }

    var hasLoadedImage: Bool {
        loadedImage != nil
    }

    /// The current working image (baked edits if any, otherwise the original).
    private func currentBaseImage() -> CGImage? {
        erasedCGImage ?? loadedImage?.cgImage
    }

    var imagePixelSize: CGSize {
        guard let cg = currentBaseImage() else { return .zero }
        return CGSize(width: cg.width, height: cg.height)
    }

    func onAppear() {
        guard loadedImage == nil else {
            return
        }

        loadFromLaunchPath()
    }

    func cancelAndClose() {
        NSApplication.shared.terminate(nil)
    }

    func updateCropRect(_ rect: CGRect) {
        // Interactive resize/move already enforces the aspect ratio (anchored to
        // the fixed handle) in the canvas, so here we only clamp into bounds —
        // no re-centering, which is what made locked-ratio drags feel jumpy.
        cropRectNormalized = ImagePipeline.clampNormalizedRect(rect)

        if autoSizeToCrop {
            applyResizeToCurrentCrop()
        } else {
            schedulePreviewRender()
        }
    }

    func setAspectPreset(_ preset: AspectPreset) {
        selectedAspectPreset = preset
        cropRectNormalized = constrainedCropRect(from: cropRectNormalized, ratio: preset.ratio)

        if autoSizeToCrop {
            applyResizeToCurrentCrop()
        } else {
            schedulePreviewRender()
        }
    }

    func updateResizeWidth(_ value: String) {
        autoSizeToCrop = false
        resizeWidth = value.filter(\.isNumber)
        schedulePreviewRender()
    }

    func updateResizeHeight(_ value: String) {
        autoSizeToCrop = false
        resizeHeight = value.filter(\.isNumber)
        schedulePreviewRender()
    }

    func setAutoSizeToCrop(_ enabled: Bool) {
        autoSizeToCrop = enabled

        if enabled {
            applyResizeToCurrentCrop()
        }
    }

    func setTrimOnSave(_ enabled: Bool) {
        trimOnSave = enabled
        schedulePreviewRender()
    }

    func setSnapPowerOfTwo(_ enabled: Bool) {
        snapPowerOfTwo = enabled
        if autoSizeToCrop {
            applyResizeToCurrentCrop()
        } else {
            schedulePreviewRender()
        }
    }

    func normalizeResizeFields() {
        guard let loadedImage else {
            return
        }

        if autoSizeToCrop {
            let cropSize = outputPixelSize(from: currentBaseImage() ?? loadedImage.cgImage)
            resizeWidth = String(Int(cropSize.width))
            resizeHeight = String(Int(cropSize.height))
            return
        }

        let fallbackWidth = loadedImage.cgImage.width
        let fallbackHeight = loadedImage.cgImage.height

        var width = max(1, Int(resizeWidth) ?? fallbackWidth)
        var height = max(1, Int(resizeHeight) ?? fallbackHeight)
        if snapPowerOfTwo {
            width = nearestPowerOfTwo(width)
            height = nearestPowerOfTwo(height)
        }

        resizeWidth = String(width)
        resizeHeight = String(height)
    }

    func resetCrop() {
        cropRectNormalized = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)

        if autoSizeToCrop {
            applyResizeToCurrentCrop()
        } else {
            schedulePreviewRender()
        }
    }

    func doneAndSave() {
        guard let loadedImage else {
            return
        }

        // Never save while a bake is mid-flight — the pending result would be lost.
        guard !isRunningLumaKey, !isRunningShellAction, !isSaving, inFlightEdits == 0 else {
            infoMessage = "Hang on — finishing the current operation…"
            return
        }

        errorMessage = nil
        infoMessage = nil
        normalizeResizeFields()

        let crop = cropRectNormalized
        let outputSize = resolvedOutputSize(fallback: loadedImage.cgImage)
        let sourceCG = currentBaseImage() ?? loadedImage.cgImage
        let sourceURL = loadedImage.url
        let sourceProperties = loadedImage.sourceProperties
        let trim = trimOnSave

        isSaving = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var finalImage = try ImagePipeline.render(
                    cgImage: sourceCG,
                    cropRectNormalized: crop,
                    outputPixels: outputSize
                )

                if trim {
                    finalImage = ImagePipeline.trimTransparent(cgImage: finalImage)
                }

                let backupURL = try ImagePipeline.saveReplacingOriginal(
                    image: finalImage,
                    originalURL: sourceURL,
                    sourceProperties: sourceProperties
                )

                DispatchQueue.main.async {
                    self.isSaving = false
                    self.errorMessage = nil
                    self.infoMessage = "Saved and backed up as \(backupURL.lastPathComponent)"
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func runShellAction(_ action: ShellImageAction) {
        guard let loadedImage else {
            return
        }

        guard !isRunningShellAction, !isSaving else {
            return
        }

        isRunningShellAction = true
        errorMessage = nil
        infoMessage = "Running \(action.commandName)..."

        let currentInputURL = loadedImage.url

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ShellActionRunner.run(action: action, inputURL: currentInputURL)

            DispatchQueue.main.async {
                self.isRunningShellAction = false
                self.lastShellCommandOutput = [result.stdout, result.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                if result.exitCode != 0 {
                    let stderrSummary = result.stderr
                        .split(separator: "\n")
                        .suffix(2)
                        .joined(separator: " ")
                    self.errorMessage = stderrSummary.isEmpty
                        ? "\(action.commandName) failed with exit code \(result.exitCode)."
                        : stderrSummary
                    return
                }

                if let outputURL = result.outputImageURL {
                    self.resetEditsForReload()
                    self.loadImage(at: outputURL)
                    self.infoMessage = "\(action.commandName) completed. Loaded \(outputURL.lastPathComponent)."
                } else {
                    self.infoMessage = "\(action.commandName) completed. No single output image detected to reload."
                }
            }
        }
    }

    // MARK: - Luma key

    func runLumaKey() {
        guard hasLoadedImage else { return }
        guard !isRunningLumaKey, !isSaving, !isRunningShellAction, inFlightEdits == 0 else { return }

        let threshold = lumaKeyThreshold
        let softness = lumaKeySoftness
        let feather = lumaKeyFeather

        isRunningLumaKey = true
        errorMessage = nil
        infoMessage = "Running luma key..."
        clearLumaPreview()

        runEdit(completion: { [weak self] ok in
            self?.isRunningLumaKey = false
            if ok { self?.infoMessage = "Luma key completed." }
        }) { base in
            try ImagePipeline.lumaKey(
                cgImage: base,
                threshold: threshold,
                softness: softness,
                feather: feather
            )
        }
    }

    /// Debounced low-res luma key preview shown live in the canvas while the
    /// sliders are adjusted (crop/off mode only). Bake with Run for full res.
    func scheduleLumaPreview() {
        guard hasLoadedImage,
              !isEraseMode, !isPolygonMode, !isWandMode, !isRestoreMode, !isSliceMode,
              !isRunningLumaKey else { return }
        lumaPreviewGeneration += 1
        let generation = lumaPreviewGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, generation == self.lumaPreviewGeneration else { return }
            self.runLumaPreview(generation: generation)
        }
    }

    private func runLumaPreview(generation: Int) {
        guard let base = currentBaseImage() else { return }
        let threshold = lumaKeyThreshold
        let softness = lumaKeySoftness
        let feather = lumaKeyFeather

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let small = ImagePipeline.downscale(base, maxEdge: 760)
            let fscale = CGFloat(small.width) / CGFloat(max(1, base.width))
            guard let keyed = try? ImagePipeline.lumaKey(
                cgImage: small,
                threshold: threshold,
                softness: softness,
                feather: feather * fscale
            ) else { return }
            let img = NSImage(cgImage: keyed, size: NSSize(width: keyed.width, height: keyed.height))
            DispatchQueue.main.async {
                guard generation == self.lumaPreviewGeneration else { return }
                self.lumaLivePreview = img
            }
        }
    }

    func clearLumaPreview() {
        lumaPreviewGeneration += 1
        if lumaLivePreview != nil { lumaLivePreview = nil }
    }

    // MARK: - Dark spots (remove)

    func updateDarkSpotMinSize(_ value: String) {
        darkSpotMinSize = value.filter(\.isNumber)
    }

    var resolvedDarkSpotMinSize: Int {
        max(1, Int(darkSpotMinSize) ?? 16)
    }

    func setDarkSpotIncludeEdges(_ enabled: Bool) {
        darkSpotIncludeEdges = enabled
        if !detectedDarkSpots.isEmpty {
            detectDarkSpots()
        }
    }

    func detectDarkSpots() {
        guard let base = currentBaseImage() else { return }
        let threshold = lumaKeyThreshold
        let minSize = resolvedDarkSpotMinSize
        let includeEdges = darkSpotIncludeEdges

        isDetectingDarkSpots = true
        errorMessage = nil
        detectedDarkSpots = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let spots = try ImagePipeline.detectDarkSpots(
                    cgImage: base,
                    threshold: threshold,
                    minSize: minSize,
                    includeBorderConnected: includeEdges
                )
                DispatchQueue.main.async {
                    self.detectedDarkSpots = spots
                    self.isDetectingDarkSpots = false
                    if spots.isEmpty {
                        self.infoMessage = includeEdges
                            ? "No dark spots detected."
                            : "No dark spots detected inside asset."
                    } else {
                        self.infoMessage = "Detected \(spots.count) dark spot\(spots.count == 1 ? "" : "s"). Click any to remove\(spots.count > 1 ? ", or Remove All" : "")."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isDetectingDarkSpots = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearDarkSpots() {
        detectedDarkSpots = []
    }

    func removeAllDarkSpots() {
        guard !isSaving, inFlightEdits == 0, hasLoadedImage else { return }
        let masks = detectedDarkSpots.map { $0.mask }
        guard !masks.isEmpty else { return }
        let count = masks.count

        isSaving = true
        errorMessage = nil
        infoMessage = "Removing \(count) spot\(count == 1 ? "" : "s")..."

        runEdit(completion: { [weak self] ok in
            self?.isSaving = false
            if ok {
                self?.detectedDarkSpots = []
                self?.infoMessage = "Removed \(count) spot\(count == 1 ? "" : "s")."
            }
        }) { base in
            guard let combined = ImagePipeline.combineMasks(masks) else { return base }
            return try ImagePipeline.applyEraseMask(
                cgImage: base, strokes: [], polygons: [],
                brushSize: 1, selectionMask: combined
            )
        }
    }

    func removeDarkSpot(at index: Int) {
        guard !isSaving, inFlightEdits == 0 else { return }
        guard index >= 0, index < detectedDarkSpots.count, hasLoadedImage else { return }
        let spot = detectedDarkSpots[index]

        isSaving = true
        errorMessage = nil
        infoMessage = "Removing dark spot..."

        runEdit(completion: { [weak self] ok in
            guard let self else { return }
            self.isSaving = false
            guard ok else { return }
            if index < self.detectedDarkSpots.count {
                self.detectedDarkSpots.remove(at: index)
            }
            let remaining = self.detectedDarkSpots.count
            self.infoMessage = remaining > 0
                ? "Spot removed. \(remaining) remaining."
                : "Spot removed. No more detected spots."
        }) { base in
            try ImagePipeline.applyEraseMask(
                cgImage: base,
                strokes: [], polygons: [],
                brushSize: 1, brushShape: .circle, brushHardness: 1.0, feather: 0,
                selectionMask: spot.mask
            )
        }
    }

    var darkSpotBoxesNormalized: [CGRect] {
        normalizedBoxes(for: detectedDarkSpots)
    }

    // MARK: - Removed spots (restore)

    func updateRemovedSpotMinSize(_ value: String) {
        removedSpotMinSize = value.filter(\.isNumber)
    }

    var resolvedRemovedSpotMinSize: Int {
        max(1, Int(removedSpotMinSize) ?? 16)
    }

    func detectRemovedSpots() {
        guard let loadedImage, let base = currentBaseImage() else { return }
        let original = loadedImage.cgImage
        let minSize = resolvedRemovedSpotMinSize

        isDetectingRemovedSpots = true
        errorMessage = nil
        detectedRemovedSpots = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let spots = try ImagePipeline.detectRemovedSpots(
                    processed: base,
                    original: original,
                    minSize: minSize
                )
                DispatchQueue.main.async {
                    self.detectedRemovedSpots = spots
                    self.isDetectingRemovedSpots = false
                    if spots.isEmpty {
                        self.infoMessage = "No enclosed removed areas found. Use the Restore brush for edge-connected areas."
                    } else {
                        self.infoMessage = "Found \(spots.count) removed area\(spots.count == 1 ? "" : "s"). Click any to restore."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isDetectingRemovedSpots = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearRemovedSpots() {
        detectedRemovedSpots = []
    }

    func restoreRemovedSpot(at index: Int) {
        guard !isSaving, inFlightEdits == 0 else { return }
        guard index >= 0, index < detectedRemovedSpots.count, let loadedImage else { return }
        let spot = detectedRemovedSpots[index]
        let original = loadedImage.cgImage

        isSaving = true
        errorMessage = nil
        infoMessage = "Restoring area..."

        runEdit(completion: { [weak self] ok in
            guard let self else { return }
            self.isSaving = false
            guard ok else { return }
            if index < self.detectedRemovedSpots.count {
                self.detectedRemovedSpots.remove(at: index)
            }
            let remaining = self.detectedRemovedSpots.count
            self.infoMessage = remaining > 0
                ? "Area restored. \(remaining) remaining."
                : "Area restored. No more detected areas."
        }) { base in
            try ImagePipeline.restore(
                base: base, original: original,
                strokes: [], polygons: [],
                brushSize: 1, selectionMask: spot.mask
            )
        }
    }

    var removedSpotBoxesNormalized: [CGRect] {
        normalizedBoxes(for: detectedRemovedSpots)
    }

    // MARK: - Smart Cutout (detect shape → refine → extract)

    var hasShapeDetection: Bool {
        shapeWorkingMask != nil
    }

    func setShapeKeepLargest(_ enabled: Bool) {
        shapeKeepLargest = enabled
        if hasShapeDetection { scheduleShapeDetection() }
    }

    /// Runs a full-resolution detection and shows the red overlay.
    func detectShape() {
        guard hasLoadedImage else { return }
        guard !isSaving, !isRunningLumaKey, !isRunningShellAction, inFlightEdits == 0 else { return }
        isDetectingShape = true
        errorMessage = nil
        infoMessage = "Detecting shape..."
        shapeDetectionGeneration += 1
        performDetection(generation: shapeDetectionGeneration)
    }

    /// Debounced re-detection used when tolerance / keep-largest change while a
    /// detection is already on screen. A fresh detection replaces the working mask
    /// and clears refine history (tolerance is a from-scratch decision).
    func scheduleShapeDetection() {
        guard hasShapeDetection, hasLoadedImage else { return }
        shapeDetectionGeneration += 1
        let generation = shapeDetectionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, generation == self.shapeDetectionGeneration else { return }
            self.isDetectingShape = true
            self.performDetection(generation: generation)
        }
    }

    private func performDetection(generation: Int) {
        guard let base = currentBaseImage() else { isDetectingShape = false; return }
        let tolerance = shapeTolerance
        let keepLargest = shapeKeepLargest
        let pixels = base.width * base.height

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let detection = try? ImagePipeline.detectForegroundShape(
                cgImage: base, tolerance: tolerance, keepLargest: keepLargest
            )
            DispatchQueue.main.async {
                guard generation == self.shapeDetectionGeneration else { return }
                self.isDetectingShape = false
                self.shapeMaskUndoStack.removeAll()
                self.shapeMaskRedoStack.removeAll()
                guard let detection, detection.pixelCount > 0 else {
                    self.shapeWorkingMask = nil
                    self.shapeOverlayImage = nil
                    self.isShapeRefineMode = false
                    self.infoMessage = "No shape found — lower the tolerance and try again."
                    return
                }
                self.setWorkingMask(detection.mask)
                let coverage = Double(detection.pixelCount) / Double(max(1, pixels))
                self.infoMessage = coverage > 0.985
                    ? "Almost everything is selected — raise the tolerance to separate the shape from its background."
                    : "Shape detected (red). Expand/Shrink or Refine the selection, then Extract & Crop."
            }
        }
    }

    /// Updates the working mask and rebuilds the red overlay from it.
    private func setWorkingMask(_ mask: CGImage) {
        shapeWorkingMask = mask
        shapeOverlayImage = ImagePipeline.keepMaskOverlay(mask).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
    }

    private func pushShapeMaskHistory() {
        guard let mask = shapeWorkingMask else { return }
        shapeMaskUndoStack.append(mask)
        if shapeMaskUndoStack.count > maxHistory { shapeMaskUndoStack.removeFirst() }
        shapeMaskRedoStack.removeAll()
    }

    /// Per-image expand/shrink step in pixels (~0.4% of the short edge, min 2px).
    private var shapeMorphStep: Int {
        guard let mask = shapeWorkingMask else { return 3 }
        return max(2, Int((CGFloat(min(mask.width, mask.height)) * 0.004).rounded()))
    }

    func expandShape() { morphWorkingMask(by: shapeMorphStep, label: "Expanded selection.") }
    func shrinkShape() { morphWorkingMask(by: -shapeMorphStep, label: "Shrank selection.") }

    private func morphWorkingMask(by radius: Int, label: String) {
        guard let mask = shapeWorkingMask,
              let result = ImagePipeline.morphMask(mask, radius: radius) else { return }
        pushShapeMaskHistory()
        setWorkingMask(result)
        infoMessage = label
    }

    func setShapeRefineMode(_ on: Bool) {
        isShapeRefineMode = on
        if on {
            isEraseMode = false
            isPolygonMode = false
            isWandMode = false
            isRestoreMode = false
            isSliceMode = false
            cancelPolygon()
            clearWandSelection()
            clearLumaPreview()
        }
    }

    /// Paints one refine stroke into the working mask (add or remove).
    private func applyShapeRefineStroke(_ stroke: [CGPoint]) {
        guard let mask = shapeWorkingMask, !stroke.isEmpty else { return }
        guard let result = try? ImagePipeline.paintShapeMask(
            mask: mask, stroke: stroke,
            brushSize: eraseBrushSize, brushShape: brushShape,
            brushHardness: eraseBrushHardness, add: shapeRefineAdd
        ) else { return }
        pushShapeMaskHistory()
        setWorkingMask(result)
    }

    var canUndoShapeMask: Bool { hasShapeDetection && !shapeMaskUndoStack.isEmpty }
    var canRedoShapeMask: Bool { hasShapeDetection && !shapeMaskRedoStack.isEmpty }

    func undoShapeMask() {
        guard let mask = shapeWorkingMask, !shapeMaskUndoStack.isEmpty else { return }
        shapeMaskRedoStack.append(mask)
        setWorkingMask(shapeMaskUndoStack.removeLast())
    }

    func redoShapeMask() {
        guard let mask = shapeWorkingMask, !shapeMaskRedoStack.isEmpty else { return }
        shapeMaskUndoStack.append(mask)
        setWorkingMask(shapeMaskRedoStack.removeLast())
    }

    /// Bakes the cutout: keeps the refined selection and makes everything else
    /// transparent, then fits the crop box to the shape.
    func extractShape() {
        guard let mask = shapeWorkingMask, hasLoadedImage else { return }
        guard !isSaving, !isRunningLumaKey, !isRunningShellAction, inFlightEdits == 0 else { return }

        let box = ImagePipeline.maskBoundingBox(mask)
        guard box.width > 0, box.height > 0 else {
            errorMessage = "The selection is empty — adjust it and try again."
            return
        }

        let feather = shapeEdgeFeather
        isSaving = true
        errorMessage = nil
        infoMessage = "Extracting shape..."
        isShapeRefineMode = false

        runEdit(completion: { [weak self] ok in
            guard let self else { return }
            self.isSaving = false
            guard ok else { return }
            self.clearShapeDetection()
            self.fitCropToPixelBox(box)
            self.infoMessage = "Shape extracted onto a transparent background."
        }) { editBase in
            try ImagePipeline.applyKeepMask(cgImage: editBase, keepMask: mask, feather: feather)
        }
    }

    func clearShapeDetection() {
        shapeDetectionGeneration += 1
        isDetectingShape = false
        isShapeRefineMode = false
        shapeWorkingMask = nil
        shapeMaskUndoStack.removeAll()
        shapeMaskRedoStack.removeAll()
        if shapeOverlayImage != nil { shapeOverlayImage = nil }
    }

    /// Sets the crop rectangle to a pixel-space bounding box (top-left origin) with
    /// a small padding so feathered edges aren't clipped.
    private func fitCropToPixelBox(_ box: CGRect) {
        guard let cg = currentBaseImage(), cg.width > 0, cg.height > 0,
              box.width > 0, box.height > 0 else { return }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let padX = max(1, box.width * 0.02)
        let padY = max(1, box.height * 0.02)
        let x0 = max(0, box.minX - padX)
        let y0 = max(0, box.minY - padY)
        let x1 = min(w, box.maxX + padX)
        let y1 = min(h, box.maxY + padY)
        selectedAspectPreset = .free
        cropRectNormalized = ImagePipeline.clampNormalizedRect(
            CGRect(x: x0 / w, y: y0 / h, width: (x1 - x0) / w, height: (y1 - y0) / h)
        )
        if autoSizeToCrop {
            applyResizeToCurrentCrop()
        } else {
            schedulePreviewRender()
        }
    }

    private static func shapeNSImage(_ spot: DarkSpot) -> NSImage? {
        guard let cg = spot.shapeImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func normalizedBoxes(for spots: [DarkSpot]) -> [CGRect] {
        guard let cg = currentBaseImage(), cg.width > 0, cg.height > 0 else { return [] }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        return spots.map {
            CGRect(x: $0.boundingBox.minX / w, y: $0.boundingBox.minY / h,
                   width: $0.boundingBox.width / w, height: $0.boundingBox.height / h)
        }
    }

    func grantPersistentFolderAccess() {
        guard let pendingURL = pendingImageURLForAccess else {
            return
        }

        if let grantedFolder = PermissionAccessManager.shared.requestFolderAccess(startingAt: pendingURL.deletingLastPathComponent()) {
            needsPersistentFolderAccess = false
            pendingAccessFolderName = ""
            errorMessage = nil
            infoMessage = "Access granted to \(grantedFolder.lastPathComponent)."
            loadImage(at: pendingURL)
        } else {
            errorMessage = "Folder access not granted. You can try again."
        }
    }

    // MARK: - Tool selection

    /// Segmented edit-tool selection. 0 = off, 1 = brush, 2 = pen, 3 = wand,
    /// 4 = restore brush.
    func selectEditTool(_ tag: Int) {
        isEraseMode = tag == 1
        isPolygonMode = tag == 2
        isWandMode = tag == 3
        isRestoreMode = tag == 4
        if tag != 0 { isSliceMode = false }
        isShapeRefineMode = false
        if tag != 2 { cancelPolygon() }
        if tag != 3 { clearWandSelection() }
        clearLumaPreview()
    }

    var currentEditTool: Int {
        if isRestoreMode { return 4 }
        if isWandMode { return 3 }
        if isPolygonMode { return 2 }
        if isEraseMode { return 1 }
        return 0
    }

    /// Keyboard tool hotkeys 1–5 (crop / brush / pen / wand / slice).
    func selectTool(_ number: Int) {
        guard hasLoadedImage else { return }
        switch number {
        case 1: selectEditTool(0); isSliceMode = false
        case 2: selectEditTool(1)
        case 3: selectEditTool(2)
        case 4: selectEditTool(3)
        case 5: if !isSliceMode { toggleSliceMode() }
        default: break
        }
    }

    func addErasePoint(_ point: CGPoint) {
        currentEraseStroke.append(point)
    }

    func endEraseStroke() {
        guard !currentEraseStroke.isEmpty else { return }
        let stroke = currentEraseStroke
        currentEraseStroke.removeAll()

        // In Smart Cutout refine mode the brush edits the red selection mask
        // instead of baking into the image.
        if isShapeRefineMode {
            applyShapeRefineStroke(stroke)
            return
        }

        guard let original = loadedImage?.cgImage else { return }

        let restore = isRestoreMode
        let backgroundOnly = eraseBackgroundOnly
        let threshold = lumaKeyThreshold
        let softness = lumaKeySoftness
        let size = eraseBrushSize
        let shape = brushShape
        let hardness = eraseBrushHardness
        let feather = eraseFeather

        runEdit { base in
            if restore {
                return try ImagePipeline.restore(
                    base: base, original: original,
                    strokes: [stroke], polygons: [],
                    brushSize: size, brushShape: shape, brushHardness: hardness, feather: feather
                )
            } else if backgroundOnly {
                return try ImagePipeline.eraseBackground(
                    cgImage: base,
                    strokes: [stroke], polygons: [],
                    brushSize: size, brushShape: shape, brushHardness: hardness, feather: feather,
                    threshold: threshold, softness: softness
                )
            } else {
                return try ImagePipeline.applyEraseMask(
                    cgImage: base,
                    strokes: [stroke], polygons: [],
                    brushSize: size, brushShape: shape, brushHardness: hardness, feather: feather
                )
            }
        }
    }

    func togglePolygonMode() {
        selectEditTool(isPolygonMode ? 0 : 2)
    }

    func toggleSliceMode() {
        isSliceMode.toggle()
        if isSliceMode {
            isEraseMode = false
            isPolygonMode = false
            isWandMode = false
            isRestoreMode = false
            isShapeRefineMode = false
            cancelPolygon()
            clearWandSelection()
            clearLumaPreview()
            if sliceAutoDetect {
                detectSprites()
            }
        }
    }

    func setSliceAutoDetect(_ enabled: Bool) {
        sliceAutoDetect = enabled
        if enabled && isSliceMode {
            detectSprites()
        }
    }

    func updateSliceRows(_ value: String) {
        sliceRows = value.filter(\.isNumber)
    }

    func updateSliceColumns(_ value: String) {
        sliceColumns = value.filter(\.isNumber)
    }

    func updateSpritePadding(_ value: String) {
        spritePadding = value.filter(\.isNumber)
        if sliceAutoDetect && isSliceMode { detectSprites() }
    }

    func updateSpriteMinSize(_ value: String) {
        spriteMinSize = value.filter(\.isNumber)
        if sliceAutoDetect && isSliceMode { detectSprites() }
    }

    func updateSpriteGap(_ value: String) {
        spriteGap = value.filter(\.isNumber)
        if sliceAutoDetect && isSliceMode { detectSprites() }
    }

    var resolvedSliceRows: Int {
        max(1, Int(sliceRows) ?? 1)
    }

    var resolvedSliceColumns: Int {
        max(1, Int(sliceColumns) ?? 1)
    }

    var resolvedSpritePadding: Int {
        max(0, Int(spritePadding) ?? 0)
    }

    var resolvedSpriteMinSize: Int {
        max(1, Int(spriteMinSize) ?? 1)
    }

    var resolvedSpriteGap: Int {
        max(0, Int(spriteGap) ?? 0)
    }

    /// Detected boxes normalized to 0...1 (top-left origin) for the canvas overlay.
    var detectedBoxesNormalized: [CGRect] {
        guard let cg = currentBaseImage(), cg.width > 0, cg.height > 0 else { return [] }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        return detectedSpriteBoxes.map {
            CGRect(x: $0.minX / w, y: $0.minY / h, width: $0.width / w, height: $0.height / h)
        }
    }

    func updateSpriteBoxes(_ normalizedBoxes: [CGRect]) {
        guard let cg = currentBaseImage(), cg.width > 0, cg.height > 0 else { return }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        detectedSpriteBoxes = normalizedBoxes.map {
            CGRect(x: $0.minX * w, y: $0.minY * h, width: $0.width * w, height: $0.height * h)
        }
    }

    func addSpriteBox() {
        guard let cg = currentBaseImage(), cg.width > 0, cg.height > 0 else { return }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let newBox = CGRect(x: w * 0.4, y: h * 0.4, width: w * 0.2, height: h * 0.2)
        detectedSpriteBoxes.append(newBox)
        infoMessage = "Box added. Drag it into position and resize with handles."
    }

    func detectSprites() {
        guard let base = currentBaseImage() else { return }
        let padding = resolvedSpritePadding
        let minSize = resolvedSpriteMinSize
        let gap = resolvedSpriteGap
        isDetectingSprites = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let boxes = ImagePipeline.detectSpriteBoxes(
                cgImage: base,
                minDimension: minSize,
                mergeGap: gap,
                padding: padding
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.detectedSpriteBoxes = boxes
                self.isDetectingSprites = false
                if boxes.isEmpty {
                    self.infoMessage = "No sprites detected — try grid mode or adjust min size."
                } else {
                    self.infoMessage = "Detected \(boxes.count) sprite\(boxes.count == 1 ? "" : "s")."
                }
            }
        }
    }

    func exportSprites() {
        guard let loadedImage else {
            return
        }

        guard !isSaving, !isRunningShellAction, !isRunningLumaKey, inFlightEdits == 0 else {
            return
        }

        let sourceURL = loadedImage.url

        guard PermissionAccessManager.shared.canAccess(sourceURL) else {
            pendingImageURLForAccess = sourceURL
            pendingAccessFolderName = sourceURL.deletingLastPathComponent().lastPathComponent
            needsPersistentFolderAccess = true
            errorMessage = "Access required for folder: \(pendingAccessFolderName)."
            return
        }

        let sourceCG = currentBaseImage() ?? loadedImage.cgImage
        let atlas = exportAtlas

        if sliceAutoDetect {
            let padding = resolvedSpritePadding
            let minSize = resolvedSpriteMinSize
            let gap = resolvedSpriteGap
            let known = detectedSpriteBoxes
            errorMessage = nil
            infoMessage = "Exporting sprites..."
            isSaving = true

            DispatchQueue.global(qos: .userInitiated).async {
                let boxes = known.isEmpty
                    ? ImagePipeline.detectSpriteBoxes(cgImage: sourceCG, minDimension: minSize, mergeGap: gap, padding: padding)
                    : known
                do {
                    guard !boxes.isEmpty else {
                        DispatchQueue.main.async {
                            self.isSaving = false
                            self.errorMessage = "No sprites detected to export."
                        }
                        return
                    }
                    let folderURL = try ImagePipeline.exportSprites(
                        cgImage: sourceCG,
                        boxes: boxes,
                        sourceURL: sourceURL,
                        atlas: atlas
                    )
                    DispatchQueue.main.async {
                        self.isSaving = false
                        self.errorMessage = nil
                        self.infoMessage = "Exported \(boxes.count) sprites to \(folderURL.lastPathComponent)\(atlas ? " (+ atlas.png/json)" : "")"
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isSaving = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }

        let rows = resolvedSliceRows
        let columns = resolvedSliceColumns

        guard rows >= 1, columns >= 1 else {
            errorMessage = "Rows and columns must be at least 1."
            return
        }

        errorMessage = nil
        infoMessage = "Exporting sprites..."
        isSaving = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let folderURL = try ImagePipeline.exportSprites(
                    cgImage: sourceCG,
                    rows: rows,
                    columns: columns,
                    sourceURL: sourceURL,
                    atlas: atlas
                )
                let count = rows * columns
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.errorMessage = nil
                    self.infoMessage = "Exported \(count) sprites to \(folderURL.lastPathComponent)\(atlas ? " (+ atlas.png/json)" : "")"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func addPolygonVertex(_ vertex: PolygonVertex) {
        vertexUndoStack.append(polygonVertices)
        vertexRedoStack.removeAll()
        polygonVertices.append(vertex)
    }

    func moveVertex(at index: Int, to anchor: CGPoint) {
        guard index < polygonVertices.count else { return }
        var copy = polygonVertices
        let delta = CGPoint(
            x: anchor.x - copy[index].anchor.x,
            y: anchor.y - copy[index].anchor.y
        )
        copy[index].anchor = anchor
        if let out = copy[index].controlOut {
            copy[index].controlOut = CGPoint(x: out.x + delta.x, y: out.y + delta.y)
        }
        if let cin = copy[index].controlIn {
            copy[index].controlIn = CGPoint(x: cin.x + delta.x, y: cin.y + delta.y)
        }
        polygonVertices = copy
    }

    /// Bends the segment starting at `index` so its curve passes through `point`.
    func curveSegment(at index: Int, through point: CGPoint) {
        let count = polygonVertices.count
        guard count >= 2, index >= 0, index < count else { return }
        let next = (index + 1) % count
        var copy = polygonVertices
        let a = copy[index].anchor
        let b = copy[next].anchor
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let offset = CGPoint(x: point.x - mid.x, y: point.y - mid.y)
        let k: CGFloat = 4.0 / 3.0
        copy[index].controlOut = CGPoint(x: a.x + k * offset.x, y: a.y + k * offset.y)
        copy[next].controlIn = CGPoint(x: b.x + k * offset.x, y: b.y + k * offset.y)
        polygonVertices = copy
    }

    func removeLastVertex() {
        guard !polygonVertices.isEmpty else { return }
        vertexUndoStack.append(polygonVertices)
        vertexRedoStack.removeAll()
        polygonVertices.removeLast()
    }

    func runMagicWand(at point: CGPoint, additive: Bool) {
        guard let base = currentBaseImage() else { return }
        isRunningWand = true
        errorMessage = nil
        let src = base
        let tol = wandTolerance
        let contig = wandContiguous
        let existingMask = additive ? wandSelectionMask : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                var mask = try ImagePipeline.magicWandMask(
                    cgImage: src, at: point,
                    tolerance: tol, contiguous: contig
                )
                if let existing = existingMask {
                    mask = try ImagePipeline.unionMask(existing: existing, with: mask)
                }
                let finalMask = mask
                DispatchQueue.main.async {
                    self.wandSelectionMask = finalMask
                    self.wandContourPath = ImagePipeline.contourPath(from: finalMask)
                    self.isRunningWand = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunningWand = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func invertWandSelection() {
        guard let mask = wandSelectionMask else { return }
        let w = mask.width; let h = mask.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(data: nil, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data,
              let srcData = mask.dataProvider?.data,
              let srcPtr = CFDataGetBytePtr(srcData)
        else { return }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h)
        let srcBytes = mask.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                ptr[y * w + x] = srcPtr[y * srcBytes + x] > 128 ? 0 : 255
            }
        }
        if let inverted = ctx.makeImage() {
            wandSelectionMask = inverted
            wandContourPath = ImagePipeline.contourPath(from: inverted)
        }
    }

    func deleteWandSelection() {
        guard let mask = wandSelectionMask, hasLoadedImage else { return }
        wandSelectionMask = nil
        wandContourPath = nil
        isWandMode = false

        runEdit { base in
            try ImagePipeline.applyEraseMask(
                cgImage: base,
                strokes: [], polygons: [],
                brushSize: 1, selectionMask: mask
            )
        }
    }

    func clearWandSelection() {
        wandSelectionMask = nil
        wandContourPath = nil
    }

    func completePolygon() {
        guard polygonVertices.count >= 3 else {
            cancelPolygon()
            return
        }
        let verts = polygonVertices
        polygonVertices.removeAll()
        vertexUndoStack.removeAll()
        vertexRedoStack.removeAll()
        guard hasLoadedImage else { return }
        let feather = eraseFeather
        let size = eraseBrushSize
        let backgroundOnly = eraseBackgroundOnly
        let threshold = lumaKeyThreshold
        let softness = lumaKeySoftness

        runEdit { base in
            if backgroundOnly {
                return try ImagePipeline.eraseBackground(
                    cgImage: base,
                    strokes: [], polygons: [verts],
                    brushSize: size, feather: feather,
                    threshold: threshold, softness: softness
                )
            }
            return try ImagePipeline.applyEraseMask(
                cgImage: base,
                strokes: [], polygons: [verts],
                brushSize: size, feather: feather
            )
        }
    }

    func cancelPolygon() {
        polygonVertices.removeAll()
        vertexUndoStack.removeAll()
        vertexRedoStack.removeAll()
    }

    /// Cuts a clean rectangle or ellipse defined by a normalized bounding rect —
    /// the easy way to remove a circular/square region. Honors feather and the
    /// "dark background only" toggle.
    func eraseShapeRegion(rect: CGRect, ellipse: Bool) {
        guard hasLoadedImage else { return }
        let r = CGRect(
            x: min(max(0, rect.minX), 1),
            y: min(max(0, rect.minY), 1),
            width: min(rect.width, 1),
            height: min(rect.height, 1)
        )
        guard r.width > 0.004, r.height > 0.004 else { return }

        let verts = Self.shapeVertices(in: r, ellipse: ellipse)
        let backgroundOnly = eraseBackgroundOnly
        let threshold = lumaKeyThreshold
        let softness = lumaKeySoftness
        let feather = eraseFeather
        let size = eraseBrushSize

        runEdit { base in
            if backgroundOnly {
                return try ImagePipeline.eraseBackground(
                    cgImage: base, strokes: [], polygons: [verts],
                    brushSize: size, feather: feather,
                    threshold: threshold, softness: softness
                )
            }
            return try ImagePipeline.applyEraseMask(
                cgImage: base, strokes: [], polygons: [verts],
                brushSize: size, feather: feather
            )
        }
    }

    private static func shapeVertices(in rect: CGRect, ellipse: Bool) -> [PolygonVertex] {
        if !ellipse {
            return [
                PolygonVertex(anchor: CGPoint(x: rect.minX, y: rect.minY)),
                PolygonVertex(anchor: CGPoint(x: rect.maxX, y: rect.minY)),
                PolygonVertex(anchor: CGPoint(x: rect.maxX, y: rect.maxY)),
                PolygonVertex(anchor: CGPoint(x: rect.minX, y: rect.maxY))
            ]
        }
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width / 2
        let ry = rect.height / 2
        let n = 72
        return (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n) * 2 * CGFloat.pi
            return PolygonVertex(anchor: CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t)))
        }
    }

    /// Reverts all baked edits back to the freshly-loaded original.
    func clearErase() {
        guard erasedCGImage != nil, inFlightEdits == 0 else { return }
        pushHistory()
        erasedCGImage = nil
        syncPipeline(to: nil)
        detectedDarkSpots = []
        detectedRemovedSpots = []
        clearShapeDetection()
        refreshDisplay()
        clearLumaPreview()
        schedulePreviewRender()
    }

    func undo() {
        if isDrawingPolygon && !vertexUndoStack.isEmpty {
            vertexRedoStack.append(polygonVertices)
            polygonVertices = vertexUndoStack.removeLast()
            return
        }
        if canUndoShapeMask {
            undoShapeMask()
            return
        }
        guard inFlightEdits == 0, !imageUndoStack.isEmpty else { return }
        imageRedoStack.append(erasedCGImage)
        erasedCGImage = imageUndoStack.removeLast()
        afterHistoryChange()
    }

    func redo() {
        if isDrawingPolygon && !vertexRedoStack.isEmpty {
            vertexUndoStack.append(polygonVertices)
            polygonVertices = vertexRedoStack.removeLast()
            return
        }
        if canRedoShapeMask {
            redoShapeMask()
            return
        }
        guard inFlightEdits == 0, !imageRedoStack.isEmpty else { return }
        imageUndoStack.append(erasedCGImage)
        erasedCGImage = imageRedoStack.removeLast()
        afterHistoryChange()
    }

    private func afterHistoryChange() {
        syncPipeline(to: erasedCGImage)
        detectedDarkSpots = []
        detectedRemovedSpots = []
        clearShapeDetection()
        refreshDisplay()
        clearLumaPreview()
        schedulePreviewRender()
    }

    /// Resets all editing state when a brand-new image is loaded (or reloaded
    /// after a shell action).
    func resetEditsForReload() {
        currentEraseStroke.removeAll()
        polygonVertices.removeAll()
        vertexUndoStack.removeAll()
        vertexRedoStack.removeAll()
        erasedCGImage = nil
        syncPipeline(to: nil)
        inFlightEdits = 0
        wandSelectionMask = nil
        wandContourPath = nil
        imageUndoStack.removeAll()
        imageRedoStack.removeAll()
        detectedDarkSpots = []
        detectedRemovedSpots = []
        clearShapeDetection()
        clearLumaPreview()
    }

    func zoomIn() {
        zoomScale = min(zoomScale * 1.25, 10.0)
        panOffset = .zero
    }

    func zoomOut() {
        zoomScale = max(zoomScale / 1.25, 1.0)
        panOffset = .zero
    }

    func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
    }

    func zoomToScale(_ scale: CGFloat, pan: CGSize) {
        zoomScale = scale
        panOffset = pan
    }

    func setZoomScale(_ scale: CGFloat) {
        zoomScale = min(max(scale, 1.0), 10.0)
    }

    func setPanOffset(_ offset: CGSize) {
        panOffset = offset
    }

    // MARK: - History helpers

    private func pushHistory() {
        imageUndoStack.append(erasedCGImage)
        if imageUndoStack.count > maxHistory {
            imageUndoStack.removeFirst()
        }
        imageRedoStack.removeAll()
    }

    /// Runs one destructive bake on the serial edit queue. Each op composes on
    /// `pipelineImage` (the previous op's result), so rapid strokes never clobber
    /// each other. The result is committed on the main thread in submission order.
    private func runEdit(completion: ((Bool) -> Void)? = nil,
                         _ transform: @escaping (_ base: CGImage) throws -> CGImage) {
        guard let original = loadedImage?.cgImage else { return }
        inFlightEdits += 1
        editQueue.async { [weak self] in
            guard let self else { return }
            let base = self.pipelineImage ?? original
            do {
                let result = try transform(base)
                self.pipelineImage = result
                DispatchQueue.main.async {
                    self.commit(result)
                    self.inFlightEdits = max(0, self.inFlightEdits - 1)
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.inFlightEdits = max(0, self.inFlightEdits - 1)
                    completion?(false)
                }
            }
        }
    }

    /// Keeps the edit-queue's `pipelineImage` in step with the main-thread
    /// `erasedCGImage` after undo / redo / clear / load.
    private func syncPipeline(to image: CGImage?) {
        editQueue.async { [weak self] in self?.pipelineImage = image }
    }

    /// Bakes a new processed image, recording the previous one for undo.
    private func commit(_ image: CGImage) {
        pushHistory()
        erasedCGImage = image
        refreshDisplay()
        clearLumaPreview()
        clearShapeDetection()
        schedulePreviewRender()
    }

    private func refreshDisplay() {
        guard let cg = currentBaseImage() else { return }
        sourceImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Loading

    private func loadFromLaunchPath() {
        guard let launchImagePath, !launchImagePath.isEmpty else {
            errorMessage = "No image path was received. Launch this app from Finder Quick Action: Edit Image, or drag a PNG/WebP onto the window."
            return
        }

        let url = Self.normalizePathArgument(launchImagePath)
        loadImage(at: url)
    }

    func handleOpenFile(at url: URL) {
        resetEditsForReload()
        resetZoom()
        loadImage(at: url)
    }

    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            handleOpenFile(at: url)
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("pasted-\(UUID().uuidString).png")
            do {
                try png.write(to: temp)
                handleOpenFile(at: temp)
                infoMessage = "Loaded pasted image (saved to a temporary file)."
            } catch {
                errorMessage = "Could not load pasted image."
            }
        } else {
            errorMessage = "Clipboard has no image or file to paste."
        }
    }

    private func loadImage(at url: URL) {
        if !PermissionAccessManager.shared.canAccess(url) {
            pendingImageURLForAccess = url
            pendingAccessFolderName = url.deletingLastPathComponent().lastPathComponent
            needsPersistentFolderAccess = true
            isRenderingPreview = false
            errorMessage = "Access required for folder: \(pendingAccessFolderName)."
            return
        }

        errorMessage = nil
        isRenderingPreview = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try ImagePipeline.loadImage(at: url)
                let image = NSImage(
                    cgImage: loaded.cgImage,
                    size: NSSize(width: loaded.cgImage.width, height: loaded.cgImage.height)
                )

                DispatchQueue.main.async {
                    self.loadedImage = loaded
                    self.fileName = loaded.url.lastPathComponent
                    self.sourceImage = image
                    self.originalImage = image
                    self.erasedCGImage = nil
                    self.syncPipeline(to: nil)
                    self.inFlightEdits = 0
                    self.cropRectNormalized = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
                    self.autoSizeToCrop = true
                    self.needsPersistentFolderAccess = false
                    self.pendingImageURLForAccess = nil
                    self.pendingAccessFolderName = ""
                    self.isRenderingPreview = false
                    self.applyResizeToCurrentCrop()
                    self.clearShapeDetection()
                    if self.autoDetectShapeOnOpen {
                        self.detectShape()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRenderingPreview = false
                    if let pipelineError = error as? PipelineError {
                        switch pipelineError {
                        case .permissionDenied:
                            self.pendingImageURLForAccess = url
                            self.pendingAccessFolderName = url.deletingLastPathComponent().lastPathComponent
                            self.needsPersistentFolderAccess = true
                        default:
                            break
                        }
                    }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func schedulePreviewRender() {
        guard let loadedImage else {
            return
        }

        previewGeneration += 1
        let generation = previewGeneration
        let crop = cropRectNormalized
        let outputSize = resolvedOutputSize(fallback: loadedImage.cgImage)
        let sourceCG = currentBaseImage() ?? loadedImage.cgImage
        let trim = trimOnSave

        isRenderingPreview = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let maxPreviewEdge: CGFloat = 440
                let divisor = max(outputSize.width, outputSize.height)
                let scale = divisor > 0 ? min(1.0, maxPreviewEdge / divisor) : 1.0
                let previewSize = CGSize(
                    width: max(1, (outputSize.width * scale).rounded()),
                    height: max(1, (outputSize.height * scale).rounded())
                )

                var rendered = try ImagePipeline.render(
                    cgImage: sourceCG,
                    cropRectNormalized: crop,
                    outputPixels: previewSize
                )

                if trim {
                    rendered = ImagePipeline.trimTransparent(cgImage: rendered)
                }

                let preview = NSImage(
                    cgImage: rendered,
                    size: NSSize(width: rendered.width, height: rendered.height)
                )

                DispatchQueue.main.async {
                    guard generation == self.previewGeneration else {
                        return
                    }

                    self.previewImage = preview
                    self.errorMessage = nil
                    self.isRenderingPreview = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.previewGeneration else {
                        return
                    }

                    self.isRenderingPreview = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func resolvedOutputSize(fallback: CGImage) -> CGSize {
        var width: Int
        var height: Int

        if autoSizeToCrop {
            let cropSize = cropPixelSize(from: currentBaseImage() ?? fallback)
            width = Int(cropSize.width)
            height = Int(cropSize.height)
        } else {
            width = max(1, Int(resizeWidth) ?? fallback.width)
            height = max(1, Int(resizeHeight) ?? fallback.height)
        }

        if snapPowerOfTwo {
            width = nearestPowerOfTwo(width)
            height = nearestPowerOfTwo(height)
        }

        return CGSize(width: max(1, width), height: max(1, height))
    }

    /// Output size as actually written (after power-of-two snapping), for the HUD.
    private func outputPixelSize(from image: CGImage) -> CGSize {
        resolvedOutputSize(fallback: image)
    }

    private func applyResizeToCurrentCrop() {
        guard let loadedImage else {
            return
        }

        let size = resolvedOutputSize(fallback: loadedImage.cgImage)
        resizeWidth = String(Int(size.width))
        resizeHeight = String(Int(size.height))
        schedulePreviewRender()
    }

    private func cropPixelSize(from image: CGImage) -> CGSize {
        let normalized = ImagePipeline.clampNormalizedRect(cropRectNormalized)
        let width = max(1, Int((normalized.width * CGFloat(image.width)).rounded()))
        let height = max(1, Int((normalized.height * CGFloat(image.height)).rounded()))
        return CGSize(width: width, height: height)
    }

    private func nearestPowerOfTwo(_ n: Int) -> Int {
        guard n > 1 else { return 1 }
        let lower = Int(pow(2.0, floor(log2(Double(n)))))
        let upper = lower * 2
        return (n - lower) <= (upper - n) ? lower : upper
    }

    private func constrainedCropRect(from rect: CGRect, ratio inputRatio: CGFloat?) -> CGRect {
        var normalized = ImagePipeline.clampNormalizedRect(rect)

        // Aspect presets are pixel ratios (e.g. 1:1 = a real square). Convert to a
        // normalized-space ratio using the image's pixel aspect so 1:1 is square in
        // pixels even on a non-square image.
        let pixel = imagePixelSize
        guard let inputRatio, inputRatio > 0, pixel.width > 0, pixel.height > 0 else {
            return normalized
        }
        let ratio = inputRatio * (pixel.height / pixel.width)

        let center = CGPoint(x: normalized.midX, y: normalized.midY)
        var width = normalized.width
        var height = normalized.height

        let currentRatio = width / max(height, 0.0001)

        if currentRatio > ratio {
            width = height * ratio
        } else {
            height = width / ratio
        }

        width = min(width, 1)
        height = min(height, 1)

        normalized = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )

        normalized = ImagePipeline.clampNormalizedRect(normalized)

        if normalized.width / max(normalized.height, 0.0001) > ratio {
            normalized.size.width = normalized.height * ratio
        } else {
            normalized.size.height = normalized.width / ratio
        }

        normalized.origin.x = min(max(0, normalized.origin.x), 1 - normalized.width)
        normalized.origin.y = min(max(0, normalized.origin.y), 1 - normalized.height)

        return ImagePipeline.clampNormalizedRect(normalized)
    }

    private static func normalizePathArgument(_ raw: String) -> URL {
        if let url = URL(string: raw), url.isFileURL {
            return url
        }

        return URL(fileURLWithPath: raw)
    }
}
