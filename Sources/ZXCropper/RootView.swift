import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 10) {
            header

            if let sourceImage = viewModel.sourceImage {
                HStack(spacing: 12) {
                    CropCanvasView(
                        image: sourceImage,
                        cropRectNormalized: Binding(
                            get: { viewModel.cropRectNormalized },
                            set: { viewModel.updateCropRect($0) }
                        ),
                        aspectRatio: viewModel.selectedAspectPreset.ratio,
                        isEraseMode: viewModel.isEraseMode,
                        eraseStrokes: viewModel.eraseStrokes,
                        currentEraseStroke: viewModel.currentEraseStroke,
                        eraseBrushSize: viewModel.eraseBrushSize,
                        eraseBrushShape: viewModel.brushShape,
                        zoomScale: viewModel.zoomScale,
                        onErasePoint: { viewModel.addErasePoint($0) },
                        onEraseEnd: { viewModel.endEraseStroke() },
                        isPolygonMode: viewModel.isPolygonMode,
                        polygonVertices: viewModel.polygonVertices,
                        onPolygonVertex: { viewModel.addPolygonVertex($0) },
                        onPolygonComplete: { viewModel.completePolygon() },
                        onSegmentCurve: { viewModel.setSegmentControl(at: $0, control: $1) },
                        onMoveVertex: { viewModel.moveVertex(at: $0, to: $1) },
                        isWandMode: viewModel.isWandMode,
                        wandContourPath: viewModel.wandContourPath,
                        onWandClick: { viewModel.runMagicWand(at: $0, additive: $1) },
                        onWandInvert: { viewModel.invertWandSelection() },
                        panOffset: viewModel.panOffset,
                        onPanOffsetChange: { viewModel.setPanOffset($0) },
                        onZoomToScale: { viewModel.zoomToScale($0, pan: $1) }
                    )
                    .frame(minWidth: 560, minHeight: 360)
                    .overlay(zoomOverlay, alignment: .bottomTrailing)
                    .overlay(alignment: .topTrailing) {
                        Button("") { viewModel.zoomIn() }
                            .keyboardShortcut("=", modifiers: .command)
                            .hidden()
                        Button("") { viewModel.zoomOut() }
                            .keyboardShortcut("-", modifiers: .command)
                            .hidden()
                        Button("") { viewModel.resetZoom() }
                            .keyboardShortcut("0", modifiers: .command)
                            .hidden()
                        Button("") { viewModel.undo() }
                            .keyboardShortcut("z", modifiers: .command)
                            .hidden()
                        Button("") { viewModel.redo() }
                            .keyboardShortcut("z", modifiers: [.command, .shift])
                            .hidden()
                    }

                    sidebar
                        .frame(width: 275)
                }
            } else {
                placeholder
            }

            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.onAppear()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Image")
                    .font(.title3.weight(.semibold))

                Text(viewModel.fileName.isEmpty ? "Waiting for PNG from Finder Quick Action" : viewModel.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isSaving {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Crop") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(
                            "Aspect",
                            selection: Binding(
                                get: { viewModel.selectedAspectPreset },
                                set: { viewModel.setAspectPreset($0) }
                            )
                        ) {
                            ForEach(AspectPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isEraseMode || viewModel.isPolygonMode)

                        Toggle(
                            "Match crop size",
                            isOn: Binding(
                                get: { viewModel.autoSizeToCrop },
                                set: { viewModel.setAutoSizeToCrop($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .font(.caption)

                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("W")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("W", text: Binding(
                                    get: { viewModel.resizeWidth },
                                    set: { viewModel.updateResizeWidth($0) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .disabled(viewModel.autoSizeToCrop)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("H")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("H", text: Binding(
                                    get: { viewModel.resizeHeight },
                                    set: { viewModel.updateResizeHeight($0) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .disabled(viewModel.autoSizeToCrop)
                            }
                        }

                        Button {
                            viewModel.resetCrop()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .disabled(viewModel.isEraseMode || viewModel.isPolygonMode)
                    }
                }

                GroupBox("Erase") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Mode", selection: Binding(
                            get: {
                                if viewModel.isWandMode { return 3 }
                                if viewModel.isPolygonMode { return 2 }
                                if viewModel.isEraseMode { return 1 }
                                return 0
                            },
                            set: { value in
                                viewModel.isEraseMode = value == 1
                                viewModel.isPolygonMode = value == 2
                                viewModel.isWandMode = value == 3
                                if value != 2 { viewModel.cancelPolygon() }
                                if value != 3 { viewModel.clearWandSelection() }
                            }
                        )) {
                            Text("\(Image(systemName: "xmark.circle")) Off").tag(0)
                            Text("\(Image(systemName: "paintbrush.pointed")) Brush").tag(1)
                            Text("\(Image(systemName: "pencil.tip")) Pen").tag(2)
                            Text("\(Image(systemName: "wand.and.stars")) Wand").tag(3)
                        }
                        .pickerStyle(.segmented)

                        if viewModel.isEraseMode {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Size: \(String(format: "%.0f", viewModel.eraseBrushSize))px")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("", selection: $viewModel.brushShape) {
                                        Text("\(Image(systemName: "circle")) Circle").tag(BrushShape.circle)
                                        Text("\(Image(systemName: "square")) Square").tag(BrushShape.square)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 120)
                                }

                                Slider(
                                    value: Binding(
                                        get: { viewModel.eraseBrushSize },
                                        set: { viewModel.eraseBrushSize = $0 }
                                    ),
                                    in: 2...1000,
                                    step: 1
                                )
                            }
                        }

                        if viewModel.isPolygonMode {
                            VStack(alignment: .leading, spacing: 6) {
                                if viewModel.isDrawingPolygon {
                                    Text("\(viewModel.polygonVertices.count) pts — Click near 1st dot to close")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 8) {
                                        Button {
                                            viewModel.completePolygon()
                                        } label: {
                                            Label("Complete", systemImage: "checkmark")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .font(.caption)

                                        Button(role: .destructive) {
                                            viewModel.cancelPolygon()
                                        } label: {
                                            Label("Cancel", systemImage: "xmark")
                                        }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                    }
                                } else {
                                    Text("Click to place polygon vertices")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if viewModel.isWandMode {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Tolerance: \(String(format: "%.0f", viewModel.wandTolerance))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Toggle("Contiguous", isOn: $viewModel.wandContiguous)
                                        .toggleStyle(.switch)
                                        .font(.caption)
                                }

                                Slider(
                                    value: $viewModel.wandTolerance,
                                    in: 0...255,
                                    step: 1
                                )

                                if viewModel.isRunningWand {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Selecting...")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else if viewModel.hasWandSelection {
                                    HStack(spacing: 8) {
                                        Button(action: viewModel.invertWandSelection) {
                                            Label("Invert", systemImage: "arrow.triangle.swap")
                                        }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                        Button(role: .destructive, action: viewModel.deleteWandSelection) {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .font(.caption)
                                    }
                                } else {
                                    Text("Click the image to select similar colors")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if viewModel.isEraseMode || viewModel.isPolygonMode || viewModel.isWandMode || viewModel.hasEraseStrokes {
                            HStack(spacing: 8) {
                                Button {
                                    viewModel.undo()
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!viewModel.canUndo)
                                .help("Undo  (Cmd+Z)")

                                Button {
                                    viewModel.redo()
                                } label: {
                                    Image(systemName: "arrow.uturn.forward")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!viewModel.canRedo)
                                .help("Redo  (Cmd+Shift+Z)")

                                Spacer()

                                if viewModel.hasEraseStrokes {
                                    Button(role: .destructive) {
                                        viewModel.clearErase()
                                    } label: {
                                        Label("Clear", systemImage: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                GroupBox("Shell Actions (.zshrc)") {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        actionButton(.luma)
                        actionButton(.slice)
                        actionButton(.rem)
                        actionButton(.remgreen)
                        actionButton(.gm)
                        remgreenFuzzButton
                    }

                    HStack(spacing: 8) {
                        Text("Fuzz")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "25",
                            text: Binding(
                                get: { viewModel.remgreenFuzz },
                                set: { viewModel.updateRemgreenFuzz($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 60)
                        .disabled(viewModel.isSaving || viewModel.isRunningShellAction)

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom command")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "Example: luma {input}",
                            text: $viewModel.customCommandTemplate
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                        HStack {
                            Button("Run Custom") {
                                viewModel.runCustomShellCommand()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.customCommandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction)

                            Spacer()
                        }
                    }

                    if viewModel.isRunningShellAction {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running shell action...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Placeholders: {input}, {dir}, {stem}, {name}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Preview") {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.windowBackgroundColor))

                    if let previewImage = viewModel.previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(8)
                    } else {
                        Text("Preview")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.isRenderingPreview {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 150)
            }

        }
    }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            if viewModel.needsPersistentFolderAccess {
                Text("Grant Folder Access Once")
                    .font(.headline)

                Text("Allow access to \(viewModel.pendingAccessFolderName) to stop repeated permission prompts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Grant Access") {
                    viewModel.grantPersistentFolderAccess()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Launch from Finder")
                    .font(.headline)

                Text("Right-click a PNG / WebP file and run Quick Action: Edit Image")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let message = viewModel.infoMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Cmd+Return = Done, Esc = Cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelAndClose()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button("Done") {
                viewModel.doneAndSave()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction)
        }
    }

    private func actionButton(_ action: ShellImageAction) -> some View {
        Button(action.title) {
            viewModel.runShellAction(action)
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction)
    }

    private var remgreenFuzzButton: some View {
        Button("REMGREEN \(viewModel.remgreenFuzzLabel)") {
            viewModel.runRemgreenWithFuzz()
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction)
    }

    private var zoomOverlay: some View {
        HStack(spacing: 4) {
            let zoomPercent = Int((viewModel.zoomScale * 100).rounded())

            Button {
                viewModel.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.zoomScale <= 1.0)
            .help("Zoom Out  (Cmd+-)")

            Text("\(zoomPercent)%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 36)

            Button {
                viewModel.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.zoomScale >= 10.0)
            .help("Zoom In  (Cmd+=)")

            if viewModel.zoomScale > 1.0 {
                Button("Reset") {
                    viewModel.resetZoom()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Reset Zoom  (Cmd+0)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}
