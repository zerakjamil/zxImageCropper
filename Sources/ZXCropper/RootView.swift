import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 14) {
            header

            if let sourceImage = viewModel.sourceImage {
                HStack(spacing: 16) {
                    CropCanvasView(
                        image: sourceImage,
                        cropRectNormalized: Binding(
                            get: { viewModel.cropRectNormalized },
                            set: { viewModel.updateCropRect($0) }
                        ),
                        aspectRatio: viewModel.selectedAspectPreset.ratio
                    )
                    .frame(minWidth: 600, minHeight: 420)

                    sidebar
                        .frame(width: 290)
                }
            } else {
                placeholder
            }

            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowOnTopEnforcer())
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
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Aspect Preset") {
                Picker(
                    "Aspect Preset",
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
            }

            GroupBox("Resize Output") {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Width")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "Width",
                            text: Binding(
                                get: { viewModel.resizeWidth },
                                set: { viewModel.updateResizeWidth($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Height")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "Height",
                            text: Binding(
                                get: { viewModel.resizeHeight },
                                set: { viewModel.updateResizeHeight($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Button("Reset Crop") {
                    viewModel.resetCrop()
                }
                .buttonStyle(.bordered)

                Spacer()
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
                .frame(height: 190)
            }

            Spacer(minLength: 0)

            Text("PNG only in v1. Done creates backup then overwrites the original.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text("Launch from Finder")
                .font(.headline)

            Text("Right-click a PNG file and run Quick Action: Edit Image")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                Text("Resize using side/corner handles. Cmd+Return = Done, Esc = Cancel, Option+Drag outside = redraw")
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
            .disabled(!viewModel.hasLoadedImage || viewModel.isSaving)
        }
    }
}
