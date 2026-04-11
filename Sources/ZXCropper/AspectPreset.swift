import CoreGraphics

enum AspectPreset: String, CaseIterable, Identifiable {
    case free = "Free"
    case square = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case threeTwo = "3:2"

    var id: String { rawValue }

    var ratio: CGFloat? {
        switch self {
        case .free:
            return nil
        case .square:
            return 1.0
        case .fourThree:
            return 4.0 / 3.0
        case .sixteenNine:
            return 16.0 / 9.0
        case .threeTwo:
            return 3.0 / 2.0
        }
    }
}
