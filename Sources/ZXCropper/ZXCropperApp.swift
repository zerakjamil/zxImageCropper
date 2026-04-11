import AppKit
import SwiftUI

@main
struct ZXCropperApp: App {
    @StateObject private var viewModel = EditorViewModel(imagePath: LaunchArguments.imagePath)

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Edit Image") {
            RootView(viewModel: viewModel)
                .frame(
                    minWidth: 930,
                    idealWidth: 980,
                    maxWidth: 1040,
                    minHeight: 630,
                    idealHeight: 680,
                    maxHeight: 760
                )
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
