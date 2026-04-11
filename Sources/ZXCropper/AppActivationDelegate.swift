import AppKit

final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        promoteEditorWindowsWithRetries()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        promoteEditorWindowsWithRetries()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        promoteEditorWindowsWithRetries()
        return true
    }

    private func promoteEditorWindowsWithRetries() {
        for index in 0...20 {
            let delay = DispatchTime.now() + (0.10 * Double(index))
            DispatchQueue.main.asyncAfter(deadline: delay) {
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                NSApp.unhide(nil)

                let candidateWindows = NSApp.windows.filter { !$0.isMiniaturized }
                for window in candidateWindows {
                    window.level = .floating
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }
}
