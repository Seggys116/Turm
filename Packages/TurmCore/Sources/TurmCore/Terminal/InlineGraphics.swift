import Foundation

/// Feature string from the terminals-wg / iTerm2 capability report.
/// `F` is both focus reporting and the inline-file protocol; the spec assigns them the same code.
public enum TerminalFeatures {
    public static let encoded = "T3CwMSc7UTs2BFGsSyHNoSxP"
}

public enum InlineGraphics {
    public enum Size: Equatable, Sendable {
        case auto
        case cells(Int)
        case pixels(Int)
        case percent(Int)
    }

    public struct Placement: Equatable, Sendable {
        public var data: Data
        public var width: Size
        public var height: Size
        public var preserveAspectRatio: Bool
    }

    public struct Cell: Equatable, Sendable {
        public var height: Double
        public var width: Double
        public var scale: Double

        public init(height: Double, width: Double, scale: Double) {
            self.height = height
            self.width = width
            self.scale = scale
        }
    }

    public enum Outcome: Equatable, Sendable {
        case reply([UInt8])
        case image(Placement)
    }
}

public enum OSC1337 {
    public enum Piece: Sendable {
        case bytes(ArraySlice<UInt8>)
        case command(ArraySlice<UInt8>)
    }

    /// Separates complete `OSC 1337` commands from the rest of a byte stream. An unfinished command stays in the trailing bytes so the terminal parser can keep holding it.
    public static func split(_ bytes: [UInt8]) -> [Piece] {
        var pieces: [Piece] = []
        var index = 0
        var plain = 0
        while index + 1 < bytes.count {
            guard bytes[index] == 0x1B, bytes[index + 1] == 0x5D, isMarker(bytes, at: index) else {
                index += 1
                continue
            }
            guard let end = terminator(bytes, from: index + 2) else { break }
            if plain < index { pieces.append(.bytes(bytes[plain..<index])) }
            let payloadStart = index + 2 + marker.count
            pieces.append(.command(bytes[payloadStart..<end.payloadEnd]))
            plain = end.sequenceEnd
            index = plain
        }
        if plain < bytes.count { pieces.append(.bytes(bytes[plain...])) }
        return pieces
    }

    private static let marker = Array("1337;".utf8)

    private static func isMarker(_ bytes: [UInt8], at index: Int) -> Bool {
        let start = index + 2
        guard start + marker.count <= bytes.count else { return false }
        return bytes[start..<(start + marker.count)].elementsEqual(marker)
    }

    private static func terminator(_ bytes: [UInt8], from index: Int) -> (payloadEnd: Int, sequenceEnd: Int)? {
        var cursor = index
        while cursor < bytes.count {
            if bytes[cursor] == 0x07 { return (cursor, cursor + 1) }
            if bytes[cursor] == 0x1B, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x5C {
                return (cursor, cursor + 2)
            }
            cursor += 1
        }
        return nil
    }
}

public enum SixelSequence {
    public enum Piece: Sendable {
        case bytes(ArraySlice<UInt8>)
        case image(ArraySlice<UInt8>)
    }

    /// Separates complete Sixel images (`DCS q`) from the surrounding text. An unfinished image stays in the trailing bytes.
    public static func split(_ bytes: [UInt8]) -> [Piece] {
        var pieces: [Piece] = []
        var index = 0
        var plain = 0
        while index + 1 < bytes.count {
            guard bytes[index] == 0x1B, bytes[index + 1] == 0x50, isSixel(bytes, at: index) else {
                index += 1
                continue
            }
            guard let end = terminator(bytes, from: index + 2) else { break }
            if plain < index { pieces.append(.bytes(bytes[plain..<index])) }
            pieces.append(.image(bytes[index..<end]))
            plain = end
            index = end
        }
        if plain < bytes.count { pieces.append(.bytes(bytes[plain...])) }
        return pieces
    }

    private static func isSixel(_ bytes: [UInt8], at index: Int) -> Bool {
        var cursor = index + 2
        while cursor < bytes.count, bytes[cursor] >= 0x20, bytes[cursor] <= 0x3F { cursor += 1 }
        return cursor < bytes.count && bytes[cursor] == 0x71
    }

    private static func terminator(_ bytes: [UInt8], from index: Int) -> Int? {
        var cursor = index
        while cursor + 1 < bytes.count {
            if bytes[cursor] == 0x1B, bytes[cursor + 1] == 0x5C { return cursor + 2 }
            cursor += 1
        }
        return nil
    }
}

/// Assembles iTerm2 / Ghostty OSC 1337 image transfers and answers the probes those terminals answer.
public struct InlineGraphicsSession: Sendable {
    private var transfer: Transfer?
    private static let byteLimit = TerminalGraphics.byteLimit

    public init() {}

    public mutating func receive(_ content: ArraySlice<UInt8>, cell: InlineGraphics.Cell) -> InlineGraphics.Outcome? {
        guard let text = String(bytes: content, encoding: .utf8), !text.isEmpty else { return nil }
        let key: String
        let value: String
        if let split = text.firstIndex(of: "=") {
            key = String(text[..<split])
            value = String(text[text.index(after: split)...])
        } else {
            key = text
            value = ""
        }
        switch key.lowercased() {
        case "reportcellsize":
            return .reply(Self.cellSize(cell))
        case "capabilities":
            return .reply(Self.capabilities)
        case "multipartfile":
            let fields = Self.fields(value)
            transfer = Transfer(inline: fields["inline"] == "1", width: Self.dimension(fields["width"]), height: Self.dimension(fields["height"]), preserveAspectRatio: fields["preserveAspectRatio"] != "0")
            return nil
        case "filepart":
            transfer?.append(value)
            return nil
        case "fileend":
            defer { transfer = nil }
            return transfer?.placement().map { .image($0) }
        case "file":
            return Self.file(value)
        default:
            return nil
        }
    }

    private static func file(_ value: String) -> InlineGraphics.Outcome? {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = fields(String(parts[0]))
        guard fields["inline"] == "1", parts.count == 2,
              let data = Data(base64Encoded: Data(parts[1].utf8), options: .ignoreUnknownCharacters),
              !data.isEmpty, data.count <= byteLimit
        else { return nil }
        return .image(InlineGraphics.Placement(
            data: data,
            width: dimension(fields["width"]),
            height: dimension(fields["height"]),
            preserveAspectRatio: fields["preserveAspectRatio"] != "0"
        ))
    }

    private static func fields(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard item.count == 2 else { continue }
            result[String(item[0])] = String(item[1])
        }
        return result
    }

    private static func dimension(_ value: String?) -> InlineGraphics.Size {
        guard let value, !value.isEmpty, value != "auto" else { return .auto }
        if value.hasSuffix("%"), let count = Int(value.dropLast()), count > 0, count <= 100 { return .percent(count) }
        if value.lowercased().hasSuffix("px"), let count = Int(value.dropLast(2)), count > 0, count < 4096 {
            return .pixels(count)
        }
        if let count = Int(value), count > 0, count < 200 { return .cells(count) }
        return .auto
    }

    private static func cellSize(_ cell: InlineGraphics.Cell) -> [UInt8] {
        let height = String(format: "%.2f", cell.height)
        let width = String(format: "%.2f", cell.width)
        let scale = String(format: "%.1f", cell.scale)
        return Array("\u{1B}]1337;ReportCellSize=\(height);\(width);\(scale)\u{1B}\\".utf8)
    }

    private static var capabilities: [UInt8] {
        Array("\u{1B}]1337;Capabilities=\(TerminalFeatures.encoded)\u{1B}\\".utf8)
    }

    private struct Transfer {
        var inline: Bool
        var width: InlineGraphics.Size
        var height: InlineGraphics.Size
        var preserveAspectRatio: Bool
        var encoded = ""

        mutating func append(_ chunk: String) {
            guard encoded.utf8.count + chunk.utf8.count <= byteLimit else {
                inline = false
                encoded = ""
                return
            }
            encoded += chunk
        }

        func placement() -> InlineGraphics.Placement? {
            guard inline, let data = Data(base64Encoded: Data(encoded.utf8), options: .ignoreUnknownCharacters), !data.isEmpty else {
                return nil
            }
            return InlineGraphics.Placement(data: data, width: width, height: height, preserveAspectRatio: preserveAspectRatio)
        }
    }
}

/// Pulls iTerm2 images and Sixel images out of a terminal byte stream.
///
/// An image usually arrives across several reads. `remainder` is the unfinished tail, and the
/// caller has to keep it until the sequence ends. Handing that tail to the terminal parser early
/// draws whatever text shared the completing read onto the image's rows: the cursor cannot move
/// down until the image's size is known, and by then the text has already been painted.
public enum TerminalGraphics {
    public static let byteLimit = 64 * 1024 * 1024

    public enum Piece: Sendable, Equatable {
        case bytes(ArraySlice<UInt8>)
        case osc(ArraySlice<UInt8>)
        case sixel(ArraySlice<UInt8>)
    }

    public static func split(_ bytes: [UInt8]) -> (pieces: [Piece], remainder: ArraySlice<UInt8>) {
        var pieces: [Piece] = []
        var index = 0
        var plain = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                index += 1
                continue
            }
            switch classify(bytes, at: index) {
            case .text:
                index += 1
            case .incomplete:
                if plain < index { pieces.append(.bytes(bytes[plain..<index])) }
                return (pieces, bytes[index...])
            case .osc(let payloadEnd, let sequenceEnd):
                if plain < index { pieces.append(.bytes(bytes[plain..<index])) }
                let payloadStart = index + 2 + marker.count
                pieces.append(.osc(bytes[payloadStart..<payloadEnd]))
                plain = sequenceEnd
                index = sequenceEnd
            case .sixel(let sequenceEnd):
                if plain < index { pieces.append(.bytes(bytes[plain..<index])) }
                pieces.append(.sixel(bytes[index..<sequenceEnd]))
                plain = sequenceEnd
                index = sequenceEnd
            }
        }
        if plain < bytes.count { pieces.append(.bytes(bytes[plain...])) }
        return (pieces, bytes[bytes.count...])
    }

    private enum Mark {
        case text
        case incomplete
        case osc(payloadEnd: Int, sequenceEnd: Int)
        case sixel(sequenceEnd: Int)
    }

    private static let marker = Array("1337;".utf8)

    private static func classify(_ bytes: [UInt8], at index: Int) -> Mark {
        guard index + 1 < bytes.count else { return .incomplete }
        switch bytes[index + 1] {
        case 0x5D:
            return osc(bytes, at: index)
        case 0x50:
            return sixel(bytes, at: index)
        default:
            return .text
        }
    }

    private static func osc(_ bytes: [UInt8], at index: Int) -> Mark {
        let start = index + 2
        let available = bytes.count - start
        if available < marker.count {
            return bytes[start...].elementsEqual(marker.prefix(available)) ? .incomplete : .text
        }
        guard bytes[start..<(start + marker.count)].elementsEqual(marker) else { return .text }
        guard let end = terminator(bytes, from: start + marker.count, allowBell: true) else { return .incomplete }
        return .osc(payloadEnd: end.payloadEnd, sequenceEnd: end.sequenceEnd)
    }

    private static func sixel(_ bytes: [UInt8], at index: Int) -> Mark {
        var cursor = index + 2
        while cursor < bytes.count, bytes[cursor] >= 0x20, bytes[cursor] <= 0x3F { cursor += 1 }
        guard cursor < bytes.count else { return .incomplete }
        guard bytes[cursor] == 0x71 else { return .text }
        guard let end = terminator(bytes, from: cursor + 1, allowBell: false) else { return .incomplete }
        return .sixel(sequenceEnd: end.sequenceEnd)
    }

    private static func terminator(_ bytes: [UInt8], from index: Int, allowBell: Bool) -> (payloadEnd: Int, sequenceEnd: Int)? {
        var cursor = index
        while cursor < bytes.count {
            if allowBell, bytes[cursor] == 0x07 { return (cursor, cursor + 1) }
            if bytes[cursor] == 0x1B, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x5C {
                return (cursor, cursor + 2)
            }
            if bytes[cursor] == 0x1B, cursor + 1 == bytes.count { return nil }
            cursor += 1
        }
        return nil
    }
}

/// Remembers an image sequence that was cut off at the end of a read.
///
/// Once a partial image grows past `TerminalGraphics.byteLimit` it is dropped instead of parsed.
/// SwiftTerm keeps its own unlimited buffer for a sequence it has already been given, so the hold
/// has to refuse the bytes before they ever reach the terminal.
public struct GraphicHold: Sendable {
    private var pending: [UInt8] = []
    private var discarding = false

    public init() {}

    public mutating func intake(_ incoming: [UInt8]) -> [UInt8]? {
        if discarding {
            guard let end = Self.sequenceEnd(incoming, from: 0) else { return nil }
            discarding = false
            return intake(Array(incoming[end...]))
        }
        var combined = pending
        pending = []
        combined.append(contentsOf: incoming)
        return combined
    }

    public mutating func hold(_ suffix: ArraySlice<UInt8>) {
        guard !suffix.isEmpty else {
            pending = []
            return
        }
        if suffix.count > TerminalGraphics.byteLimit {
            discarding = true
            pending = []
            return
        }
        pending = Array(suffix)
    }

    private static func sequenceEnd(_ bytes: [UInt8], from index: Int) -> Int? {
        var cursor = index
        while cursor < bytes.count {
            if bytes[cursor] == 0x07 { return cursor + 1 }
            if bytes[cursor] == 0x1B, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x5C {
                return cursor + 2
            }
            cursor += 1
        }
        return nil
    }
}
