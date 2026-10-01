import SwiftUI
import TurmCore
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func chrome(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    static func chromeTint(light: CGFloat, dark: CGFloat) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: dark) : UIColor(white: 0, alpha: light) }
    }
}

enum Chrome {
    enum UI {
        static let terminalBackground = UIColor.chrome(light: TerminalPalette.background.light, dark: TerminalPalette.background.dark)
        static let inputBackground = UIColor.chrome(light: 0xF5F5F7, dark: 0x111113)
        static let topBar = UIColor.chrome(light: 0xE6E6EA, dark: 0x1B1B1F)
        static let sidebar = UIColor.chrome(light: 0xEBEBEE, dark: 0x0E0E10)
        static let statusBar = UIColor.chrome(light: 0xECECF0, dark: 0x151518)
        static let text = UIColor.chrome(light: TerminalPalette.foreground.light, dark: TerminalPalette.foreground.dark)
        static let accent = UIColor.chrome(light: 0x1F2328, dark: 0xE4E4E7)
        static let onAccent = UIColor.chrome(light: 0xFFFFFF, dark: 0x0B0B0C)
        static let failure = UIColor.chrome(light: 0xCF222E, dark: 0xF26B78)
        static let success = UIColor.chrome(light: 0x1A7F37, dark: 0x8FD46D)
        static let warning = UIColor.chrome(light: 0x9A6700, dark: 0xE6C547)
        static let divider = UIColor.chromeTint(light: 0.12, dark: 0.12)
        static let subtleDivider = UIColor.chromeTint(light: 0.07, dark: 0.07)
        static let secondaryText = UIColor.chromeTint(light: 0.5, dark: 0.45)
        static let chipFill = UIColor.chromeTint(light: 0.05, dark: 0.08)
        static let chipFillPressed = UIColor.chromeTint(light: 0.12, dark: 0.16)
        static let chipStroke = UIColor.chromeTint(light: 0.12, dark: 0.12)
    }

    static let terminalBackground = Color(uiColor: UI.terminalBackground)
    static let inputBackground = Color(uiColor: UI.inputBackground)
    static let topBar = Color(uiColor: UI.topBar)
    static let sidebar = Color(uiColor: UI.sidebar)
    static let statusBar = Color(uiColor: UI.statusBar)
    static let text = Color(uiColor: UI.text)
    static let accent = Color(uiColor: UI.accent)
    static let onAccent = Color(uiColor: UI.onAccent)
    static let failure = Color(uiColor: UI.failure)
    static let success = Color(uiColor: UI.success)
    static let warning = Color(uiColor: UI.warning)
    static let divider = Color(uiColor: UI.divider)
    static let subtleDivider = Color(uiColor: UI.subtleDivider)
    static let secondaryText = Color(uiColor: UI.secondaryText)
    static let chipFill = Color(uiColor: UI.chipFill)
    static let chipStroke = Color(uiColor: UI.chipStroke)

    enum Radius {
        static let chip: CGFloat = 8
        static let group: CGFloat = 12
    }

    enum Metrics {
        static let target: CGFloat = 44
        static let railWidth: CGFloat = 56
        static let minimumStrip: CGFloat = 44
        static let readableWidth: CGFloat = 640

        static func margin(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
            sizeClass == .regular ? 20 : 16
        }
    }

    static var columnMotion: Animation { .spring(duration: 0.32, bounce: 0.08) }

    enum Typeface {
        static let label = Font.system(.footnote, design: .rounded).weight(.medium)
        static let caption = Font.system(.caption, design: .rounded)
        static let section = Font.system(.caption, design: .rounded).weight(.semibold)
        static let body = Font.system(.subheadline, design: .rounded).weight(.medium)
        static let mono = Font.system(.footnote, design: .monospaced)
        static let monoBody = Font.system(.subheadline, design: .monospaced)
        static let title = Font.system(.title3, design: .rounded).weight(.semibold)
        static let barTitle = Font.system(.headline, design: .rounded)
    }

    static func cardShape(minimum: CGFloat = Radius.group + 4) -> AnyShape {
        if #available(iOS 26.0, *) {
            return AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(minimum)), isUniform: true))
        }
        return AnyShape(RoundedRectangle(cornerRadius: minimum, style: .continuous))
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func press() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func confirm() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warn() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
