import AppKit
import SwiftUI

struct WindowOnTopEnforcer: NSViewRepresentable {
    final class Coordinator {
        var configuredWindowIDs: Set<ObjectIdentifier> = []
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureIfNeeded(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureIfNeeded(for: nsView, coordinator: context.coordinator)
    }

    private func configureIfNeeded(for view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            let id = ObjectIdentifier(window)
            guard !coordinator.configuredWindowIDs.contains(id) else {
                return
            }

            coordinator.configuredWindowIDs.insert(id)

            NSApp.activate(ignoringOtherApps: true)
            window.level = .floating
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
