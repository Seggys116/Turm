import AppKit
import SwiftUI

struct ThemeColor {
    let light: NSColor
    let dark: NSColor

    init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    var dynamicNS: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    var color: Color {
        Color(nsColor: dynamicNS)
    }

    func resolved(dark isDark: Bool) -> NSColor {
        isDark ? dark : light
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Theme {
    static let terminalBackground = ThemeColor(light: 0xFFFFFF, dark: 0x0B0B0C)
    static let inputBackground = ThemeColor(light: 0xF5F5F7, dark: 0x111113)
    static let topBar = ThemeColor(light: 0xE6E6EA, dark: 0x1B1B1F)
    static let sidebar = ThemeColor(light: 0xEBEBEE, dark: 0x0E0E10)
    static let statusBar = ThemeColor(light: 0xECECF0, dark: 0x151518)
    static let text = ThemeColor(light: 0x1F2328, dark: 0xDCDCDC)
    static let divider = ThemeColor(
        light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.12)
    )
    static let subtleDivider = ThemeColor(
        light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.07)
    )
    static let secondaryText = ThemeColor(
        light: NSColor(white: 0, alpha: 0.5), dark: NSColor(white: 1, alpha: 0.45)
    )
    static let chipFill = ThemeColor(
        light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.08)
    )
    static let chipStroke = ThemeColor(
        light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.12)
    )
    static let dropOutline = ThemeColor(
        light: NSColor(white: 0, alpha: 0.32), dark: NSColor(white: 1, alpha: 0.38)
    )
    static let dropFill = ThemeColor(
        light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.05)
    )
    static let added = ThemeColor(light: 0x1A7F37, dark: 0x8CD973)
    static let removed = ThemeColor(light: 0xCF222E, dark: 0xF26B78)
    static let failure = ThemeColor(light: 0xCF222E, dark: 0xF26B78)
    static let syntaxCommand = ThemeColor(light: 0x1A7F37, dark: 0x8FD46D)
    static let syntaxBuiltin = ThemeColor(light: 0x0969DA, dark: 0x61AFEF)
    static let syntaxFunction = ThemeColor(light: 0x0A7B8C, dark: 0x4FC1D0)
    static let syntaxKeyword = ThemeColor(light: 0x8250DF, dark: 0xC678DD)
    static let syntaxFlag = ThemeColor(light: 0x7D4E00, dark: 0xD7BA7D)
    static let syntaxString = ThemeColor(light: 0xB35900, dark: 0xE5A56B)
    static let syntaxVariable = ThemeColor(light: 0xBF3989, dark: 0xF08FC0)
    static let syntaxOperator = ThemeColor(light: 0x6E7781, dark: 0x9AA0AA)
    static let syntaxComment = ThemeColor(light: 0x8C959F, dark: 0x6B7280)
    static let syntaxGroup = ThemeColor(light: 0x953800, dark: 0xD19A66)
    static let syntaxError = ThemeColor(light: 0xCF222E, dark: 0xF26B78)
    static let scrollKnob = ThemeColor(
        light: NSColor(white: 0, alpha: 0.26), dark: NSColor(white: 1, alpha: 0.22)
    )
    static let scrollKnobActive = ThemeColor(
        light: NSColor(white: 0, alpha: 0.45), dark: NSColor(white: 1, alpha: 0.4)
    )
    static let inputGhost = ThemeColor(
        light: NSColor(white: 0, alpha: 0.32), dark: NSColor(white: 1, alpha: 0.3)
    )

    static let ansi: [ThemeColor] = [
        ThemeColor(light: 0x24292F, dark: 0x1D1F21), ThemeColor(light: 0xCF222E, dark: 0xF26D78),
        ThemeColor(light: 0x1A7F37, dark: 0x8FD46D), ThemeColor(light: 0x9A6700, dark: 0xE6C547),
        ThemeColor(light: 0x0969DA, dark: 0x61AFEF), ThemeColor(light: 0x8250DF, dark: 0xC678DD),
        ThemeColor(light: 0x1B7C83, dark: 0x56B6C2), ThemeColor(light: 0x6E7781, dark: 0xC8CCD4),
        ThemeColor(light: 0x57606A, dark: 0x5C6370), ThemeColor(light: 0xA40E26, dark: 0xFF8B94),
        ThemeColor(light: 0x2DA44E, dark: 0xB5F08E), ThemeColor(light: 0xBF8700, dark: 0xF5DB7A),
        ThemeColor(light: 0x218BFF, dark: 0x82C4FF), ThemeColor(light: 0xA475F9, dark: 0xDD9AF0),
        ThemeColor(light: 0x3192AA, dark: 0x7AD5E0), ThemeColor(light: 0x8C959F, dark: 0xFFFFFF),
    ]
}
