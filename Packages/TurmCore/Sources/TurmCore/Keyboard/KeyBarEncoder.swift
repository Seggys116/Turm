import Foundation

public nonisolated enum KeyBarEncoder {
    private static let escape: UInt8 = 0x1B
    private static let functionTildeCodes = [15, 17, 18, 19, 20, 21, 23, 24]

    public static func bytes(for kind: KeyKind, modifiers: KeyModifiers, applicationCursor: Bool, kittyFlags: Int = 0) -> [UInt8]? {
        switch kind {
        case .escape:
            return withAlt([escape], modifiers)
        case .tab:
            return withAlt([0x09], modifiers)
        case .newline:
            return NewlineEncoder.insertNewline(kittyFlags: kittyFlags)
        case .text(let value):
            return text(value, modifiers: modifiers)
        case .arrow(let arrow):
            return cursor(arrow.final, application: applicationCursor, modifiers: modifiers)
        case .navigation(let navigation):
            switch navigation {
            case .home: return cursor(0x48, application: applicationCursor, modifiers: modifiers)
            case .end: return cursor(0x46, application: applicationCursor, modifiers: modifiers)
            case .pageUp: return tilde(5, modifiers: modifiers)
            case .pageDown: return tilde(6, modifiers: modifiers)
            }
        case .function(let number):
            guard (1...12).contains(number) else { return nil }
            if number <= 4 {
                return cursor(UInt8(0x4F + number), application: true, modifiers: modifiers)
            }
            return tilde(functionTildeCodes[number - 5], modifiers: modifiers)
        case .control, .alt, .paste, .pad, .functionPage, .hideKeyboard:
            return nil
        }
    }

    public static func text(_ text: String, modifiers: KeyModifiers) -> [UInt8] {
        var bytes = Array(text.utf8)
        if modifiers.contains(.ctrl), let code = controlCode(for: text) {
            bytes = [code]
        }
        return withAlt(bytes, modifiers)
    }

    // Applies the sticky modifiers to a single typed character, or returns nil for anything longer.
    public static func modify(typed data: ArraySlice<UInt8>, modifiers: KeyModifiers) -> [UInt8]? {
        guard !modifiers.isEmpty, let typed = String(bytes: data, encoding: .utf8), typed.count == 1 else { return nil }
        return text(typed, modifiers: modifiers)
    }

    public static func controlCode(for text: String) -> UInt8? {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, scalar.value < 0x80 else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case 0x61...0x7A: return value - 0x60
        case 0x41...0x5A: return value - 0x40
        case 0x40, 0x20, 0x32: return 0x00
        case 0x5B, 0x33: return 0x1B
        case 0x5C, 0x34: return 0x1C
        case 0x5D, 0x35: return 0x1D
        case 0x5E, 0x36: return 0x1E
        case 0x5F, 0x2F, 0x37: return 0x1F
        case 0x3F, 0x38: return 0x7F
        default: return nil
        }
    }

    private static func withAlt(_ bytes: [UInt8], _ modifiers: KeyModifiers) -> [UInt8] {
        modifiers.contains(.alt) ? [escape] + bytes : bytes
    }

    private static func cursor(_ final: UInt8, application: Bool, modifiers: KeyModifiers) -> [UInt8] {
        if modifiers.isEmpty {
            return [escape, application ? 0x4F : 0x5B, final]
        }
        return [escape, 0x5B] + Array("1;\(modifiers.parameter)".utf8) + [final]
    }

    private static func tilde(_ code: Int, modifiers: KeyModifiers) -> [UInt8] {
        let parameters = modifiers.isEmpty ? "\(code)" : "\(code);\(modifiers.parameter)"
        return [escape, 0x5B] + Array(parameters.utf8) + [0x7E]
    }
}
