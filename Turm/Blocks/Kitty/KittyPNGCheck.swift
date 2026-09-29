import Foundation

enum KittyPNGCheck {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let idat = Array("IDAT".utf8)
    private static let truncatedText = "PNG data is truncated: not enough bytes to satisfy read request"
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in bytes { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return ~value
    }

    private static func failure(_ message: String, _ code: String = "EBADPNG") -> KittyFailure {
        KittyFailure(code: code, message: message)
    }

    private static func chunkFailure(_ name: ArraySlice<UInt8>, _ message: String) -> KittyFailure {
        var text = ""
        for byte in name {
            let letter = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            text += letter ? String(UnicodeScalar(byte)) : "[" + String(format: "%02x", byte) + "]"
        }
        return failure("\(text): \(message)")
    }

    private static func uint32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func validHeader(_ width: UInt32, _ height: UInt32, _ fields: ArraySlice<UInt8>) -> Bool {
        let values = Array(fields)
        let depth = Int(values[0])
        let color = Int(values[1])
        guard width != 0, height != 0, width <= 1_000_000, height <= 1_000_000 else { return false }
        guard [1, 2, 4, 8, 16].contains(depth), [0, 2, 3, 4, 6].contains(color) else { return false }
        if color == 3 && depth > 8 { return false }
        if (color == 2 || color == 4 || color == 6) && depth < 8 { return false }
        return values[2] == 0 && values[3] == 0 && values[4] < 2
    }

    static func rowLengths(width: Int, height: Int, depth: Int, color: Int, interlaced: Bool) -> [Int] {
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][color] ?? 1
        let pixelDepth = depth * channels
        func row(_ pixels: Int) -> Int { (pixels * pixelDepth + 7) / 8 + 1 }
        guard interlaced else { return [Int](repeating: row(width), count: height) }
        let passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        var lengths: [Int] = []
        for (xStart, yStart, xStep, yStep) in passes {
            let passWidth = (width - xStart + xStep - 1) / xStep
            let passHeight = (height - yStart + yStep - 1) / yStep
            guard passWidth > 0, passHeight > 0 else { continue }
            lengths.append(contentsOf: [Int](repeating: row(passWidth), count: passHeight))
        }
        return lengths
    }

    static func validate(_ data: [UInt8], maxDimension: Int) -> KittyFailure? {
        let truncated = failure(truncatedText)
        guard data.count >= 8 else { return truncated }
        if Array(data[0..<8]) != signature {
            return Array(data[0..<4]) != Array(signature[0..<4])
                ? failure("Not a PNG file") : failure("PNG file corrupted by ASCII conversion")
        }
        var position = 8
        var seenHeader = false
        var palette = false
        var fields: [UInt8] = []
        var width: UInt32 = 0
        var height: UInt32 = 0
        while true {
            guard position + 8 <= data.count else { return truncated }
            let length = Int(uint32(data[position..<(position + 4)]))
            let name = data[(position + 4)..<(position + 8)]
            if data[position] >= 0x80 { return chunkFailure(name, "bad header (invalid length)") }
            if !name.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) {
                return chunkFailure(name, "bad header (invalid type)")
            }
            let isHeader = Array(name) == Array("IHDR".utf8)
            if Array(name) == idat {
                if !seenHeader { return chunkFailure(name, "Missing IHDR before IDAT") }
                if fields[1] == 3, !palette { return chunkFailure(name, "Missing PLTE before IDAT") }
                break
            }
            if !seenHeader, !isHeader { return chunkFailure(name, "missing IHDR") }
            if isHeader, length != 13 { return chunkFailure(name, length < 13 ? "too short" : "too long") }
            let body = position + 8
            guard body + length + 4 <= data.count else { return truncated }
            if name.first! & 0x20 == 0, crc(data[(position + 4)..<(body + length)]) != uint32(data[(body + length)..<(body + length + 4)]) {
                return chunkFailure(name, "CRC error")
            }
            if isHeader {
                seenHeader = true
                let rawWidth = uint32(data[body..<(body + 4)])
                let rawHeight = uint32(data[(body + 4)..<(body + 8)])
                if rawWidth > 0x7FFFFFFF || rawHeight > 0x7FFFFFFF { return failure("PNG unsigned integer out of range") }
                width = rawWidth
                height = rawHeight
                fields = Array(data[(body + 8)..<(body + 13)])
                if !validHeader(width, height, fields[...]) { return failure("Invalid IHDR data") }
            } else if Array(name) == Array("PLTE".utf8) {
                palette = true
            }
            position = body + length + 4
        }
        if Int(width) > maxDimension || Int(height) > maxDimension { return failure("PNG image is too large", "ENOMEM") }
        return validateImageData(data, from: position, width: Int(width), height: Int(height), fields: fields)
    }

    private static func validateImageData(_ data: [UInt8], from start: Int, width: Int, height: Int, fields: [UInt8]) -> KittyFailure? {
        let name = data[(start + 4)..<(start + 8)]
        var stream: [UInt8] = []
        var chunks: [(end: Int, valid: Bool)] = []
        var cursor = start
        while cursor + 8 <= data.count, Array(data[(cursor + 4)..<(cursor + 8)]) == idat {
            let length = Int(uint32(data[cursor..<(cursor + 4)]))
            let body = cursor + 8
            guard body + length + 4 <= data.count else {
                if data.count - body < min(length, 4096) { return failure(truncatedText) }
                stream.append(contentsOf: data[body...])
                cursor = data.count
                break
            }
            stream.append(contentsOf: data[body..<(body + length)])
            let valid = crc(data[(cursor + 4)..<(body + length)]) == uint32(data[(body + length)..<(body + length + 4)])
            chunks.append((stream.count, valid))
            cursor = body + length + 4
        }
        let lengths = rowLengths(width: width, height: height, depth: Int(fields[0]), color: Int(fields[1]), interlaced: fields[4] == 1)
        let total = lengths.reduce(0, +)
        guard stream.count >= 2 else { return notEnough(data, cursor) }
        if let text = KittyInflate.header(stream) { return chunkFailure(name, text) }
        if stream[1] & 0x20 != 0 { return chunkFailure(name, "missing LZ dictionary") }
        let output: [UInt8]
        var inflateFailure: KittyDeflate.Failure?
        let consumed: Int
        var checksumBad = false
        if KittyDeflate.prefersFast(stream[2...]), let fast = KittyDeflate.fast(stream[2...], capacity: total),
           fast.count == total, KittyDeflate.trailerMatches(stream, fast) {
            output = fast
            consumed = stream.count
        } else {
            let outcome = KittyDeflate.inflate(stream, from: 2, capacity: total)
            output = outcome.output
            inflateFailure = outcome.failure
            consumed = outcome.failure == nil ? min(stream.count, outcome.end + 4) : outcome.end
            if outcome.failure == nil, stream.count - outcome.end >= 4 {
                let trailer = stream[outcome.end..<(outcome.end + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                checksumBad = trailer != KittyInflate.adler32(output)
            }
            if inflateFailure == .buffer, output.count >= total { inflateFailure = nil }
        }
        for chunk in chunks where chunk.end <= consumed && !chunk.valid { return chunkFailure(name, "CRC error") }
        var offset = 0
        for length in lengths {
            let end = offset + length
            if end > output.count {
                switch inflateFailure {
                case .some(.data(let text)): return chunkFailure(name, text.isEmpty ? "damaged LZ stream" : text)
                case .some(.buffer): return notEnough(data, cursor)
                case nil: return failure("Not enough image data")
                }
            }
            if checksumBad, end == total { return chunkFailure(name, "incorrect data check") }
            if output[offset] > 4 { return failure("bad adaptive filter value") }
            offset = end
        }
        return nil
    }

    private static func notEnough(_ data: [UInt8], _ cursor: Int) -> KittyFailure {
        cursor + 8 <= data.count ? failure("Not enough image data") : failure(truncatedText)
    }
}
