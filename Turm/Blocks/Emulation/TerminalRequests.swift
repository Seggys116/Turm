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

    /// `CSI 48 ; rows ; columns ; height_px ; width_px t`
    static func inBandResize(rows: Int, columns: Int, height: Int, width: Int) -> [UInt8] {
        Array("\u{1B}[48;\(rows);\(columns);\(height);\(width)t".utf8)
    }

    static func inBandResizeMode(enabled: Bool) -> [UInt8] {
        Array("\u{1B}[?2048;\(enabled ? 1 : 2)$y".utf8)
    }

    static func pointerShape(_ body: String) -> [UInt8] {
        var bytes: [UInt8] = [0x1B, 0x5D]
        bytes.append(contentsOf: "22;\(body)".utf8)
        bytes.append(contentsOf: [0x1B, 0x5C])
        return bytes
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

enum TerminalGrid {
    static func cell(width: Double, height: Double, scale: Double) -> (width: Int, height: Int) {
        (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    static func pixels(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) -> (width: Int, height: Int) {
        (fitting(columns, cellWidth), fitting(rows, cellHeight))
    }

    private static func fitting(_ count: Int, _ cell: Int) -> Int {
        guard count > 0, cell > 0 else { return 0 }
        let (product, overflow) = count.multipliedReportingOverflow(by: cell)
        if overflow || product > Int(UInt16.max) { return Int(UInt16.max) }
        return product
    }
}

enum PointerCommand: Equatable {
    case set(String)
    case push([String])
    case pop
    case query([String])
}

struct PointerStack: Equatable {
    static let capacity = 16
    static let names: Set<String> = [
        "alias", "cell", "copy", "crosshair", "default",
        "e-resize", "ew-resize", "grab", "grabbing", "help",
        "move", "n-resize", "ne-resize", "nesw-resize", "no-drop",
        "not-allowed", "ns-resize", "nw-resize", "nwse-resize", "pointer",
        "progress", "s-resize", "se-resize", "sw-resize", "text",
        "vertical-text", "w-resize", "wait", "zoom-in", "zoom-out",
    ]

    var isAlternate = false
    private var main: [String] = []
    private var alternate: [String] = []

    var current: String? { active.last }

    mutating func set(_ name: String) {
        guard Self.names.contains(name) else { return }
        var names = active
        if names.isEmpty { names = [name] }
        else { names[names.count - 1] = name }
        active = names
    }

    mutating func clear() { active = [] }

    mutating func push(_ names: [String]) {
        let known = names.filter { Self.names.contains($0) }
        guard !known.isEmpty else { return }
        var stack = active
        stack.append(contentsOf: known)
        if stack.count > Self.capacity { stack.removeFirst(stack.count - Self.capacity) }
        active = stack
    }

    mutating func pop() {
        guard !active.isEmpty else { return }
        var stack = active
        stack.removeLast()
        active = stack
    }

    mutating func resetAll() {
        main = []
        alternate = []
    }

    func answer(_ names: [String]) -> String {
        if names.count == 1, let name = names.first, let special = specialAnswer(name) { return special }
        return names.map { name in
            if let special = specialAnswer(name) { return special }
            return Self.names.contains(name) ? "1" : "0"
        }.joined(separator: ",")
    }

    private func specialAnswer(_ name: String) -> String? {
        switch name {
        case "__current__": return current ?? "0"
        case "__default__", "__grabbed__": return "default"
        default: return nil
        }
    }

    private var active: [String] {
        get { isAlternate ? alternate : main }
        set {
            if isAlternate { alternate = newValue }
            else { main = newValue }
        }
    }
}

enum TerminalControlFilter {
    struct Control: Equatable {
        var at: Int
        var kind: Kind

        enum Kind: Equatable {
            case inBandResize(Bool)
            case inBandResizeQuery
            case pointer(PointerCommand)
            case reset
        }
    }

    struct Extraction: Equatable {
        var bytes: [UInt8] = []
        var held: [UInt8] = []
        var controls: [Control] = []
    }

    private static let holdLimit = 256

    static func extract(_ bytes: [UInt8]) -> Extraction {
        var result = Extraction()
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                result.bytes.append(bytes[index])
                index += 1
                continue
            }
            if index + 1 == bytes.count {
                return hold(bytes, from: index, into: &result)
            }
            switch bytes[index + 1] {
            case 0x63:
                result.bytes.append(contentsOf: [0x1B, 0x63])
                result.controls.append(Control(at: result.bytes.count, kind: .reset))
                index += 2
            case 0x5B:
                guard let end = sequenceEnd(bytes, from: index + 2) else {
                    return hold(bytes, from: index, into: &result)
                }
                consumeCSI(bytes[index..<end], into: &result)
                index = end
            case 0x5D:
                if let end = oscEnd(bytes, from: index + 2) {
                    let sequence = bytes[index..<end]
                    if let command = pointerCommand(sequence) {
                        result.controls.append(Control(at: result.bytes.count, kind: .pointer(command)))
                    } else {
                        result.bytes.append(contentsOf: sequence)
                    }
                    index = end
                } else if shouldHoldOSC(bytes, from: index) {
                    return hold(bytes, from: index, into: &result)
                } else {
                    result.bytes.append(bytes[index])
                    index += 1
                }
            default:
                result.bytes.append(bytes[index])
                index += 1
            }
        }
        return result
    }

    private static func hold(_ bytes: [UInt8], from index: Int, into result: inout Extraction) -> Extraction {
        if bytes.count - index > holdLimit {
            result.bytes.append(contentsOf: bytes[index...])
            return result
        }
        result.held = Array(bytes[index...])
        return result
    }

    private static func sequenceEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] >= 0x40 { return index + 1 }
            index += 1
        }
        return nil
    }

    private static func oscEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x07 { return index + 1 }
            if bytes[index] == 0x1B {
                guard index + 1 < bytes.count else { return nil }
                if bytes[index + 1] == 0x5C { return index + 2 }
            }
            index += 1
        }
        return nil
    }

    private static func shouldHoldOSC(_ bytes: [UInt8], from index: Int) -> Bool {
        guard bytes.count - index <= holdLimit else { return false }
        var cursor = index + 2
        var code = 0
        var digits = 0
        while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            code = code * 10 + Int(bytes[cursor] - 0x30)
            digits += 1
            cursor += 1
            if digits > 4 { return false }
        }
        if cursor >= bytes.count {
            if digits == 0 { return true }
            return "22".hasPrefix(String(code))
        }
        return code == 22
    }

    private struct CSI {
        var privateMode: Bool
        var numbers: [Int]
        var intermediates: [UInt8]
        var final: UInt8
    }

    private static func consumeCSI(_ sequence: ArraySlice<UInt8>, into result: inout Extraction) {
        guard let parsed = parseCSI(sequence) else {
            result.bytes.append(contentsOf: sequence)
            return
        }
        if !parsed.privateMode, parsed.numbers.isEmpty, parsed.intermediates == [0x21], parsed.final == 0x70 {
            result.bytes.append(contentsOf: sequence)
            result.controls.append(Control(at: result.bytes.count, kind: .reset))
            return
        }
        let queries = parsed.privateMode && parsed.intermediates == [0x24] && parsed.final == 0x70 && parsed.numbers == [2048]
        if queries {
            result.controls.append(Control(at: result.bytes.count, kind: .inBandResizeQuery))
            return
        }
        let sets = parsed.privateMode && parsed.intermediates.isEmpty
            && (parsed.final == 0x68 || parsed.final == 0x6C) && parsed.numbers.contains(2048)
        guard sets else {
            result.bytes.append(contentsOf: sequence)
            return
        }
        let kept = parsed.numbers.filter { $0 != 2048 }
        if !kept.isEmpty {
            result.bytes.append(contentsOf: [0x1B, 0x5B, 0x3F])
            result.bytes.append(contentsOf: kept.map(String.init).joined(separator: ";").utf8)
            result.bytes.append(parsed.final)
        }
        result.controls.append(Control(at: result.bytes.count, kind: .inBandResize(parsed.final == 0x68)))
    }

    private static func parseCSI(_ sequence: ArraySlice<UInt8>) -> CSI? {
        let start = sequence.startIndex
        guard sequence.count >= 3, sequence[start] == 0x1B, sequence[start + 1] == 0x5B else { return nil }
        var index = start + 2
        let end = sequence.endIndex
        let privateMode = index < end && sequence[index] == 0x3F
        if privateMode { index += 1 }
        var numbers: [Int] = []
        var value = 0
        var digits = false
        var intermediates: [UInt8] = []
        while index < end {
            let byte = sequence[index]
            if byte >= 0x40 {
                if digits { numbers.append(value) }
                return CSI(privateMode: privateMode, numbers: numbers, intermediates: intermediates, final: byte)
            }
            if byte == 0x3B {
                numbers.append(digits ? value : 0)
                value = 0
                digits = false
            } else if byte >= 0x30, byte <= 0x39 {
                digits = true
                if value < 1_000_000 { value = value * 10 + Int(byte - 0x30) }
            } else if (0x20...0x2F).contains(byte) {
                if digits {
                    numbers.append(value)
                    value = 0
                    digits = false
                }
                intermediates.append(byte)
            }
            index += 1
        }
        return nil
    }

    private static func pointerCommand(_ sequence: ArraySlice<UInt8>) -> PointerCommand? {
        let start = sequence.startIndex
        guard sequence.count >= 4, sequence[start] == 0x1B, sequence[start + 1] == 0x5D else { return nil }
        var index = start + 2
        let end = sequence.endIndex
        var code = 0
        var digits = 0
        while index < end, sequence[index] >= 0x30, sequence[index] <= 0x39 {
            code = code * 10 + Int(sequence[index] - 0x30)
            digits += 1
            index += 1
            if digits > 4 { return nil }
        }
        guard code == 22, digits > 0 else { return nil }
        if index < end, sequence[index] == 0x3B { index += 1 }
        var payloadEnd = index
        while payloadEnd < end, sequence[payloadEnd] != 0x07, sequence[payloadEnd] != 0x1B {
            payloadEnd += 1
        }
        return command(for: String(decoding: sequence[index..<payloadEnd], as: UTF8.self))
    }

    private static func command(for payload: String) -> PointerCommand {
        guard let first = payload.first else { return .set("") }
        let rest = String(payload.dropFirst())
        switch first {
        case ">": return .push(names(in: rest))
        case "<": return .pop
        case "?": return .query(names(in: rest))
        case "=": return .set(rest)
        default: return .set(payload)
        }
    }

    private static func names(in text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
    }
}
