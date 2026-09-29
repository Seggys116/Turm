import Foundation

enum KeyEventType: Int {
    case press = 1
    case repeated = 2
    case release = 3
}

struct KeyInput {
    var keyCode: UInt16
    var characters: String
    var unmodified: String
    var shift = false
    var control = false
    var option = false
    var command = false
    var capsLock = false
    var numLock = false
    var event = KeyEventType.press
    var shifted: String?
    var base: String?

    var modifierBits: Int {
        (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0) + (command ? 8 : 0)
    }

    var lockBits: Int {
        (capsLock ? 64 : 0) + (numLock ? 128 : 0)
    }

    var modifierParameter: Int { 1 + modifierBits }
}

struct KeyModes: Equatable {
    var applicationCursor = false
    var kittyFlags = 0

    var disambiguate: Bool { kittyFlags & 1 != 0 }
    var reportEvents: Bool { kittyFlags & 2 != 0 }
    var reportAlternates: Bool { kittyFlags & 4 != 0 }
    var reportAllKeys: Bool { kittyFlags & 8 != 0 }
    var reportText: Bool { kittyFlags & 16 != 0 }
    var escapeMode: Bool { kittyFlags & 9 != 0 }
}

enum KeyEncoder {
    private static let escape: UInt8 = 0x1B

    private enum Functional {
        case cursor(Character)
        case function(Character, Int)
        case tilde(Int)
        case extended(Int, legacy: Int?)
        case lockOrModifier(Int)
        case c0(legacy: Int, csi: Int)
        case keypad(Int)
    }

    private struct Encoded {
        var bytes: [UInt8]
        var escaped: Bool
    }

    private static func functional(for keyCode: UInt16) -> Functional? {
        switch keyCode {
        case 126: return .cursor("A")
        case 125: return .cursor("B")
        case 124: return .cursor("C")
        case 123: return .cursor("D")
        case 115: return .cursor("H")
        case 119: return .cursor("F")
        case 114: return .tilde(2)
        case 117: return .tilde(3)
        case 116: return .tilde(5)
        case 121: return .tilde(6)
        case 122: return .function("P", 11)
        case 120: return .function("Q", 12)
        case 99: return .function("R", 13)
        case 118: return .function("S", 14)
        case 96: return .tilde(15)
        case 97: return .tilde(17)
        case 98: return .tilde(18)
        case 100: return .tilde(19)
        case 101: return .tilde(20)
        case 109: return .tilde(21)
        case 103: return .tilde(23)
        case 111: return .tilde(24)
        case 105: return .extended(57376, legacy: 25)
        case 107: return .extended(57377, legacy: 26)
        case 113: return .extended(57378, legacy: 28)
        case 106: return .extended(57379, legacy: 29)
        case 64: return .extended(57380, legacy: 31)
        case 79: return .extended(57381, legacy: 32)
        case 80: return .extended(57382, legacy: 33)
        case 90: return .extended(57383, legacy: 34)
        case 110: return .extended(57363, legacy: 29)
        case 71: return .lockOrModifier(57360)
        case 57: return .lockOrModifier(57358)
        case 56: return .lockOrModifier(57441)
        case 59: return .lockOrModifier(57442)
        case 58: return .lockOrModifier(57443)
        case 55: return .lockOrModifier(57444)
        case 60: return .lockOrModifier(57447)
        case 62: return .lockOrModifier(57448)
        case 61: return .lockOrModifier(57449)
        case 54: return .lockOrModifier(57450)
        case 36: return .c0(legacy: 13, csi: 13)
        case 76: return .c0(legacy: 13, csi: 57414)
        case 51: return .c0(legacy: 127, csi: 127)
        case 48: return .c0(legacy: 9, csi: 9)
        case 53: return .c0(legacy: 27, csi: 27)
        case 82: return .keypad(57399)
        case 83: return .keypad(57400)
        case 84: return .keypad(57401)
        case 85: return .keypad(57402)
        case 86: return .keypad(57403)
        case 87: return .keypad(57404)
        case 88: return .keypad(57405)
        case 89: return .keypad(57406)
        case 91: return .keypad(57407)
        case 92: return .keypad(57408)
        case 65: return .keypad(57409)
        case 75: return .keypad(57410)
        case 67: return .keypad(57411)
        case 78: return .keypad(57412)
        case 69: return .keypad(57413)
        case 81: return .keypad(57415)
        case 95: return .keypad(57416)
        default: return nil
        }
    }

    private static let baseLayout: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 49: " ", 50: "`"
    ]

    static func encode(_ key: KeyInput, modes: KeyModes) -> [UInt8]? {
        var key = key
        if !modes.reportEvents {
            if key.event == .release { return nil }
            key.event = .press
        }
        guard let encoded = build(key, modes: modes) else { return nil }
        if key.event == .release && !encoded.escaped { return nil }
        return encoded.bytes
    }

    private static func build(_ key: KeyInput, modes: KeyModes) -> Encoded? {
        let locks = modes.kittyFlags != 0 ? key.lockBits : 0
        let field = modifierField(1 + key.modifierBits + locks, key.event)
        switch functional(for: key.keyCode) {
        case .cursor(let letter):
            if field.isEmpty {
                return legacy(modes.applicationCursor ? "\u{1B}O\(letter)" : "\u{1B}[\(letter)")
            }
            return escaped("\u{1B}[1;\(field)\(letter)")
        case .function(let letter, let number):
            let tildeForm = modes.kittyFlags != 0 && number == 13
            if field.isEmpty {
                if !modes.escapeMode { return legacy("\u{1B}O\(letter)") }
                return escaped(tildeForm ? "\u{1B}[13~" : "\u{1B}[\(letter)")
            }
            return escaped(tildeForm ? "\u{1B}[13;\(field)~" : "\u{1B}[1;\(field)\(letter)")
        case .tilde(let number):
            return tilde(number, field: field)
        case .extended(let code, let legacyNumber):
            if modes.escapeMode { return csiU("\(code)", field: field) }
            guard let legacyNumber else { return nil }
            return tilde(legacyNumber, field: field)
        case .lockOrModifier(let code):
            guard modes.reportAllKeys else { return nil }
            return csiU("\(code)", field: field)
        case .c0(let legacyCode, let csiCode):
            let needsEscape = modes.reportAllKeys
                || (modes.disambiguate && (legacyCode == 27 || key.modifierBits != 0))
            if needsEscape { return csiU("\(csiCode)", field: field) }
            return Encoded(bytes: legacyC0(legacyCode, key), escaped: false)
        case .keypad(let code):
            return encodeText(key, modes: modes, field: field, keypadCode: code)
        case nil:
            return encodeText(key, modes: modes, field: field, keypadCode: nil)
        }
    }

    private static func legacyC0(_ code: Int, _ key: KeyInput) -> [UInt8] {
        var result: [UInt8]
        switch code {
        case 13: result = [0x0D]
        case 9: result = key.shift ? [escape, 0x5B, 0x5A] : [0x09]
        case 127: result = [key.control ? 0x08 : 0x7F]
        default: result = [escape]
        }
        if key.option { result.insert(escape, at: 0) }
        return result
    }

    private static func encodeText(_ key: KeyInput, modes: KeyModes, field: String, keypadCode: Int?) -> Encoded? {
        guard !key.characters.isEmpty else { return nil }
        let nonShift = key.control || key.option || key.command
        let scalar = key.unmodified.unicodeScalars.first ?? key.characters.unicodeScalars.first
        if let scalar, modes.reportAllKeys || (modes.disambiguate && nonShift) {
            let code = keypadCode ?? Int(lowered(scalar))
            var head = "\(code)"
            if keypadCode == nil, modes.reportAlternates { head += alternates(key, code: code) }
            return csiU(head, field: field, text: associatedText(key, modes: modes, nonShift: nonShift))
        }
        let prefix: [UInt8] = key.option ? [escape] : []
        if key.control, key.unmodified == " " {
            return Encoded(bytes: prefix + [0], escaped: false)
        }
        if key.option, !key.control {
            let plain = key.shift ? (key.shifted ?? key.unmodified.uppercased()) : key.unmodified
            if plain.utf8.count == 1 { return Encoded(bytes: prefix + Array(plain.utf8), escaped: false) }
        }
        return Encoded(bytes: Array(key.characters.utf8), escaped: false)
    }

    private static func lowered(_ scalar: Unicode.Scalar) -> UInt32 {
        String(scalar).lowercased().unicodeScalars.first?.value ?? scalar.value
    }

    private static func alternates(_ key: KeyInput, code: Int) -> String {
        var shifted: Int?
        if key.shift {
            let scalar = key.shifted?.unicodeScalars.first ?? key.unmodified.uppercased().unicodeScalars.first
            shifted = scalar.map { Int($0.value) }
        }
        if shifted == code { shifted = nil }
        var base = key.base?.unicodeScalars.first ?? baseLayout[key.keyCode]?.unicodeScalars.first
        if let value = base, Int(lowered(value)) == code { base = nil }
        guard shifted != nil || base != nil else { return "" }
        var result = ":" + (shifted.map(String.init) ?? "")
        if let base { result += ":\(lowered(base))" }
        return result
    }

    private static func associatedText(_ key: KeyInput, modes: KeyModes, nonShift: Bool) -> String {
        guard modes.reportText, modes.reportAllKeys, key.event != .release, !nonShift else { return "" }
        let scalars = key.characters.unicodeScalars
        let printable = scalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }
        guard printable else { return "" }
        return scalars.map { String($0.value) }.joined(separator: ":")
    }

    private static func modifierField(_ parameter: Int, _ event: KeyEventType) -> String {
        let type = event == .press ? "" : ":\(event.rawValue)"
        return parameter == 1 && type.isEmpty ? "" : "\(parameter)\(type)"
    }

    private static func tilde(_ number: Int, field: String) -> Encoded {
        escaped(field.isEmpty ? "\u{1B}[\(number)~" : "\u{1B}[\(number);\(field)~")
    }

    private static func csiU(_ head: String, field: String, text: String = "") -> Encoded {
        var body = head
        if !text.isEmpty {
            body += ";\(field);\(text)"
        } else if !field.isEmpty {
            body += ";\(field)"
        }
        return escaped("\u{1B}[\(body)u")
    }

    private static func legacy(_ text: String) -> Encoded {
        Encoded(bytes: Array(text.utf8), escaped: false)
    }

    private static func escaped(_ text: String) -> Encoded {
        Encoded(bytes: Array(text.utf8), escaped: true)
    }
}
