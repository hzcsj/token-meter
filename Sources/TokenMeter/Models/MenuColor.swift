import AppKit

enum MenuColor {
    case primary
    case secondary
    case red
    case orange
    case gray

    var nsColor: NSColor {
        switch self {
        case .primary:
            return NSColor(calibratedWhite: 1.0, alpha: 1.0)
        case .secondary:
            return NSColor(calibratedWhite: 0.7, alpha: 1.0)
        case .red:
            return NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1.0)
        case .orange:
            return NSColor(srgbRed: 1.0, green: 0.7, blue: 0.3, alpha: 1.0)
        case .gray:
            return NSColor(calibratedWhite: 0.5, alpha: 1.0)
        }
    }
}
