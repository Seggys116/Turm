import AppKit
import Foundation

enum CurlyUnderlineKey: AttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
    typealias Value = Bool
    typealias ObjectiveCValue = NSNumber
    static let name = "turm.curlyUnderline"

    static func objectiveCValue(for value: Bool) throws -> NSNumber { NSNumber(value: value) }
    static func value(for object: NSNumber) throws -> Bool { object.boolValue }
}

enum BlinkKey: AttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
    typealias Value = Bool
    typealias ObjectiveCValue = NSNumber
    static let name = "turm.blink"

    static func objectiveCValue(for value: Bool) throws -> NSNumber { NSNumber(value: value) }
    static func value(for object: NSNumber) throws -> Bool { object.boolValue }
}

enum FontStyleKey: AttributedStringKey, ObjectiveCConvertibleAttributedStringKey {
    typealias Value = Int
    typealias ObjectiveCValue = NSNumber
    static let name = "turm.fontStyle"

    static func objectiveCValue(for value: Int) throws -> NSNumber { NSNumber(value: value) }
    static func value(for object: NSNumber) throws -> Int { object.intValue }
}

extension AttributeScopes {
    struct TurmTextAttributes: AttributeScope {
        let curlyUnderline: CurlyUnderlineKey
        let blink: BlinkKey
        let fontStyle: FontStyleKey
        let appKit: AttributeScopes.AppKitAttributes
    }

    var turmText: TurmTextAttributes.Type { TurmTextAttributes.self }
}

extension NSAttributedString.Key {
    static let curlyUnderline = NSAttributedString.Key(CurlyUnderlineKey.name)
    static let blink = NSAttributedString.Key(BlinkKey.name)
    static let fontStyle = NSAttributedString.Key(FontStyleKey.name)
}

enum TerminalFonts {
    private static let fonts: [NSFont] = (0..<4).map { index in
        let base = NSFont.monospacedSystemFont(ofSize: TerminalPalette.fontSize, weight: index & 1 != 0 ? .bold : .regular)
        guard index & 2 != 0 else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: TerminalPalette.fontSize) ?? base
    }

    static func font(for style: Int) -> NSFont {
        fonts[min(max(style, 0), 3)]
    }
}

extension NSAttributedString {
    static func terminalText(_ text: AttributedString) -> NSAttributedString {
        guard let converted = try? NSAttributedString(text, including: \.turmText) else {
            return NSAttributedString(string: String(text.characters))
        }
        let result = NSMutableAttributedString(attributedString: converted)
        let whole = NSRange(location: 0, length: result.length)
        result.beginEditing()
        result.enumerateAttribute(.fontStyle, in: whole) { value, range, _ in
            result.addAttribute(.font, value: TerminalFonts.font(for: (value as? NSNumber)?.intValue ?? 0), range: range)
        }
        result.removeAttribute(.fontStyle, range: whole)
        result.endEditing()
        return result
    }
}
