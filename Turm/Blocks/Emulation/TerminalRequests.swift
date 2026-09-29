import Foundation

enum TerminalRequest: Equatable {
    case privateMode(Int, enabled: Bool)
    case colorSchemeQuery
    case capabilities([String])
}

enum TerminalRequestScanner {
    private static let esc: UInt8 = 0x1B

    static func scan(_ bytes: ArraySlice<UInt8>) -> [TerminalRequest] {
        var requests: [TerminalRequest] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == esc, index + 1 < bytes.endIndex else {
                index += 1
                continue
            }
            switch bytes[index + 1] {
            case 0x5B:
                index = scanCSI(bytes, from: index + 2, into: &requests)
            case 0x50:
                index = scanDCS(bytes, from: index + 2, into: &requests)
            default:
                index += 1
            }
        }
        return requests
    }

    private static func scanCSI(_ bytes: ArraySlice<UInt8>, from start: Int, into requests: inout [TerminalRequest]) -> Int {
        guard start < bytes.endIndex, bytes[start] == 0x3F else { return start }
        var end = start + 1
        while end < bytes.endIndex, bytes[end] < 0x40 { end += 1 }
        guard end < bytes.endIndex else { return end }
        let params = bytes[(start + 1)..<end].split(separator: 0x3B).compactMap {
            Int(String(decoding: $0, as: UTF8.self))
        }
        switch bytes[end] {
        case 0x68, 0x6C:
            for param in params {
                requests.append(.privateMode(param, enabled: bytes[end] == 0x68))
            }
        case 0x6E where params == [996]:
            requests.append(.colorSchemeQuery)
        default:
            break
        }
        return end + 1
    }

    private static func scanDCS(_ bytes: ArraySlice<UInt8>, from start: Int, into requests: inout [TerminalRequest]) -> Int {
        guard start + 1 < bytes.endIndex, bytes[start] == 0x2B, bytes[start + 1] == 0x71 else { return start }
        var end = start + 2
        while end < bytes.endIndex, bytes[end] != esc, bytes[end] != 0x07 { end += 1 }
        guard end < bytes.endIndex else { return end }
        let names = bytes[(start + 2)..<end].split(separator: 0x3B).compactMap { hex -> String? in
            decodeHex(hex)
        }
        requests.append(.capabilities(names))
        return end + 1
    }

    private static func decodeHex(_ hex: ArraySlice<UInt8>) -> String? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let value = UInt8(String(decoding: hex[index..<(index + 2)], as: UTF8.self), radix: 16) else { return nil }
            result.append(value)
            index += 2
        }
        return String(bytes: result, encoding: .utf8)
    }
}

enum TerminalReply {
    private static let capabilities: [String: String?] = [
        "TN": "xterm-256color",
        "Co": "256",
        "colors": "256",
        "RGB": "8/8/8",
        "Tc": nil,
    ]

    static func colorScheme(dark: Bool) -> [UInt8] {
        Array("\u{1B}[?997;\(dark ? 1 : 2)n".utf8)
    }

    static func capability(_ name: String) -> [UInt8] {
        guard let entry = capabilities[name] else {
            return Array("\u{1B}P0+r\u{1B}\\".utf8)
        }
        var text = "\u{1B}P1+r\(hex(name))"
        if let value = entry { text += "=\(hex(value))" }
        text += "\u{1B}\\"
        return Array(text.utf8)
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02X", $0) }.joined()
    }
}
