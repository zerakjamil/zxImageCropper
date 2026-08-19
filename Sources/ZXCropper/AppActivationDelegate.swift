import AppKit

final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    var onOpenFile: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        focusEditorWindows(ignoringOtherApps: true)

        for delay in [0.04, 0.1, 0.2, 0.35, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusEditorWindows(ignoringOtherApps: true)
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        onOpenFile?(url)
        focusEditorWindows(ignoringOtherApps: true)

        for delay in [0.04, 0.1, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusEditorWindows(ignoringOtherApps: true)
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        focusEditorWindows(ignoringOtherApps: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        focusEditorWindows(ignoringOtherApps: true)
        return true
    }

    func focusEditorWindows(ignoringOtherApps: Bool) {
        if ignoringOtherApps {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
        }

        NSApp.unhide(nil)

        for window in NSApp.windows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

