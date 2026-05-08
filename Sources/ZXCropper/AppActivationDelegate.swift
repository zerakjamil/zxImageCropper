import AppKit

final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    var onOpenFile: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        focusEditorWindows(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        onOpenFile?(url)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        focusEditorWindows(ignoringOtherApps: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        focusEditorWindows(ignoringOtherApps: true)
        return true
    }

    private func focusEditorWindows(ignoringOtherApps: Bool) {
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
        }
    }
}
