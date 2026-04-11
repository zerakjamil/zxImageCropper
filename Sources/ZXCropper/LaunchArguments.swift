import Foundation

enum LaunchArguments {
    static var imagePath: String? {
        CommandLine.arguments
            .dropFirst()
            .first(where: { !$0.hasPrefix("--") })
    }
}
