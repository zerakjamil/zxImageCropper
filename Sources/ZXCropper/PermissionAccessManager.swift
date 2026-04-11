import AppKit
import Foundation

final class PermissionAccessManager {
    static let shared = PermissionAccessManager()

    private let bookmarksKey = "ZXCropper.SecurityScopedFolderBookmarks"
    private var scopedFolders: [URL] = []

    private init() {
        restoreBookmarks()
    }

    func canAccess(_ fileURL: URL) -> Bool {
        let standardizedFileURL = fileURL.standardizedFileURL

        if FileManager.default.isReadableFile(atPath: standardizedFileURL.path) {
            return true
        }

        return scopedFolders.contains(where: { folder in
            let folderPath = folder.standardizedFileURL.path
            let filePath = standardizedFileURL.path
            return filePath == folderPath || filePath.hasPrefix(folderPath + "/")
        })
    }

    @discardableResult
    func requestFolderAccess(startingAt directoryURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Choose a folder to grant persistent access. For example: Downloads."
        panel.directoryURL = directoryURL

        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.url else {
            return nil
        }

        do {
            let bookmarkData = try selectedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            storeBookmarkData(bookmarkData)

            var stale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            _ = resolvedURL.startAccessingSecurityScopedResource()
            appendScopedFolderIfNeeded(resolvedURL)

            if stale {
                let refreshedData = try resolvedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                storeBookmarkData(refreshedData)
            }

            return resolvedURL
        } catch {
            return nil
        }
    }

    private func restoreBookmarks() {
        guard let stored = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] else {
            return
        }

        var refreshedBookmarks: [Data] = []

        for data in stored {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )

                _ = url.startAccessingSecurityScopedResource()
                appendScopedFolderIfNeeded(url)

                if stale {
                    let refreshedData = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    refreshedBookmarks.append(refreshedData)
                } else {
                    refreshedBookmarks.append(data)
                }
            } catch {
                continue
            }
        }

        UserDefaults.standard.set(refreshedBookmarks, forKey: bookmarksKey)
    }

    private func storeBookmarkData(_ data: Data) {
        var existing = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        if !existing.contains(data) {
            existing.append(data)
            UserDefaults.standard.set(existing, forKey: bookmarksKey)
        }
    }

    private func appendScopedFolderIfNeeded(_ url: URL) {
        let standardized = url.standardizedFileURL
        if !scopedFolders.contains(where: { $0.standardizedFileURL.path == standardized.path }) {
            scopedFolders.append(standardized)
        }
    }
}
