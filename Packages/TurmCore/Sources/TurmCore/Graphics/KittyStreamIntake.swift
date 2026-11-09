import Foundation

public struct KittyStreamIntake {
    public static let defaultLimit = 128 * 1024 * 1024

    public let limit: Int
    public private(set) var isSkipping = false
    private var held: [UInt8] = []
    private var skipCarry: [UInt8] = []

    public init(limit: Int = KittyStreamIntake.defaultLimit) {
        self.limit = limit
    }

    public mutating func take(_ chunk: [UInt8]) -> [UInt8]? {
        var incoming = chunk
        if isSkipping {
            guard let rest = skip(incoming) else { return nil }
            incoming = rest
        }
        guard !held.isEmpty else { return incoming }
        let scanned = held.count
        held.append(contentsOf: incoming)
        let opensGraphics = held.count >= 3 && held[0] == 0x1B && held[1] == 0x5F && held[2] == 0x47
        if opensGraphics, KittyGraphicsScanner.terminator(in: held, from: max(3, scanned - 1)) == nil {
            if held.count > limit {
                skipCarry = held.last == 0x1B ? [0x1B] : []
                isSkipping = true
                held = []
            }
            return nil
        }
        let ready = held
        held = []
        return ready
    }

    public mutating func split(_ bytes: [UInt8]) -> [KittyGraphicsScanner.Piece] {
        let split = KittyGraphicsScanner.split(bytes)
        held = Array(split.remainder)
        return split.pieces
    }

    private mutating func skip(_ chunk: [UInt8]) -> [UInt8]? {
        let bytes = skipCarry + chunk
        skipCarry = []
        guard let end = KittyGraphicsScanner.terminator(in: bytes, from: 0) else {
            if bytes.last == 0x1B { skipCarry = [0x1B] }
            return nil
        }
        isSkipping = false
        return Array(bytes[(bytes[end] == 0x1B ? end + 2 : end + 1)...])
    }
}
