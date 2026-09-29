import Foundation

struct KittyCommand: Equatable {
    var action: Character?
    var imageID: UInt32?
    var imageNumber: UInt32?
    var placementID: UInt32?
    var columns: Int?
    var rows: Int?
    var more = false
    var deleteTarget: Character?
    var zIndex = 0
    var cursorPolicy = 0
    var pixelX = 0
    var pixelY = 0
    var parentImage: UInt32?
    var parentPlacement: UInt32?
    var parentColumns = 0
    var parentRows = 0
    var x: Int?
    var y: Int?
    var quiet = 0
    var virtual = false
    var medium: Character?
    var resolvedID: UInt32?
    var format: Int?
    var compression: Character?
    var dataSize = 0
    var dataOffset = 0
    var hints = 0
    var stateValue: Int?
    var loopValue: Int?
    var cropWidth = 0
    var cropHeight = 0

    var isCropped: Bool {
        cropWidth != 0 || cropHeight != 0 || (x ?? 0) != 0 || (y ?? 0) != 0
    }

    var displays: Bool {
        action == "T" || action == "p"
    }

    var transmits: Bool {
        action == "T" || action == "t"
    }

    var isRelative: Bool {
        (parentImage != nil || parentPlacement != nil) && !virtual
    }

    var deletesAll: Bool {
        action == "d" && (deleteTarget == nil || deleteTarget == "a" || deleteTarget == "A")
    }

    var deletesByID: Bool {
        action == "d" && (deleteTarget == "i" || deleteTarget == "I") && imageID != nil
    }
}

enum KittyGraphicsScanner {
    enum ClearScope {
        case visible
        case everything
        case reset
        case scrollback
    }

    enum Kind {
        case text
        case graphics(KittyCommand)
        case clear(ClearScope)
    }

    struct Piece {
        let bytes: ArraySlice<UInt8>
        let kind: Kind

        var command: KittyCommand? {
            if case .graphics(let command) = kind { return command }
            return nil
        }
    }

    private static let escape: UInt8 = 0x1B

    static func split(_ bytes: [UInt8]) -> (pieces: [Piece], remainder: ArraySlice<UInt8>) {
        var pieces: [Piece] = []
        var start = 0
        var index = 0
        let count = bytes.count
        while index < count {
            guard bytes[index] == escape else {
                index += 1
                continue
            }
            guard index + 1 < count else { return finish(bytes, pieces, start, index) }
            switch bytes[index + 1] {
            case 0x5F:
                guard index + 2 < count else { return finish(bytes, pieces, start, index) }
                guard bytes[index + 2] == 0x47 else {
                    index += 2
                    continue
                }
                guard let end = terminator(in: bytes, from: index + 3) else {
                    return finish(bytes, pieces, start, index)
                }
                if start < index { pieces.append(Piece(bytes: bytes[start..<index], kind: .text)) }
                let body = bytes[(index + 3)..<end]
                let control = body.firstIndex(of: 0x3B).map { body[..<$0] } ?? body
                pieces.append(Piece(bytes: bytes[index..<(end + 2)], kind: .graphics(parse(control))))
                start = end + 2
                index = start
            case 0x5B:
                if index + 4 < count, bytes[index + 2] == 0x32, bytes[index + 3] == 0x32, bytes[index + 4] == 0x4A {
                    pieces.append(Piece(bytes: bytes[start..<index], kind: .clear(.scrollback)))
                    start = index + 5
                    index = start
                } else if index + 3 < count, bytes[index + 3] == 0x4A, bytes[index + 2] == 0x32 || bytes[index + 2] == 0x33 {
                    let scope: ClearScope = bytes[index + 2] == 0x32 ? .visible : .everything
                    pieces.append(Piece(bytes: bytes[start..<(index + 4)], kind: .clear(scope)))
                    start = index + 4
                    index = start
                } else {
                    index += 2
                }
            case 0x63:
                pieces.append(Piece(bytes: bytes[start..<(index + 2)], kind: .clear(.reset)))
                start = index + 2
                index = start
            default:
                index += 1
            }
        }
        if start < count { pieces.append(Piece(bytes: bytes[start...], kind: .text)) }
        return (pieces, bytes[count...])
    }

    private static func finish(
        _ bytes: [UInt8], _ pieces: [Piece], _ start: Int, _ index: Int
    ) -> (pieces: [Piece], remainder: ArraySlice<UInt8>) {
        var pieces = pieces
        if start < index { pieces.append(Piece(bytes: bytes[start..<index], kind: .text)) }
        return (pieces, bytes[index...])
    }

    static func payload(of apc: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let bytes = Array(apc)
        guard bytes.count >= 5, let separator = bytes[3..<(bytes.count - 2)].firstIndex(of: 0x3B) else { return [] }
        return bytes[(separator + 1)..<(bytes.count - 2)]
    }

    static func replacingPayload(_ apc: [UInt8], with payload: [UInt8]) -> [UInt8] {
        guard apc.count >= 5 else { return apc }
        let closing = apc.count - 2
        let end = apc[3..<closing].firstIndex(of: 0x3B) ?? closing
        var result = Array(apc[0..<end])
        if !payload.isEmpty { result.append(0x3B) }
        result.append(contentsOf: payload)
        result.append(contentsOf: apc[closing...])
        return result
    }

    static func terminator(in bytes: [UInt8], from: Int) -> Int? {
        var end = max(from, 0)
        while end + 1 < bytes.count {
            if bytes[end] == escape, bytes[end + 1] == 0x5C { return end }
            end += 1
        }
        return nil
    }

    static func parse(_ control: ArraySlice<UInt8>) -> KittyCommand {
        var command = KittyCommand()
        for pair in control.split(separator: 0x2C) {
            let parts = pair.split(separator: 0x3D, maxSplits: 1)
            guard parts.count == 2, let key = parts[parts.startIndex].first else { continue }
            let value = String(decoding: parts[parts.startIndex + 1], as: UTF8.self)
            switch Character(UnicodeScalar(key)) {
            case "a": command.action = value.first
            case "i": command.imageID = identifier(value)
            case "I": command.imageNumber = identifier(value)
            case "p": command.placementID = identifier(value)
            case "c": command.columns = Int(value)
            case "r": command.rows = Int(value)
            case "m": command.more = value == "1"
            case "d": command.deleteTarget = value.first
            case "z": command.zIndex = Int(value) ?? 0
            case "C": command.cursorPolicy = Int(value) ?? 0
            case "X": command.pixelX = Int(value) ?? 0
            case "Y": command.pixelY = Int(value) ?? 0
            case "P": command.parentImage = identifier(value)
            case "Q": command.parentPlacement = identifier(value)
            case "H": command.parentColumns = Int(value) ?? 0
            case "V": command.parentRows = Int(value) ?? 0
            case "x": command.x = Int(value)
            case "y": command.y = Int(value)
            case "q": command.quiet = Int(value) ?? 0
            case "U": command.virtual = value == "1"
            case "t": command.medium = value.first
            case "f": command.format = Int(value)
            case "o": command.compression = value.first
            case "S": command.dataSize = Int(value) ?? 0
            case "O": command.dataOffset = Int(value) ?? 0
            case "N": command.hints = Int(value) ?? 0
            case "s": command.stateValue = Int(value)
            case "v": command.loopValue = Int(value)
            case "w": command.cropWidth = Int(value) ?? 0
            case "h": command.cropHeight = Int(value) ?? 0
            default: break
            }
        }
        if let medium = command.medium, medium != "d" { command.more = false }
        return command
    }

    private static func identifier(_ value: String) -> UInt32? {
        guard let number = UInt32(value), number > 0 else { return nil }
        return number
    }

    static func rewrite(
        _ apc: ArraySlice<UInt8>, dropping keys: Set<Character>, setting values: [(Character, String)]
    ) -> [UInt8] {
        let bytes = Array(apc)
        guard bytes.count >= 5 else { return bytes }
        let closing = bytes.count - 2
        let controlEnd = bytes[3..<closing].firstIndex(of: 0x3B) ?? closing
        let replaced = Set(values.map(\.0))
        var pairs: [[UInt8]] = bytes[3..<controlEnd].split(separator: 0x2C).compactMap { pair in
            guard let key = pair.first, !keys.contains(Character(UnicodeScalar(key))),
                  !replaced.contains(Character(UnicodeScalar(key)))
            else { return nil }
            return Array(pair)
        }
        for (key, value) in values { pairs.append(Array("\(key)=\(value)".utf8)) }
        var result = Array(bytes[0..<3])
        result.append(contentsOf: Array(pairs.joined(separator: [0x2C])))
        result.append(contentsOf: bytes[controlEnd...])
        return result
    }
}
