import Foundation

enum ShellImageAction: String, CaseIterable, Identifiable {
    case luma
    case slice
    case rem
    case remgreen
    case gm

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
        case .luma, .rem, .remgreen, .gm:
            return true
        }
    }
}
