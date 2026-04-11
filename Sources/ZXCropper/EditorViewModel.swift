import AppKit
import Foundation

final class EditorViewModel: ObservableObject {
    @Published var sourceImage: NSImage?
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
    @Published var customCommandTemplate: String = ""
    @Published var needsPersistentFolderAccess = false
    @Published var pendingAccessFolderName = ""

    private let launchImagePath: String?
    private var loadedImage: LoadedImage?
    private var previewGeneration = 0
    private var pendingImageURLForAccess: URL?

    init(imagePath: String?) {
        launchImagePath = imagePath
        _ = PermissionAccessManager.shared
    }

    var hasLoadedImage: Bool {
        loadedImage != nil
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
        let constrained = constrainedCropRect(from: rect, ratio: selectedAspectPreset.ratio)
        cropRectNormalized = constrained

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

    func normalizeResizeFields() {
        guard let loadedImage else {
            return
        }

        if autoSizeToCrop {
            let cropSize = cropPixelSize(from: loadedImage.cgImage)
            resizeWidth = String(Int(cropSize.width))
            resizeHeight = String(Int(cropSize.height))
            return
        }

        let fallbackWidth = loadedImage.cgImage.width
        let fallbackHeight = loadedImage.cgImage.height

        let width = max(1, Int(resizeWidth) ?? fallbackWidth)
        let height = max(1, Int(resizeHeight) ?? fallbackHeight)

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

        errorMessage = nil
        infoMessage = nil
        normalizeResizeFields()

        let crop = cropRectNormalized
        let outputSize = resolvedOutputSize(fallback: loadedImage.cgImage)
        let sourceImage = loadedImage.cgImage
        let sourceURL = loadedImage.url
        let sourceProperties = loadedImage.sourceProperties

        isSaving = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let finalImage = try ImagePipeline.render(
                    cgImage: sourceImage,
                    cropRectNormalized: crop,
                    outputPixels: outputSize
                )

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
                    self.loadImage(at: outputURL)
                    self.infoMessage = "\(action.commandName) completed. Loaded \(outputURL.lastPathComponent)."
                } else {
                    self.infoMessage = "\(action.commandName) completed. No single output image detected to reload."
                }
            }
        }
    }

    func runCustomShellCommand() {
        guard let loadedImage else {
            return
        }

        let template = customCommandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            errorMessage = "Enter a custom command first. Example: luma {input}"
            return
        }

        guard !isRunningShellAction, !isSaving else {
            return
        }

        isRunningShellAction = true
        errorMessage = nil
        infoMessage = "Running custom command..."

        let currentInputURL = loadedImage.url
        let firstToken = template.split(separator: " ").first?.lowercased() ?? ""
        let expectsSingleImage = firstToken != "slice" && firstToken != "pslice"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ShellActionRunner.run(
                customCommandTemplate: template,
                inputURL: currentInputURL,
                expectsSingleImageOutput: expectsSingleImage
            )

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
                        ? "Custom command failed with exit code \(result.exitCode)."
                        : stderrSummary
                    return
                }

                if let outputURL = result.outputImageURL {
                    self.loadImage(at: outputURL)
                    self.infoMessage = "Custom command completed. Loaded \(outputURL.lastPathComponent)."
                } else {
                    self.infoMessage = "Custom command completed. No single output image detected to reload."
                }
            }
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

    private func loadFromLaunchPath() {
        guard let launchImagePath, !launchImagePath.isEmpty else {
            errorMessage = "No image path was received. Launch this app from Finder Quick Action: Edit Image."
            return
        }

        let url = Self.normalizePathArgument(launchImagePath)
        loadImage(at: url)
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
                let loaded = try ImagePipeline.loadPNG(at: url)
                let image = NSImage(
                    cgImage: loaded.cgImage,
                    size: NSSize(width: loaded.cgImage.width, height: loaded.cgImage.height)
                )

                DispatchQueue.main.async {
                    self.loadedImage = loaded
                    self.fileName = loaded.url.lastPathComponent
                    self.sourceImage = image
                    self.cropRectNormalized = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
                    self.autoSizeToCrop = true
                    self.needsPersistentFolderAccess = false
                    self.pendingImageURLForAccess = nil
                    self.pendingAccessFolderName = ""
                    self.isRenderingPreview = false
                    self.applyResizeToCurrentCrop()
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
        let sourceCG = loadedImage.cgImage

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

                let rendered = try ImagePipeline.render(
                    cgImage: sourceCG,
                    cropRectNormalized: crop,
                    outputPixels: previewSize
                )

                let preview = NSImage(
                    cgImage: rendered,
                    size: NSSize(width: previewSize.width, height: previewSize.height)
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
        if autoSizeToCrop {
            return cropPixelSize(from: fallback)
        }

        let width = max(1, Int(resizeWidth) ?? fallback.width)
        let height = max(1, Int(resizeHeight) ?? fallback.height)
        return CGSize(width: width, height: height)
    }

    private func applyResizeToCurrentCrop() {
        guard let loadedImage else {
            return
        }

        let cropSize = cropPixelSize(from: loadedImage.cgImage)
        resizeWidth = String(Int(cropSize.width))
        resizeHeight = String(Int(cropSize.height))
        schedulePreviewRender()
    }

    private func cropPixelSize(from image: CGImage) -> CGSize {
        let normalized = ImagePipeline.clampNormalizedRect(cropRectNormalized)
        let width = max(1, Int((normalized.width * CGFloat(image.width)).rounded()))
        let height = max(1, Int((normalized.height * CGFloat(image.height)).rounded()))
        return CGSize(width: width, height: height)
    }

    private func constrainedCropRect(from rect: CGRect, ratio: CGFloat?) -> CGRect {
        var normalized = ImagePipeline.clampNormalizedRect(rect)

        guard let ratio, ratio > 0 else {
            return normalized
        }

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
