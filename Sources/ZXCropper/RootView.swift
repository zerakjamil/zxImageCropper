import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var showHelp = false
    @AppStorage("isSidebarCollapsed") private var isSidebarCollapsed = false

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
                        eraseStrokes: [],
                        currentEraseStroke: viewModel.currentEraseStroke,
                        eraseBrushSize: viewModel.eraseBrushSize,
                        eraseBrushShape: viewModel.brushShape,
                        zoomScale: viewModel.zoomScale,
                        onErasePoint: { viewModel.addErasePoint($0) },
                        onEraseEnd: { viewModel.endEraseStroke() },
                        isPolygonMode: viewModel.isPolygonMode,
                        penShape: viewModel.penShape,
                        onEraseShape: { viewModel.eraseShapeRegion(rect: $0, ellipse: $1) },
                        polygonVertices: viewModel.polygonVertices,
                        onPolygonVertex: { viewModel.addPolygonVertex($0) },
                        onPolygonComplete: { viewModel.closePolygonPath() },
                        onPolygonRemoveLast: { viewModel.removeLastVertex() },
                        onPolygonCancel: { viewModel.cancelPolygon() },
                        onMoveVertex: { viewModel.moveVertex(at: $0, to: $1) },
                        onCurveSegment: { viewModel.curveSegment(at: $0, through: $1) },
                        onFinalizeCurveSegment: { viewModel.finalizeCurveSegment(at: $0, through: $1) },
                        onInsertVertex: { viewModel.insertVertexOnSegment($0, at: $1) },
                        penSmooth: viewModel.penSmooth,
                        isWandMode: viewModel.isWandMode,
                        wandContourPath: viewModel.wandContourPath,
                        onWandClick: { viewModel.runMagicWand(at: $0, additive: $1) },
                        onWandInvert: { viewModel.invertWandSelection() },
                        isSliceMode: viewModel.isSliceMode,
                        sliceRows: viewModel.resolvedSliceRows,
                        sliceColumns: viewModel.resolvedSliceColumns,
                        sliceAutoDetect: viewModel.sliceAutoDetect,
                        detectedBoxes: viewModel.detectedBoxesNormalized,
                        panOffset: viewModel.panOffset,
                        onPanOffsetChange: { viewModel.setPanOffset($0) },
                        onZoomToScale: { viewModel.zoomToScale($0, pan: $1) },
                        darkSpotBoxes: viewModel.darkSpotBoxesNormalized,
                        darkSpotShapes: viewModel.darkSpotShapes,
                        onDarkSpotClick: { viewModel.removeDarkSpot(at: $0) },
                        isSpriteBoxEditMode: viewModel.isSpriteBoxEditMode,
                        onSpriteBoxesChanged: { viewModel.updateSpriteBoxes($0) },
                        isRestoreMode: viewModel.isRestoreMode,
                        removedSpotBoxes: viewModel.removedSpotBoxesNormalized,
                        removedSpotShapes: viewModel.removedSpotShapes,
                        onRemovedSpotClick: { viewModel.restoreRemovedSpot(at: $0) },
                        originalImage: viewModel.originalImage,
                        livePreviewImage: viewModel.lumaLivePreview,
                        pixelSize: viewModel.imagePixelSize,
                        onSelectTool: { viewModel.selectTool($0) }
                    )
                    .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
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
                        Button("") { viewModel.detectPenPathCandidates() }
                            .keyboardShortcut("d", modifiers: .command)
                            .hidden()
                    }

                    if isSidebarCollapsed {
                        collapsedSidebar
                            .frame(width: 52)
                    } else {
                        sidebar
                            .frame(width: 275)
                    }
                }
            } else {
                placeholder
            }

            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WindowOnTopEnforcer()
            // Global hidden shortcut: paste an image / file with Cmd+V.
            Button("") { viewModel.pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: .command)
                .hidden()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            viewModel.handleOpenFile(at: url)
            return true
        }
        .onAppear {
            viewModel.onAppear()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Image")
                    .font(.title3.weight(.semibold))

                Text(viewModel.fileName.isEmpty ? "Waiting for image from Finder Quick Action" : viewModel.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isSaving {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: isSidebarCollapsed ? "sidebar.left" : "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(isSidebarCollapsed ? "Expand Sidebar" : "Minimize Sidebar to Icons")

            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Shortcuts")
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                shortcutCheatSheet
            }
        }
    }

    private var shortcutCheatSheet: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts")
                .font(.headline)
            Group {
                shortcutRow("1 – 5", "Crop · Brush · Pen · Wand · Slice")
                shortcutRow("⌘D", "Auto Pen Path: detect parts")
                shortcutRow("Hold \\", "Compare with original")
                shortcutRow("Scroll / Pinch", "Zoom in & out (at cursor)")
                shortcutRow("Hold Z + drag", "Pan the image")
                shortcutRow("Double-click", "Zoom to point")
                shortcutRow("⌘Z / ⇧⌘Z", "Undo / Redo")
                shortcutRow("⌘= / ⌘- / ⌘0", "Zoom in / out / reset")
                shortcutRow("⌘V", "Paste image or file")
                shortcutRow("Drag & drop", "Open a PNG / JPEG / WebP")
                shortcutRow("⌘Return / Esc", "Done / Cancel")
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 290)
    }

    private func shortcutRow(_ keys: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(keys)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .frame(width: 92, alignment: .leading)
            Text(description)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Controls")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSidebarCollapsed = true
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Minimize Sidebar (Precision Mode)")
                }
                .padding(.horizontal, 4)

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
                        .disabled(viewModel.isEraseMode || viewModel.isPolygonMode || viewModel.isSliceMode)

                        Toggle(
                            "Match crop size",
                            isOn: Binding(
                                get: { viewModel.autoSizeToCrop },
                                set: { viewModel.setAutoSizeToCrop($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .font(.caption)

                        Toggle(
                            "Snap output to powers of 2",
                            isOn: Binding(
                                get: { viewModel.snapPowerOfTwo },
                                set: { viewModel.setSnapPowerOfTwo($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .font(.caption)

                        Toggle(
                            "Trim transparent edges on save",
                            isOn: Binding(
                                get: { viewModel.trimOnSave },
                                set: { viewModel.setTrimOnSave($0) }
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
                        .disabled(viewModel.isEraseMode || viewModel.isPolygonMode || viewModel.isSliceMode)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "lasso")
                                .foregroundStyle(.red)
                            Text("Auto Pen Path Cutout")
                                .font(.subheadline.weight(.semibold))
                        }

                        Text("Detect every part of the subject as an editable pen path, then cycle through the parts (or the full combined outline) and cut.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("Tolerance: \(String(format: "%.0f", viewModel.shapeTolerance))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $viewModel.shapeTolerance, in: 10...200, step: 1)
                            .help("How aggressively background colours are removed. Higher = trims more of a soft glow/halo; lower = keeps more of it.")

                        Button {
                            viewModel.detectPenPathCandidates()
                        } label: {
                            Label(viewModel.isDetectingShape ? "Detecting…" : "Detect Pen Path", systemImage: "lasso")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                        .help("Trace every detected part as an editable pen path  (⌘D)")
                        .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction || viewModel.isRunningLumaKey || viewModel.isDetectingShape || viewModel.inFlightEdits > 0)

                        if viewModel.isDetectingShape {
                            ProgressView().controlSize(.small)
                        }

                        if viewModel.pathCandidates.count > 1 {
                            if viewModel.hasVFXPaths {
                                let labels = ["Core", "Glow", "Hull"]
                                let label = viewModel.currentCandidateIndex < labels.count
                                    ? labels[viewModel.currentCandidateIndex]
                                    : "Path \(viewModel.currentCandidateIndex + 1)"
                                HStack(spacing: 6) {
                                    Button {
                                        viewModel.cyclePrevCandidate()
                                    } label: {
                                        Label("◄ Prev", systemImage: "chevron.backward")
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .help("Previous VFX path")

                                    Text("\(label) \(viewModel.currentCandidateIndex + 1) of \(viewModel.pathCandidates.count) ")
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity)

                                    Button {
                                        viewModel.cycleNextCandidate()
                                    } label: {
                                        Label("Next ►", systemImage: "chevron.forward")
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .help("Next VFX path")
                                }

                                VStack(spacing: 2) {
                                    Text("Expansion: \(String(format: "%.0f", viewModel.shapeExpansion))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Slider(value: $viewModel.shapeExpansion, in: -50...100, step: 1)
                                        .help("Expand outward to cover more glow halo, or contract inward to tighten to the core.")
                                }
                                .onChange(of: viewModel.shapeExpansion) { _ in
                                    viewModel.applyExpansion()
                                }

                            } else {
                                HStack(spacing: 6) {
                                    Button {
                                        viewModel.cyclePrevCandidate()
                                    } label: {
                                        Label("◄ Prev", systemImage: "chevron.backward")
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .help("Previous detected part")

                                    Text("Shape \(viewModel.currentCandidateIndex + 1) of \(viewModel.pathCandidates.count)")
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity)

                                    Button {
                                        viewModel.cycleNextCandidate()
                                    } label: {
                                        Label("Next ►", systemImage: "chevron.forward")
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .help("Next detected part")
                                }

                                Button {
                                    viewModel.selectCombinedOuterPath()
                                } label: {
                                    Label("Full Logo (Combined Boundary)", systemImage: "rectangle.inset.filled")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                                .help("Jump back to the outline that encloses every part.")
                            }
                        }

                        Text("Then use the Pen tool (⌘3): drag dots to refine, click a segment's dot to add one, or cut with Erase Inside / Keep Inside.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Erase") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Mode", selection: Binding(
                            get: { viewModel.currentEditTool },
                            set: { viewModel.selectEditTool($0) }
                        )) {
                            Text("\(Image(systemName: "xmark.circle")) Off").tag(0)
                            Text("\(Image(systemName: "paintbrush.pointed")) Brush").tag(1)
                            Text("\(Image(systemName: "pencil.tip")) Pen").tag(2)
                            Text("\(Image(systemName: "wand.and.stars")) Wand").tag(3)
                            Text("\(Image(systemName: "arrow.uturn.backward.circle")) Restore").tag(4)
                        }
                        .pickerStyle(.segmented)

                        if viewModel.isRestoreMode {
                            Text("Paint to bring back original pixels the key removed.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.isEraseMode || viewModel.isPolygonMode {
                            Toggle(
                                "Erase dark background only",
                                isOn: $viewModel.eraseBackgroundOnly
                            )
                            .toggleStyle(.switch)
                            .font(.caption)
                            .help("Within your brush/lasso, only near-black pixels (using the Luma Key threshold) are removed — bright art is kept. Clean the middle without affecting connected areas like the lower part.")

                            if viewModel.eraseBackgroundOnly {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("BG threshold: \(String(format: "%.0f", viewModel.lumaKeyThreshold))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Slider(value: $viewModel.lumaKeyThreshold, in: 5...80, step: 1)

                                    Text("BG softness: \(String(format: "%.0f", viewModel.lumaKeySoftness))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Slider(value: $viewModel.lumaKeySoftness, in: 0...60, step: 1)

                                    Text("Paint or lasso the area to clean — only dark background goes.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if viewModel.isEraseMode || viewModel.isRestoreMode {
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

                                Text("Hardness: \(String(format: "%.0f", viewModel.eraseBrushHardness * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Slider(
                                    value: $viewModel.eraseBrushHardness,
                                    in: 0.1...1.0,
                                    step: 0.05
                                )
                                .disabled(viewModel.brushShape == .square)
                            }
                        }

                        if viewModel.isPolygonMode {
                            VStack(alignment: .leading, spacing: 6) {
                                Picker("Shape", selection: Binding(
                                    get: { viewModel.penShape },
                                    set: {
                                        viewModel.penShape = $0
                                        viewModel.cancelPolygon()
                                    }
                                )) {
                                    Text("\(Image(systemName: "scribble")) Free").tag(PenShape.free)
                                    Text("\(Image(systemName: "rectangle")) Rect").tag(PenShape.rectangle)
                                    Text("\(Image(systemName: "circle")) Ellipse").tag(PenShape.ellipse)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                if viewModel.penShape == .free {
                                    Toggle("Smooth curve", isOn: Binding(
                                        get: { viewModel.penSmooth },
                                        set: { viewModel.setPenSmooth($0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .font(.caption)
                                    .disabled(viewModel.isPolygonClosed)

                                    if viewModel.isPolygonAwaitingAction {
                                        // ── Phase 2: Path closed, pick an action ──
                                        Text("\(viewModel.polygonVertices.count) pts — path closed")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Text("Choose an action for the selection:")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)

                                        VStack(spacing: 6) {
                                            Button {
                                                viewModel.completePolygon()
                                            } label: {
                                                Label("Erase Inside", systemImage: "eraser")
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.red.opacity(0.8))
                                            .font(.caption)
                                            .help("Remove everything inside the selection")

                                            Button {
                                                viewModel.keepInsidePolygon()
                                            } label: {
                                                Label("Keep Inside", systemImage: "scissors")
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.teal)
                                            .font(.caption)
                                            .help("Keep the inside, erase everything outside")

                                            HStack(spacing: 8) {
                                                Button {
                                                    viewModel.isPolygonClosed = false
                                                } label: {
                                                    Label("Reopen", systemImage: "arrow.uturn.backward")
                                                }
                                                .buttonStyle(.bordered)
                                                .font(.caption)
                                                .help("Reopen the path to keep editing vertices")

                                                Button(role: .destructive) {
                                                    viewModel.cancelPolygon()
                                                } label: {
                                                    Label("Cancel", systemImage: "xmark")
                                                }
                                                .buttonStyle(.bordered)
                                                .font(.caption)
                                            }
                                        }

                                    } else if viewModel.isDrawingPolygon {
                                        // ── Phase 1: Drawing points ──
                                        Text(viewModel.penSmooth
                                            ? "\(viewModel.polygonVertices.count) pts — placing points auto-smooths the curve; tap a line to add a point"
                                            : "\(viewModel.polygonVertices.count) pts — drag the line to curve (arc); tap the line to add a point")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Text("Drag a dot to move • Return/1st dot closes • Backspace removes last • Esc cancels")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)

                                        HStack(spacing: 8) {
                                            Button {
                                                viewModel.closePolygonPath()
                                            } label: {
                                                Label("Close Path", systemImage: "checkmark")
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .font(.caption)
                                            .disabled(viewModel.polygonVertices.count < 3)
                                            .help("Close the path, then choose an action")

                                            Button(role: .destructive) {
                                                viewModel.cancelPolygon()
                                            } label: {
                                                Label("Cancel", systemImage: "xmark")
                                            }
                                            .buttonStyle(.bordered)
                                            .font(.caption)
                                        }
                                    } else {
                                        Text(viewModel.penSmooth
                                            ? "Click points around the shape — the curve auto-smooths through them"
                                            : "Click to place dots; then drag the line between dots to curve")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("Drag to cut a \(viewModel.penShape == .ellipse ? "circle/oval" : "rectangle/square") — hold Shift for a perfect \(viewModel.penShape == .ellipse ? "circle" : "square").")
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

                        if viewModel.isEraseMode || viewModel.isPolygonMode || viewModel.isWandMode || viewModel.isRestoreMode {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Feather: \(String(format: "%.0f", viewModel.eraseFeather))px")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Slider(
                                    value: $viewModel.eraseFeather,
                                    in: 0...20,
                                    step: 1
                                )
                            }
                        }

                        if viewModel.isEraseMode || viewModel.isPolygonMode || viewModel.isWandMode || viewModel.isRestoreMode || viewModel.hasEdits {
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

                                if viewModel.hasEdits {
                                    Button(role: .destructive) {
                                        viewModel.clearErase()
                                    } label: {
                                        Label("Reset edits", systemImage: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                GroupBox("Slice") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Slice preview",
                            isOn: Binding(
                                get: { viewModel.isSliceMode },
                                set: { _ in viewModel.toggleSliceMode() }
                            )
                        )
                        .toggleStyle(.switch)
                        .font(.caption)

                        Picker("", selection: Binding(
                            get: { viewModel.sliceAutoDetect },
                            set: { viewModel.setSliceAutoDetect($0) }
                        )) {
                            Text("Grid").tag(false)
                            Text("Auto-detect").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if viewModel.sliceAutoDetect {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Min size (px)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("Min", text: Binding(
                                        get: { viewModel.spriteMinSize },
                                        set: { viewModel.updateSpriteMinSize($0) }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Padding (px)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("Pad", text: Binding(
                                        get: { viewModel.spritePadding },
                                        set: { viewModel.updateSpritePadding($0) }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Gap (px)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("Gap", text: Binding(
                                        get: { viewModel.spriteGap },
                                        set: { viewModel.updateSpriteGap($0) }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                }
                            }

                            HStack {
                                if viewModel.isDetectingSprites {
                                    Text("Detecting…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(viewModel.detectedSpriteBoxes.count) sprites found")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    viewModel.detectSprites()
                                } label: {
                                    Label("Re-detect", systemImage: "arrow.clockwise")
                                }
                                .font(.caption2)
                                .disabled(!viewModel.hasLoadedImage || !viewModel.isSliceMode)
                            }

                            if !viewModel.detectedSpriteBoxes.isEmpty {
                                Toggle(
                                    "Edit boxes",
                                    isOn: Binding(
                                        get: { viewModel.isSpriteBoxEditMode },
                                        set: { viewModel.isSpriteBoxEditMode = $0 }
                                    )
                                )
                                .toggleStyle(.switch)
                                .font(.caption2)

                                if viewModel.isSpriteBoxEditMode {
                                    HStack(spacing: 6) {
                                        Button {
                                            viewModel.addSpriteBox()
                                        } label: {
                                            Label("Add Box", systemImage: "plus.square")
                                        }
                                        .buttonStyle(.bordered)
                                        .font(.caption2)

                                        Spacer()

                                        Text("Drag to move • Handles to resize • Right-click to delete/split")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Rows")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("Rows", text: Binding(
                                        get: { viewModel.sliceRows },
                                        set: { viewModel.updateSliceRows($0) }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Columns")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("Cols", text: Binding(
                                        get: { viewModel.sliceColumns },
                                        set: { viewModel.updateSliceColumns($0) }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                }
                            }

                            Text("\(viewModel.resolvedSliceRows * viewModel.resolvedSliceColumns) sprites, left→right top→bottom")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Toggle(
                            "Also export packed atlas (PNG + JSON)",
                            isOn: $viewModel.exportAtlas
                        )
                        .toggleStyle(.switch)
                        .font(.caption2)

                        Button {
                            viewModel.exportSprites()
                        } label: {
                            Label("Export Sprites", systemImage: "square.grid.3x3")
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                        .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction || viewModel.isRunningLumaKey)
                    }
                }

                GroupBox("Shell Actions (.zshrc)") {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            actionButton(.rem)
                            actionButton(.slice)
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
                    }
                }

            GroupBox("Luma Key (Black BG → Alpha)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Flood-fills from edges — removes only black connected to the border. Dark parts inside the asset are preserved.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Threshold: \(String(format: "%.0f", viewModel.lumaKeyThreshold))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: $viewModel.lumaKeyThreshold,
                        in: 5...80,
                        step: 1
                    )
                    .onChange(of: viewModel.lumaKeyThreshold) { _ in viewModel.scheduleLumaPreview() }

                    Text("Softness: \(String(format: "%.0f", viewModel.lumaKeySoftness))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: $viewModel.lumaKeySoftness,
                        in: 0...60,
                        step: 1
                    )
                    .onChange(of: viewModel.lumaKeySoftness) { _ in viewModel.scheduleLumaPreview() }

                    Text("Feather: \(String(format: "%.0f", viewModel.lumaKeyFeather))px")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: $viewModel.lumaKeyFeather,
                        in: 0...20,
                        step: 1
                    )
                    .onChange(of: viewModel.lumaKeyFeather) { _ in viewModel.scheduleLumaPreview() }

                    Text("Tip: drag the sliders to preview live, then Run to apply.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.runLumaKey()
                    } label: {
                        Label("Run Luma Key", systemImage: "moon.z")
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                    .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction || viewModel.isRunningLumaKey)

                    if viewModel.isRunningLumaKey {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Keying...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Text("Min spot size")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("16", text: Binding(
                            get: { viewModel.darkSpotMinSize },
                            set: { viewModel.updateDarkSpotMinSize($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 60)
                        Spacer()
                    }

                    Toggle(
                        "Include luma-key areas (edge-connected)",
                        isOn: Binding(
                            get: { viewModel.darkSpotIncludeEdges },
                            set: { viewModel.setDarkSpotIncludeEdges($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .font(.caption2)
                    .help("Also detect the dark regions a Luma Key would remove, so you can take them out selectively instead of all at once.")

                    Button {
                        viewModel.detectDarkSpots()
                    } label: {
                        Label("Detect Dark Spots", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction || viewModel.isRunningLumaKey || viewModel.isDetectingDarkSpots)

                    if viewModel.isDetectingDarkSpots {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Detecting...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !viewModel.detectedDarkSpots.isEmpty {
                        HStack {
                            Text("\(viewModel.detectedDarkSpots.count) spot\(viewModel.detectedDarkSpots.count == 1 ? "" : "s") — click to remove")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Spacer()
                            Button("Remove All") {
                                viewModel.removeAllDarkSpots()
                            }
                            .font(.caption2)
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isSaving || viewModel.inFlightEdits > 0)
                            Button("Clear") {
                                viewModel.clearDarkSpots()
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    Text("Restore parts the key removed: detect enclosed holes, dark outlines, edge shadows, and crevices.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text("Min area")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("16", text: Binding(
                            get: { viewModel.removedSpotMinSize },
                            set: { viewModel.updateRemovedSpotMinSize($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 60)
                        Spacer()
                    }

                    Toggle(
                        "Include edge shadows & outlines",
                        isOn: Binding(
                            get: { viewModel.removedSpotIncludeEdges },
                            set: { viewModel.setRemovedSpotIncludeEdges($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .font(.caption2)
                    .help("Also detect deleted black outlines, shadows under layers, and edge crevices so you can restore their blackness without restoring the whole background.")

                    Button {
                        viewModel.detectRemovedSpots()
                    } label: {
                        Label("Detect Removed Spots", systemImage: "arrow.uturn.backward.square")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction || viewModel.isRunningLumaKey || viewModel.isDetectingRemovedSpots)

                    if viewModel.isDetectingRemovedSpots {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Detecting...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !viewModel.detectedRemovedSpots.isEmpty {
                        HStack {
                            Text("\(viewModel.detectedRemovedSpots.count) area\(viewModel.detectedRemovedSpots.count == 1 ? "" : "s") — click to restore")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Restore All") {
                                viewModel.restoreAllRemovedSpots()
                            }
                            .font(.caption2)
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isSaving || viewModel.inFlightEdits > 0)
                            Button("Clear") {
                                viewModel.clearRemovedSpots()
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            GroupBox("Preview") {
                ZStack {
                    CheckerboardView()
                        .clipShape(RoundedRectangle(cornerRadius: 8))

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

                Text("Right-click an image (PNG, JPEG, WebP) and run Quick Action: Edit Image")
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
            .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningShellAction || viewModel.isRunningLumaKey || viewModel.inFlightEdits > 0)
        }
    }

    private func actionButton(_ action: ShellImageAction) -> some View {
        Button(action.title) {
            viewModel.runShellAction(action)
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

    private var collapsedSidebar: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSidebarCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .help("Expand Sidebar")

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    Group {
                        collapsedToolButton(title: "Crop / Select Mode", icon: "crop", tag: 0)
                        collapsedToolButton(title: "Brush Erase", icon: "paintbrush.pointed", tag: 1)
                        collapsedToolButton(title: "Pen / Lasso Cutout", icon: "pencil.tip", tag: 2)
                        collapsedToolButton(title: "Magic Wand", icon: "wand.and.stars", tag: 3)
                        collapsedToolButton(title: "Restore Original", icon: "arrow.uturn.backward.circle", tag: 4)
                    }

                    Divider()
                        .padding(.vertical, 2)

                    // Auto Pen Path Cutout
                    Button {
                        viewModel.detectPenPathCandidates()
                    } label: {
                        Image(systemName: "lasso")
                            .font(.system(size: 15))
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningLumaKey || viewModel.isDetectingShape || viewModel.inFlightEdits > 0)
                    .help("Detect Pen Path (⌘D)")

                    // Luma Key
                    Button {
                        viewModel.runLumaKey()
                    } label: {
                        Image(systemName: "moon.z")
                            .font(.system(size: 15))
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.hasLoadedImage || viewModel.isSaving || viewModel.isRunningLumaKey)
                    .help("Run Luma Key")

                    // Slice Mode Toggle
                    Button {
                        viewModel.toggleSliceMode()
                    } label: {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 15))
                            .foregroundStyle(viewModel.isSliceMode ? Color.accentColor : Color.primary)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(viewModel.isSliceMode ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                            )
                    }
                    .buttonStyle(.borderless)
                    .help("Toggle Slice Grid")

                    Divider()
                        .padding(.vertical, 2)

                    // Undo / Redo / Reset
                    Button {
                        viewModel.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.canUndo)
                    .help("Undo (⌘Z)")

                    Button {
                        viewModel.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 14))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.canRedo)
                    .help("Redo (⇧⌘Z)")

                    if viewModel.hasEdits {
                        Button {
                            viewModel.clearErase()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundStyle(.red)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .help("Reset Edits")
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
    }

    private func collapsedToolButton(title: String, icon: String, tag: Int) -> some View {
        let isSelected = viewModel.currentEditTool == tag
        return Button {
            viewModel.selectEditTool(tag)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}
