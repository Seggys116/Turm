struct SGRRewriter {
    private var carry: [UInt8] = []
    private static let carryLimit = 64

    mutating func rewrite(_ input: [UInt8]) -> [UInt8] {
        guard !carry.isEmpty || input.contains(0x1B) else { return input }
        let bytes = carry + input
        carry = []
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.append(bytes[index])
                index += 1
                continue
            }
            guard index + 1 < bytes.count else {
                carry = [0x1B]
                break
            }
            guard bytes[index + 1] == 0x5B else {
                output.append(0x1B)
                index += 1
                continue
            }
            var end = index + 2
            while end < bytes.count, (0x20...0x3F).contains(bytes[end]) { end += 1 }
            guard end < bytes.count else {
                if bytes.count - index <= Self.carryLimit {
                    carry = Array(bytes[index...])
                } else {
                    output.append(contentsOf: bytes[index...])
                }
                break
            }
            let range = (index + 2)..<end
            if bytes[end] == 0x6D, let sixPossible = Self.scan(bytes, range) {
                output.append(contentsOf: [0x1B, 0x5B])
                if sixPossible {
                    output.append(contentsOf: Self.rewriteParameters(Array(bytes[range])))
                } else {
                    output.append(contentsOf: bytes[range])
                }
                output.append(0x6D)
            } else {
                output.append(contentsOf: bytes[index...end])
            }
            index = end + 1
        }
        return output
    }

    /// Nil when the bytes are not plain SGR parameters; otherwise whether a parameter equal to 6 appears, the only case rewriteParameters can change.
    static func scan(_ bytes: [UInt8], _ range: Range<Int>) -> Bool? {
        var sixPossible = false
        var value = 0
        var plain = true
        for position in range {
            let byte = bytes[position]
            switch byte {
            case 0x30...0x39:
                value = min(value * 10 + Int(byte - 0x30), 100_001)
            case 0x3B, 0x3A:
                if plain && value == 6 { sixPossible = true }
                plain = byte == 0x3B
                value = 0
            default:
                return nil
            }
        }
        return sixPossible || (plain && value == 6)
    }

    static func rewriteParameters(_ params: [UInt8]) -> [UInt8] {
        var groups = params.split(separator: 0x3B, omittingEmptySubsequences: false).map { Array($0) }
        var position = 0
        while position < groups.count {
            let group = groups[position]
            if group.contains(0x3A) {
                position += 1
                continue
            }
            switch value(of: group) {
            case 38, 48, 58:
                let mode = position + 1 < groups.count && !groups[position + 1].contains(0x3A) ? value(of: groups[position + 1]) : nil
                position += mode == 5 ? 3 : (mode == 2 ? 5 : 1)
            case 6:
                groups[position] = [0x35]
                position += 1
            default:
                position += 1
            }
        }
        return Array(groups.joined(separator: [0x3B]))
    }

    private static func value(of group: [UInt8]) -> Int? {
        guard !group.isEmpty else { return nil }
        var result = 0
        for byte in group {
            result = result * 10 + Int(byte - 0x30)
            if result > 100_000 { return nil }
        }
        return result
    }
}
