import Foundation

/// Reads the percentage from the latest line of a command's output, for tools that draw text progress instead of sending OSC 9;4.
struct OutputProgress {
    private enum Escape {
        case none
        case start
        case charset
        case csi
        case string
        case stringEscape
    }

    private static let lineLimit = 512

    private var line: [UInt8] = []
    private var lastLine: [UInt8] = []
    private var returned = false
    private var escape = Escape.none

    private(set) var percent: Double?

    mutating func feed(_ bytes: some Sequence<UInt8>) {
        for byte in bytes { consume(byte) }
        percent = Self.percent(in: line.isEmpty ? lastLine : line)
    }

    private mutating func consume(_ byte: UInt8) {
        switch escape {
        case .none:
            break
        case .start:
            switch byte {
            case 0x5B: escape = .csi
            case 0x5D, 0x50, 0x5F, 0x5E, 0x58: escape = .string
            case 0x28...0x2F: escape = .charset
            default: escape = .none
            }
            return
        case .charset:
            escape = .none
            return
        case .csi:
            guard (0x40...0x7E).contains(byte) else { return }
            escape = .none
            if byte == 0x47 { returned = true }
            return
        case .string:
            if byte == 0x07 { escape = .none } else if byte == 0x1B { escape = .stringEscape }
            return
        case .stringEscape:
            escape = byte == 0x5C ? .none : .string
            return
        }

        switch byte {
        case 0x1B:
            escape = .start
        case 0x0A:
            if !line.isEmpty { lastLine = line }
            line = []
            returned = false
        case 0x0D:
            returned = true
        case 0x00..<0x20, 0x7F:
            break
        default:
            if returned {
                line = []
                returned = false
            }
            line.append(byte)
            if line.count > Self.lineLimit { line.removeFirst(line.count - Self.lineLimit) }
        }
    }

    static func percent(in line: [UInt8]) -> Double? {
        var index = line.count - 1
        while index >= 0 {
            defer { index -= 1 }
            guard line[index] == 0x25 else { continue }
            var end = index
            if end > 0, line[end - 1] == 0x20 { end -= 1 }
            var start = end
            var dots = 0
            while start > 0 {
                let previous = line[start - 1]
                if isDigit(previous) {
                    start -= 1
                } else if previous == 0x2E, dots == 0 {
                    dots += 1
                    start -= 1
                } else {
                    break
                }
            }
            guard start < end, isDigit(line[start]), isDigit(line[end - 1]) else { continue }
            if start > 0, isLetter(line[start - 1]) { continue }
            let digits = line[start..<end]
            let whole = digits.prefix { $0 != 0x2E }
            guard whole.count <= 3,
                  let value = Double(String(decoding: digits, as: UTF8.self)),
                  (0...100).contains(value)
            else { continue }
            return value
        }
        return nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
    }
}

enum ShellActivity: Equatable {
    case inactive
    case working
    case progress(Double)
    case succeeded
    case failed

    var isBusy: Bool {
        switch self {
        case .working, .progress: true
        default: false
        }
    }

    static func combined(_ activities: [ShellActivity]) -> ShellActivity {
        let values = activities.compactMap { activity -> Double? in
            if case .progress(let value) = activity { return value }
            return nil
        }
        if let lowest = values.min() { return .progress(lowest) }
        if activities.contains(.working) { return .working }
        if activities.contains(.failed) { return .failed }
        if activities.contains(.succeeded) { return .succeeded }
        return .inactive
    }
}
