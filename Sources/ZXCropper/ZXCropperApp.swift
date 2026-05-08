import AppKit
import SwiftUI

@main
struct ZXCropperApp: App {
    @NSApplicationDelegateAdaptor(AppActivationDelegate.self) private var appDelegate
    @StateObject private var viewModel = EditorViewModel(imagePath: LaunchArguments.imagePath)

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Edit Image") {
            RootView(viewModel: viewModel)
                .frame(
                    minWidth: 940,
                    idealWidth: 980,
                    maxWidth: 1120,
                    minHeight: 660,
                    idealHeight: 730,
                    maxHeight: 820
                )
                .onAppear {
                    appDelegate.onOpenFile = { [weak viewModel] url in
                        viewModel?.handleOpenFile(at: url)
                    }
                }
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
