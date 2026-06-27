import Foundation

enum ShellImageAction: String, CaseIterable, Identifiable {
    case slice
    case rem

    var id: String { rawValue }

    var title: String {
        rawValue.uppercased()
    }

    var commandName: String {
        rawValue
    }

    var expectsSingleImageOutput: Bool {
        switch self {
        case .slice:
            return false
        case .rem:
            return true
        }
    }
}
