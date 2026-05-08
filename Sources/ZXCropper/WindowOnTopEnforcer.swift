import AppKit
import SwiftUI

struct WindowOnTopEnforcer: NSViewRepresentable {
    final class Coordinator {
        var configuredWindowIDs: Set<ObjectIdentifier> = []
    }

    private let maxWindowAttachRetries = 15
    private let retryDelay: TimeInterval = 0.08
    private let compactSize = NSSize(width: 980, height: 730)
    private let minSize = NSSize(width: 940, height: 660)
    private let maxSize = NSSize(width: 1120, height: 820)

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
            promoteWhenAttached(view: view, coordinator: coordinator, remainingRetries: maxWindowAttachRetries)
        }
    }

    private func promoteWhenAttached(view: NSView, coordinator: Coordinator, remainingRetries: Int) {
        guard let window = view.window else {
            guard remainingRetries > 0 else {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                promoteWhenAttached(view: view, coordinator: coordinator, remainingRetries: remainingRetries - 1)
            }

            return
        }

        let id = ObjectIdentifier(window)
        if !coordinator.configuredWindowIDs.contains(id) {
            coordinator.configuredWindowIDs.insert(id)
            window.level = .floating
            applyCompactWindowConstraints(window, forceCompactFrame: true)
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // One delayed promotion helps in cases where Finder/services steals focus back briefly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func applyCompactWindowConstraints(_ window: NSWindow, forceCompactFrame: Bool) {
        window.minSize = minSize
        window.maxSize = maxSize

        let current = window.frame.size
        let needsCompaction = current.width > maxSize.width || current.height > maxSize.height || current.width < minSize.width || current.height < minSize.height

        guard forceCompactFrame || needsCompaction else {
            return
        }

        let targetSize = NSSize(
            width: min(max(compactSize.width, minSize.width), maxSize.width),
            height: min(max(compactSize.height, minSize.height), maxSize.height)
        )

        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let centeredOrigin: NSPoint

        if let screenFrame {
            centeredOrigin = NSPoint(
                x: screenFrame.origin.x + (screenFrame.width - targetSize.width) / 2,
                y: screenFrame.origin.y + (screenFrame.height - targetSize.height) / 2
            )
        } else {
            centeredOrigin = window.frame.origin
        }

        let targetFrame = NSRect(origin: centeredOrigin, size: targetSize)
        window.setFrame(targetFrame, display: true, animate: false)
    }
}
