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

struct PolygonHistoryEntry {
    let vertices: [PolygonVertex]
    let isClosed: Bool
}

struct ImageHistoryEntry {
    let image: CGImage?
    let polygonVertices: [PolygonVertex]
    let isPolygonClosed: Bool
    let vertexUndoStack: [PolygonHistoryEntry]
    let vertexRedoStack: [PolygonHistoryEntry]
    let editToolTag: Int
    let isSliceMode: Bool
}


final class EditorViewModel: ObservableObject {
    @Published var sourceImage: NSImage?
    @Published var originalImage: NSImage?
    @Published var previewImage: NSImage?
    @Published var cropRectNormalized: CGRect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
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
    @Published var penSmooth = false
    @Published var penShape: PenShape = .free
    @Published var polygonVertices: [PolygonVertex] = []
    /// When true the pen path is visually closed and awaiting an action
    /// (Complete / Keep Inside). No new vertices can be added.
    @Published var isPolygonClosed = false
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
    /// When true, Detect Removed Spots also identifies edge shadows, outlines, line details, and cavities.
    @Published var removedSpotIncludeEdges = true
    // Auto Pen Path Cutout: detect every part of the subject as editable pen paths,
    // then cycle through the parts (or the full combined outline) and cut.
    @Published var isDetectingShape = false
    @Published var shapeTolerance: CGFloat = 60
    /// Detected candidate paths. Candidate 0 is the combined full-logo outline;
    /// the rest are individual parts, largest first.
    @Published var pathCandidates: [[PolygonVertex]] = []
    @Published var currentCandidateIndex: Int = 0
    /// True when the current pathCandidates came from the VFX engine (3 paths:
    /// core, glow, hull) instead of component-based detection.
    @Published var hasVFXPaths = false
    /// Real-time expansion/contraction factor applied on top of the base VFX
    /// candidates. Positive = inflate to cover more glow; negative = tighten to
    /// the core. The base vertices in pathCandidates are never modified — the
    /// display path (`polygonVertices`) is recomputed from the slider value.
    @Published var shapeExpansion: CGFloat = 0
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
    private var imageUndoStack: [ImageHistoryEntry] = []
    private var imageRedoStack: [ImageHistoryEntry] = []
    private let maxHistory = 12

    var hasEdits: Bool {
        erasedCGImage != nil
    }

    var isDrawingPolygon: Bool {
        !polygonVertices.isEmpty && !isPolygonClosed
    }

    /// True when the pen path has been closed and the user must pick an action.
    var isPolygonAwaitingAction: Bool {
        !polygonVertices.isEmpty && isPolygonClosed
    }

    var canUndo: Bool {
        ((isDrawingPolygon || isPolygonClosed) && !vertexUndoStack.isEmpty)
            || (inFlightEdits == 0 && !imageUndoStack.isEmpty)
    }

    var canRedo: Bool {
        // Undoing a freshly detected pen path leaves an empty polygon (isDrawing /
        // isClosed both false) with the path still on the redo stack — the flag must
        // not gate on polygon state.
        !vertexRedoStack.isEmpty
            || (inFlightEdits == 0 && !imageRedoStack.isEmpty)
    }

    private var vertexUndoStack: [PolygonHistoryEntry] = []
    private var vertexRedoStack: [PolygonHistoryEntry] = []
    private struct PendingPolygonState {
        let vertices: [PolygonVertex]
        let isClosed: Bool
        let undoStack: [PolygonHistoryEntry]
        let redoStack: [PolygonHistoryEntry]
    }
    private var pendingPolygonHistoryEntry: PendingPolygonState?
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
        cropRectNormalized = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)

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

    func setRemovedSpotIncludeEdges(_ enabled: Bool) {
        removedSpotIncludeEdges = enabled
    }

    var resolvedRemovedSpotMinSize: Int {
        max(1, Int(removedSpotMinSize) ?? 16)
    }

    func detectRemovedSpots() {
        guard let loadedImage, let base = currentBaseImage() else { return }
        let original = loadedImage.cgImage
        let minSize = resolvedRemovedSpotMinSize
        let includeEdges = removedSpotIncludeEdges

        isDetectingRemovedSpots = true
        errorMessage = nil
        detectedRemovedSpots = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let spots = try ImagePipeline.detectRemovedSpots(
                    processed: base,
                    original: original,
                    minSize: minSize,
                    includeEdgeDetails: includeEdges
                )
                DispatchQueue.main.async {
                    self.detectedRemovedSpots = spots
                    self.isDetectingRemovedSpots = false
                    if spots.isEmpty {
                        self.infoMessage = includeEdges
                            ? "No removed areas or edge shadows detected."
                            : "No enclosed removed areas found."
                    } else {
                        self.infoMessage = "Found \(spots.count) removed area\(spots.count == 1 ? "" : "s"). Click any to restore\(spots.count > 1 ? ", or Restore All" : "")."
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

    func restoreAllRemovedSpots() {
        guard !isSaving, inFlightEdits == 0, hasLoadedImage else { return }
        guard let loadedImage else { return }
        let masks = detectedRemovedSpots.map { $0.mask }
        guard !masks.isEmpty else { return }
        let count = masks.count
        let original = loadedImage.cgImage

        isSaving = true
        errorMessage = nil
        infoMessage = "Restoring \(count) area\(count == 1 ? "" : "s")..."

        runEdit(completion: { [weak self] ok in
            self?.isSaving = false
            if ok {
                self?.detectedRemovedSpots = []
                self?.infoMessage = "Restored \(count) area\(count == 1 ? "" : "s")."
            }
        }) { base in
            guard let combined = ImagePipeline.combineMasks(masks) else { return base }
            return try ImagePipeline.restore(
                base: base, original: original,
                strokes: [], polygons: [],
                brushSize: 1, selectionMask: combined
            )
        }
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

    // MARK: - Auto Pen Path Cutout (detect parts → cycle → cut)

    /// Detects every connected subject part as an editable pen path. Candidate 0 is
    /// the combined full-logo outline; the rest are individual parts, largest
    /// first. Drops the editor straight into pen mode with candidate 0 selected and
    /// the path closed and awaiting a cut action. The generated path lands on the
    /// vertex undo stack, so ⌘Z removes it.
    func detectPenPathCandidates() {
        guard hasLoadedImage else { return }
        guard !isSaving, !isRunningLumaKey, !isRunningShellAction, inFlightEdits == 0 else { return }
        // Snapshot the base on the main thread; a new undo / edit / detection bumps
        // the generation and invalidates this run, so a stale outline can never
        // clobber newer state.
        guard let base = currentBaseImage() else { return }
        let tolerance = shapeTolerance
        isDetectingShape = true
        errorMessage = nil
        infoMessage = "Detecting pen paths..."
        shapeDetectionGeneration += 1
        let generation = shapeDetectionGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Try VFX detection first (generates 3 candidates: core, glow, hull
            // from alpha or radial luminance falloff). Falls back to standard
            // component-based detection when the image isn't a VFX asset.
            let vfx = ImagePipeline.detectGameAssetVFXPaths(cgImage: base, tolerance: tolerance)

            DispatchQueue.main.async {
                guard generation == self.shapeDetectionGeneration else { return }
                self.isDetectingShape = false

                if let vfx, vfx.count >= 3, vfx.allSatisfy({ $0.count >= 3 }) {
                    // VFX candidates: [core, glow, hull]
                    self.hasVFXPaths = true
                    self.pathCandidates = vfx
                    self.currentCandidateIndex = 0
                    self.shapeExpansion = 0
                    self.selectEditTool(2)
                    self.penShape = .free
                    self.vertexUndoStack.append(
                        PolygonHistoryEntry(vertices: self.polygonVertices, isClosed: self.isPolygonClosed)
                    )
                    self.vertexRedoStack.removeAll()
                    self.polygonVertices = vfx[0]
                    self.isPolygonClosed = true
                    if self.penSmooth { self.recomputeSmoothHandles() }
                    self.infoMessage = "VFX paths ready — Core / Glow / Hull via ◄ Prev / Next ►; adjust Expansion for halo coverage."
                } else {
                    // Standard component-based detection.
                    self.hasVFXPaths = false
                    let set = ImagePipeline.detectPenPathSet(cgImage: base, tolerance: tolerance)
                    guard let set, !set.componentPaths.isEmpty else {
                        self.errorMessage = "Could not detect a subject outline. Try a clearer image or adjust the tolerance."
                        return
                    }
                    // A single part's combined outline IS that part, so dedup it —
                    // otherwise the nav shows a fake "Shape 1 of 2 / Shape 2 of 2".
                    let candidates = [set.combinedOuterPath] + set.componentPaths.filter { $0 != set.combinedOuterPath }
                    guard candidates.first?.count ?? 0 >= 3 else {
                        self.errorMessage = "The detected outlines were too small to use as pen paths."
                        return
                    }
                    self.pathCandidates = candidates
                    self.currentCandidateIndex = 0
                    self.selectEditTool(2)
                    self.penShape = .free
                    // Record the pre-detect path (normally empty) so ⌘Z removes the
                    // generated path; redo restores it.
                    self.vertexUndoStack.append(
                        PolygonHistoryEntry(vertices: self.polygonVertices, isClosed: self.isPolygonClosed)
                    )
                    self.vertexRedoStack.removeAll()
                    self.polygonVertices = candidates[0]
                    self.isPolygonClosed = true
                    if self.penSmooth { self.recomputeSmoothHandles() }
                    self.infoMessage = candidates.count > 1
                        ? "Outline ready — ◄ Prev / Next ► to pick a part, or drag dots to refine, then cut."
                        : "Outline ready — drag dots or lines to refine, then Erase Inside or Keep Inside."
                }
            }
        }
    }

    func cycleNextCandidate() {
        guard !pathCandidates.isEmpty else { return }
        currentCandidateIndex = (currentCandidateIndex + 1) % pathCandidates.count
        applyCandidate()
    }

    func cyclePrevCandidate() {
        guard !pathCandidates.isEmpty else { return }
        currentCandidateIndex = (currentCandidateIndex - 1 + pathCandidates.count) % pathCandidates.count
        applyCandidate()
    }

    /// Jump back to candidate 0, the combined full-logo outline.
    func selectCombinedOuterPath() {
        guard !pathCandidates.isEmpty else { return }
        currentCandidateIndex = 0
        applyCandidate()
    }

    /// Swaps the canvas pen path to the current candidate. Cycled candidates aren't
    /// pushed on the undo stack — one ⌘Z removes the whole generated path.
    // ponytail: no per-candidate undo entries; the pre-detect snapshot covers it.
    private func applyCandidate() {
        let verts = pathCandidates[currentCandidateIndex]
        guard !verts.isEmpty else { return }
        polygonVertices = verts
        isPolygonClosed = true
        if penSmooth { recomputeSmoothHandles() }
        if hasVFXPaths { applyExpansion() }
    }

    /// Inflates / contracts the current VFX candidate's vertices from their centroid
    /// by `(1 + shapeExpansion / 100)`. Called on every slider drag (from `.onChange`
    /// in the view) and on candidate switch. Does NOT modify the stored candidate
    /// — only the display path.
    func applyExpansion() {
        guard hasVFXPaths, !pathCandidates.isEmpty, shapeExpansion != 0 else { return }
        let base = pathCandidates[currentCandidateIndex]
        guard base.count >= 3 else { return }
        var sx: CGFloat = 0, sy: CGFloat = 0
        for v in base { sx += v.anchor.x; sy += v.anchor.y }
        let cx = sx / CGFloat(base.count), cy = sy / CGFloat(base.count)
        let scale = 1 + shapeExpansion / 100
        polygonVertices = base.map { v in
            var copy = v
            copy.anchor = CGPoint(x: cx + (v.anchor.x - cx) * scale, y: cy + (v.anchor.y - cy) * scale)
            return copy
        }
        isPolygonClosed = true
        if penSmooth { recomputeSmoothHandles() }
    }

    func clearShapeDetection() {
        shapeDetectionGeneration += 1
        isDetectingShape = false
        if !pathCandidates.isEmpty { pathCandidates = [] }
        currentCandidateIndex = 0
        hasVFXPaths = false
        shapeExpansion = 0
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
        guard !isPolygonClosed else { return }
        vertexUndoStack.append(PolygonHistoryEntry(vertices: polygonVertices, isClosed: isPolygonClosed))
        vertexRedoStack.removeAll()
        polygonVertices.append(vertex)
        if penSmooth { recomputeSmoothHandles() }
    }

    /// Visually closes the pen path without performing any erase/keep action.
    /// The user must then tap Complete or Keep Inside.
    func closePolygonPath() {
        guard polygonVertices.count >= 3 else { return }
        vertexUndoStack.append(PolygonHistoryEntry(vertices: polygonVertices, isClosed: isPolygonClosed))
        vertexRedoStack.removeAll()
        isPolygonClosed = true
    }

    func setPenSmooth(_ enabled: Bool) {
        penSmooth = enabled
        if enabled {
            recomputeSmoothHandles()
        }
    }

    /// Recomputes every anchor's handles as a **smooth closed spline** (Catmull-Rom
    /// → Bézier) so adjacent segments share a tangent — no kinks. Place points around
    /// a shape and the whole path flows smoothly through them (a circle for points on
    /// a circle). Done in image-pixel space so it's circular on screen.
    func recomputeSmoothHandles() {
        let n = polygonVertices.count
        guard n >= 3 else {
            for i in polygonVertices.indices {
                polygonVertices[i].controlOut = nil
                polygonVertices[i].controlIn = nil
            }
            return
        }
        let w = CGFloat(loadedImage?.cgImage.width ?? 1)
        let h = CGFloat(loadedImage?.cgImage.height ?? 1)
        let p = polygonVertices.map { CGPoint(x: $0.anchor.x * w, y: $0.anchor.y * h) }
        var verts = polygonVertices
        for i in 0..<n {
            let prev = p[(i - 1 + n) % n]
            let cur = p[i]
            let next = p[(i + 1) % n]
            // Catmull-Rom tangent at this anchor; Bézier handle = anchor ± tangent/6·... .
            let tx = (next.x - prev.x) / 6
            let ty = (next.y - prev.y) / 6
            verts[i].controlOut = CGPoint(x: (cur.x + tx) / w, y: (cur.y + ty) / h)
            verts[i].controlIn = CGPoint(x: (cur.x - tx) / w, y: (cur.y - ty) / h)
        }
        polygonVertices = verts
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
        // In smooth mode, re-flow the whole spline so neighbours stay tangent-continuous.
        if penSmooth { recomputeSmoothHandles() }
    }

    /// The circle through `a`, `p`, `b`, plus the signed sweep angle from `a` to `b`
    /// that actually passes through `p`. `nil` if the three points are collinear
    /// (no meaningful circle). Shared by the live-preview and final arc fits.
    private func circularArc(from a: CGPoint, to b: CGPoint, through p: CGPoint) -> (center: CGPoint, radius: CGFloat, startAngle: CGFloat, sweep: CGFloat)? {
        let det = 2 * (a.x * (p.y - b.y) + p.x * (b.y - a.y) + b.x * (a.y - p.y))
        let chordLen = hypot(b.x - a.x, b.y - a.y)
        // Perpendicular bulge of p off the chord (scale-invariant). If tiny, treat as straight.
        let perpDist = chordLen > 1e-9 ? abs(det) / (2 * chordLen) : 0
        guard chordLen > 1e-9, perpDist >= chordLen * 0.005 else { return nil }

        let a2 = a.x * a.x + a.y * a.y
        let p2 = p.x * p.x + p.y * p.y
        let b2 = b.x * b.x + b.y * b.y
        let ox = (a2 * (p.y - b.y) + p2 * (b.y - a.y) + b2 * (a.y - p.y)) / det
        let oy = (a2 * (b.x - p.x) + p2 * (a.x - b.x) + b2 * (p.x - a.x)) / det
        let center = CGPoint(x: ox, y: oy)
        let radius = hypot(a.x - ox, a.y - oy)

        let twoPi = CGFloat.pi * 2
        func norm(_ angle: CGFloat) -> CGFloat {
            var x = angle.truncatingRemainder(dividingBy: twoPi)
            if x < 0 { x += twoPi }
            return x
        }
        let aAng = atan2(a.y - oy, a.x - ox)
        let bAng = atan2(b.y - oy, b.x - ox)
        let pAng = atan2(p.y - oy, p.x - ox)
        let sweepCCW = norm(bAng - aAng)
        // Signed arc a→b that actually passes through p.
        var sweep = norm(pAng - aAng) <= sweepCCW ? sweepCCW : sweepCCW - twoPi
        sweep = max(-twoPi + 0.02, min(twoPi - 0.02, sweep))
        return (center, radius, aAng, sweep)
    }

    private func ccwTangent(at q: CGPoint, center: CGPoint) -> CGPoint {
        let vx = -(q.y - center.y)
        let vy = (q.x - center.x)
        let len = hypot(vx, vy)
        return len > 1e-9 ? CGPoint(x: vx / len, y: vy / len) : .zero
    }

    /// Cheap live preview while dragging: bends the segment starting at `index`
    /// into the single-cubic best fit of the circular arc through the two anchors
    /// and `point`. A single cubic only stays visually circular up to roughly a
    /// 90° bulge, but recomputing this on every drag frame needs to be fast and
    /// must never change the vertex count (indices must stay stable mid-gesture) —
    /// see `finalizeCurveSegment` for the exact multi-piece version committed on
    /// release.
    func curveSegment(at index: Int, through point: CGPoint) {
        // In smooth mode curvature is automatic (Catmull-Rom); manual arc-drag is off.
        guard !penSmooth else { return }
        let count = polygonVertices.count
        guard count >= 2, index >= 0, index < count else { return }
        let next = (index + 1) % count
        var copy = polygonVertices

        let w = CGFloat(loadedImage?.cgImage.width ?? 1)
        let h = CGFloat(loadedImage?.cgImage.height ?? 1)
        let a = CGPoint(x: copy[index].anchor.x * w, y: copy[index].anchor.y * h)
        let b = CGPoint(x: copy[next].anchor.x * w, y: copy[next].anchor.y * h)
        let p = CGPoint(x: point.x * w, y: point.y * h)

        guard let arc = circularArc(from: a, to: b, through: p) else {
            copy[index].controlOut = nil
            copy[next].controlIn = nil
            polygonVertices = copy
            return
        }

        // Cubic control distance for a circular arc: (4/3)·tan(θ/4)·R.
        let dist = (4.0 / 3.0) * tan(arc.sweep / 4) * arc.radius
        let tA = ccwTangent(at: a, center: arc.center)
        let tB = ccwTangent(at: b, center: arc.center)
        let cOut = CGPoint(x: a.x + dist * tA.x, y: a.y + dist * tA.y)
        let cIn = CGPoint(x: b.x - dist * tB.x, y: b.y - dist * tB.y)

        copy[index].controlOut = CGPoint(x: cOut.x / w, y: cOut.y / h)
        copy[next].controlIn = CGPoint(x: cIn.x / w, y: cIn.y / h)
        polygonVertices = copy
    }

    /// Commits the **exact** circular arc for the segment at `index`, called once
    /// on drag release. A single cubic Bézier cannot represent a wide arc without
    /// visible flattening — that's the "never circular" bug — so this splits the
    /// bulge into multiple pieces of at most 90° each (where a cubic is accurate to
    /// within a fraction of a percent), inserting extra anchors along the true
    /// circle as needed. For a modest bulge (the common case) this is exactly one
    /// piece, identical to `curveSegment`'s live preview — no visible change on
    /// release. Only large bulges gain the extra points, and only then.
    func finalizeCurveSegment(at index: Int, through point: CGPoint) {
        guard !penSmooth else { return }
        let count = polygonVertices.count
        guard count >= 2, index >= 0, index < count else { return }
        let next = (index + 1) % count
        var copy = polygonVertices

        vertexUndoStack.append(PolygonHistoryEntry(vertices: polygonVertices, isClosed: isPolygonClosed))
        vertexRedoStack.removeAll()

        let w = CGFloat(loadedImage?.cgImage.width ?? 1)
        let h = CGFloat(loadedImage?.cgImage.height ?? 1)
        let a = CGPoint(x: copy[index].anchor.x * w, y: copy[index].anchor.y * h)
        let b = CGPoint(x: copy[next].anchor.x * w, y: copy[next].anchor.y * h)
        let p = CGPoint(x: point.x * w, y: point.y * h)

        guard let arc = circularArc(from: a, to: b, through: p) else {
            copy[index].controlOut = nil
            copy[next].controlIn = nil
            polygonVertices = copy
            return
        }

        let maxPieceSweep = CGFloat.pi / 2
        let pieceCount = max(1, Int(ceil(abs(arc.sweep) / maxPieceSweep)))
        let pieceSweep = arc.sweep / CGFloat(pieceCount)
        let dist = (4.0 / 3.0) * tan(pieceSweep / 4) * arc.radius

        func pointOnCircle(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: arc.center.x + arc.radius * cos(angle), y: arc.center.y + arc.radius * sin(angle))
        }

        var pieceAnchors: [PolygonVertex] = []
        for i in 0...pieceCount {
            let angle = arc.startAngle + arc.sweep * CGFloat(i) / CGFloat(pieceCount)
            let pos = i == 0 ? a : (i == pieceCount ? b : pointOnCircle(angle))
            let tangent = ccwTangent(at: pos, center: arc.center)
            var vertex = PolygonVertex(anchor: CGPoint(x: pos.x / w, y: pos.y / h), controlIn: nil, controlOut: nil)
            if i > 0 {
                let inCtl = CGPoint(x: pos.x - dist * tangent.x, y: pos.y - dist * tangent.y)
                vertex.controlIn = CGPoint(x: inCtl.x / w, y: inCtl.y / h)
            }
            if i < pieceCount {
                let outCtl = CGPoint(x: pos.x + dist * tangent.x, y: pos.y + dist * tangent.y)
                vertex.controlOut = CGPoint(x: outCtl.x / w, y: outCtl.y / h)
            }
            pieceAnchors.append(vertex)
        }

        copy[index].controlOut = pieceAnchors[0].controlOut
        copy[next].controlIn = pieceAnchors[pieceCount].controlIn
        if pieceCount > 1 {
            copy.insert(contentsOf: pieceAnchors[1..<pieceCount], at: index + 1)
        }
        polygonVertices = copy
    }

    /// Inserts a new anchor on the segment starting at `segmentIndex`, at the point
    /// on the curve nearest `point`. Uses a De Casteljau split so the curve's shape
    /// is unchanged — it just gains a draggable point to refine that spot. Works on
    /// closed paths too (the detect-as-pen case), where tapping the midpoint dot of
    /// a segment must add a vertex.
    func insertVertexOnSegment(_ segmentIndex: Int, at point: CGPoint) {
        let count = polygonVertices.count
        guard count >= 2, segmentIndex >= 0, segmentIndex < count else { return }
        let next = (segmentIndex + 1) % count
        var verts = polygonVertices
        let start = verts[segmentIndex]
        let end = verts[next]
        let a = start.anchor
        let b = end.anchor
        let c1 = start.controlOut ?? a
        let c2 = end.controlIn ?? b
        let wasCurved = start.controlOut != nil || end.controlIn != nil

        func cubic(_ t: CGFloat) -> CGPoint {
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * mt * a.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * b.x,
                y: mt * mt * mt * a.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * b.y
            )
        }
        // Nearest parameter to the clicked point.
        var bestT: CGFloat = 0.5
        var bestD = CGFloat.greatestFiniteMagnitude
        let samples = 48
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let p = cubic(t)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < bestD { bestD = d; bestT = t }
        }
        let t = bestT

        func lerp(_ p: CGPoint, _ q: CGPoint, _ tt: CGFloat) -> CGPoint {
            CGPoint(x: p.x + (q.x - p.x) * tt, y: p.y + (q.y - p.y) * tt)
        }
        let p01 = lerp(a, c1, t)
        let p12 = lerp(c1, c2, t)
        let p23 = lerp(c2, b, t)
        let p012 = lerp(p01, p12, t)
        let p123 = lerp(p12, p23, t)
        let splitPoint = lerp(p012, p123, t)

        vertexUndoStack.append(PolygonHistoryEntry(vertices: polygonVertices, isClosed: isPolygonClosed))
        vertexRedoStack.removeAll()
        verts[segmentIndex].controlOut = wasCurved ? p01 : nil
        verts[next].controlIn = wasCurved ? p23 : nil
        let inserted = PolygonVertex(
            anchor: splitPoint,
            controlIn: wasCurved ? p012 : nil,
            controlOut: wasCurved ? p123 : nil
        )
        verts.insert(inserted, at: segmentIndex + 1)
        polygonVertices = verts
        if penSmooth { recomputeSmoothHandles() }
    }

    func removeLastVertex() {
        guard !polygonVertices.isEmpty else { return }
        vertexUndoStack.append(PolygonHistoryEntry(vertices: polygonVertices, isClosed: isPolygonClosed))
        vertexRedoStack.removeAll()
        polygonVertices.removeLast()
        if penSmooth { recomputeSmoothHandles() }
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
        pendingPolygonHistoryEntry = PendingPolygonState(
            vertices: polygonVertices,
            isClosed: isPolygonClosed,
            undoStack: vertexUndoStack,
            redoStack: vertexRedoStack
        )
        polygonVertices.removeAll()
        isPolygonClosed = false
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
        isPolygonClosed = false
        vertexUndoStack.removeAll()
        vertexRedoStack.removeAll()
    }

    /// Inverse of `completePolygon()`: keeps everything **inside** the pen
    /// selection and makes all pixels outside transparent. The crop rectangle
    /// is then fitted to the bounding box of the kept region.
    func keepInsidePolygon() {
        guard polygonVertices.count >= 3 else {
            cancelPolygon()
            return
        }
        let verts = polygonVertices
        pendingPolygonHistoryEntry = PendingPolygonState(
            vertices: polygonVertices,
            isClosed: isPolygonClosed,
            undoStack: vertexUndoStack,
            redoStack: vertexRedoStack
        )
        polygonVertices.removeAll()
        isPolygonClosed = false
        vertexUndoStack.removeAll()
        vertexRedoStack.removeAll()
        guard hasLoadedImage else { return }
        let feather = eraseFeather

        runEdit(completion: { ok in
            guard ok else { return }
        }) { base in
            let keepMask = try ImagePipeline.rasterizeKeepMask(
                width: base.width,
                height: base.height,
                polygons: [verts],
                feather: feather
            )
            let result = try ImagePipeline.applyKeepMask(
                cgImage: base,
                keepMask: keepMask,
                feather: 0 // feather already baked into the mask
            )
            return result
        }
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
        if (isDrawingPolygon || isPolygonClosed) && !vertexUndoStack.isEmpty {
            let previous = vertexUndoStack.removeLast()
            vertexRedoStack.append(PolygonHistoryEntry(vertices: polygonVertices, isClosed: isPolygonClosed))
            polygonVertices = previous.vertices
            isPolygonClosed = previous.isClosed
            return
        }
        guard inFlightEdits == 0, !imageUndoStack.isEmpty else { return }
        
        let redoEntry = ImageHistoryEntry(
            image: erasedCGImage,
            polygonVertices: polygonVertices,
            isPolygonClosed: isPolygonClosed,
            vertexUndoStack: vertexUndoStack,
            vertexRedoStack: vertexRedoStack,
            editToolTag: currentEditTool,
            isSliceMode: isSliceMode
        )
        imageRedoStack.append(redoEntry)
        
        let undoEntry = imageUndoStack.removeLast()
        erasedCGImage = undoEntry.image
        
        // Restore tool selection directly
        let tag = undoEntry.editToolTag
        isEraseMode = (tag == 1)
        isPolygonMode = (tag == 2)
        isWandMode = (tag == 3)
        isRestoreMode = (tag == 4)
        isSliceMode = undoEntry.isSliceMode

        // Restore polygon state
        polygonVertices = undoEntry.polygonVertices
        isPolygonClosed = undoEntry.isPolygonClosed
        vertexUndoStack = undoEntry.vertexUndoStack
        vertexRedoStack = undoEntry.vertexRedoStack
        
        afterHistoryChange()
    }

    func redo() {
        if !vertexRedoStack.isEmpty {
            let next = vertexRedoStack.removeLast()
            vertexUndoStack.append(PolygonHistoryEntry(vertices: polygonVertices, isClosed: isPolygonClosed))
            polygonVertices = next.vertices
            isPolygonClosed = next.isClosed
            return
        }
        guard inFlightEdits == 0, !imageRedoStack.isEmpty else { return }
        
        let undoEntry = ImageHistoryEntry(
            image: erasedCGImage,
            polygonVertices: polygonVertices,
            isPolygonClosed: isPolygonClosed,
            vertexUndoStack: vertexUndoStack,
            vertexRedoStack: vertexRedoStack,
            editToolTag: currentEditTool,
            isSliceMode: isSliceMode
        )
        imageUndoStack.append(undoEntry)
        
        let redoEntry = imageRedoStack.removeLast()
        erasedCGImage = redoEntry.image
        
        // Restore tool selection directly
        let tag = redoEntry.editToolTag
        isEraseMode = (tag == 1)
        isPolygonMode = (tag == 2)
        isWandMode = (tag == 3)
        isRestoreMode = (tag == 4)
        isSliceMode = redoEntry.isSliceMode

        // Restore polygon state
        polygonVertices = redoEntry.polygonVertices
        isPolygonClosed = redoEntry.isPolygonClosed
        vertexUndoStack = redoEntry.vertexUndoStack
        vertexRedoStack = redoEntry.vertexRedoStack
        
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
        let entry = ImageHistoryEntry(
            image: erasedCGImage,
            polygonVertices: pendingPolygonHistoryEntry?.vertices ?? [],
            isPolygonClosed: pendingPolygonHistoryEntry?.isClosed ?? false,
            vertexUndoStack: pendingPolygonHistoryEntry?.undoStack ?? [],
            vertexRedoStack: pendingPolygonHistoryEntry?.redoStack ?? [],
            editToolTag: currentEditTool,
            isSliceMode: isSliceMode
        )
        pendingPolygonHistoryEntry = nil
        
        imageUndoStack.append(entry)
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
            errorMessage = "No image path was received. Launch this app from Finder Quick Action: Edit Image, or drag an image (PNG, JPEG, WebP) onto the window."
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
                    self.cropRectNormalized = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
                    self.autoSizeToCrop = true
                    self.needsPersistentFolderAccess = false
                    self.pendingImageURLForAccess = nil
                    self.pendingAccessFolderName = ""
                    self.isRenderingPreview = false
                    self.applyResizeToCurrentCrop()
                    self.clearShapeDetection()
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
