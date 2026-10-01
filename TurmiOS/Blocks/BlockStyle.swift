import SwiftTerm
import TurmCore
import UIKit

extension NSAttributedString.Key {
    static let blockFontStyle = NSAttributedString.Key("turm.fontStyle")
}

enum BlockTheme {
    static let text = color(TerminalPalette.foreground)
    static let background = color(TerminalPalette.background)
    static let added = color(light: 0x1A7F37, dark: 0x8CD973)
    static let ghost = tint(light: 0.32, dark: 0.3)

    static func color(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    static func color(_ palette: PaletteColor) -> UIColor {
        color(light: palette.light, dark: palette.dark)
    }

    private static func tint(light: CGFloat, dark: CGFloat) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: dark) : UIColor(white: 0, alpha: light) }
    }
}

enum BlockStyle {
    private static let ansi = TerminalPalette.ansi.map { BlockTheme.color($0) }
    private static var fonts: [String: UIFont] = [:]

    static func attributes(_ attribute: Attribute) -> [NSAttributedString.Key: Any] {
        var foreground = color(attribute.fg)
        var background = color(attribute.bg)
        if attribute.style.contains(.inverse) {
            let swapped = background ?? BlockTheme.background
            background = foreground ?? BlockTheme.text
            foreground = swapped
        }
        var ink = foreground ?? BlockTheme.text
        if attribute.style.contains(.dim) { ink = ink.withAlphaComponent(0.6) }
        if attribute.style.contains(.invisible) { ink = .clear }
        let fontStyle = (attribute.style.contains(.bold) ? 1 : 0) | (attribute.style.contains(.italic) ? 2 : 0)
        var result: [NSAttributedString.Key: Any] = [.foregroundColor: ink, .blockFontStyle: fontStyle]
        if let background { result[.backgroundColor] = background }

        var underline = attribute.underlineStyle
        if underline == .none, attribute.style.contains(.underline) { underline = .single }
        switch underline {
        case .none: break
        case .single, .curly: result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case .double: result[.underlineStyle] = NSUnderlineStyle.double.rawValue
        case .dotted: result[.underlineStyle] = NSUnderlineStyle([.single, .patternDot]).rawValue
        case .dashed: result[.underlineStyle] = NSUnderlineStyle([.single, .patternDash]).rawValue
        }
        if underline != .none, let underlineColor = attribute.underlineColor.flatMap({ color($0) }) {
            result[.underlineColor] = underlineColor
        }
        if attribute.style.contains(.crossedOut) { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return result
    }

    static func font(style: Int, size: Double) -> UIFont {
        let key = "\(style)-\(size)"
        if let cached = fonts[key] { return cached }
        let base = UIFont.monospacedSystemFont(ofSize: size, weight: style & 1 != 0 ? .bold : .regular)
        var font = base
        if style & 2 != 0, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        if fonts.count > 64 { fonts.removeAll() }
        fonts[key] = font
        return font
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.foregroundColor: BlockTheme.text, .blockFontStyle: 0])
    }

    static func display(_ text: NSAttributedString, size: Double) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        result.beginEditing()
        result.enumerateAttribute(.blockFontStyle, in: whole) { value, range, _ in
            result.addAttribute(.font, value: font(style: value as? Int ?? 0, size: size), range: range)
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        result.endEditing()
        return result
    }

    static func cellSize(fontSize: Double) -> CGSize {
        let font = font(style: 0, size: fontSize)
        return CGSize(width: ("M" as NSString).size(withAttributes: [.font: font]).width, height: font.lineHeight)
    }

    private static func color(_ value: Attribute.Color) -> UIColor? {
        switch value {
        case .defaultColor, .defaultInvertedColor:
            return nil
        case .trueColor(let red, let green, let blue):
            return rgb(red, green, blue)
        case .ansi256(let code):
            return indexed(Int(code))
        }
    }

    private static func indexed(_ code: Int) -> UIColor {
        if code < 16 { return ansi[code] }
        if code < 232 {
            let index = code - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return rgb(levels[index / 36], levels[(index / 6) % 6], levels[index % 6])
        }
        let level = UInt8(8 + (code - 232) * 10)
        return rgb(level, level, level)
    }

    private static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
