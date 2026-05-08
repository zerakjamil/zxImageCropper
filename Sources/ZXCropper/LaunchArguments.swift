import Foundation

enum LaunchArguments {
    static var imagePath: String? {
        let candidates = CommandLine.arguments.dropFirst()

        // Ignore launch flags like -psn_0_12345 that macOS injects for app launches.
        if let explicitPath = candidates.first(where: isLikelyImagePathArgument) {
            return explicitPath
        }

        return candidates.first(where: { !$0.hasPrefix("-") })
    }

    private static func isLikelyImagePathArgument(_ argument: String) -> Bool {
        if argument.hasPrefix("-") {
            return false
        }

        if let url = URL(string: argument), url.isFileURL {
            return true
        }

        return FileManager.default.fileExists(atPath: argument)
    }
}
