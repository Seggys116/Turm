import Compression
import Foundation

nonisolated enum KittyDeflate {
    enum Failure: Error, Equatable {
        case data(String)
        case buffer
    }

    struct Outcome {
        var output: [UInt8]
        var end: Int
        var failure: Failure?
    }

    private struct Table {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]
        var left: Int

        init(_ lengths: [Int]) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for length in lengths { count[length] += 1 }
            left = 1
            for length in 1...15 {
                left <<= 1
                left -= count[length]
                if left < 0 { return }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + count[length] }
            for (index, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = index
                offsets[length] += 1
            }
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedTables: (Table, Table) = {
        var lengths = [Int](repeating: 8, count: 288)
        for index in 144..<256 { lengths[index] = 9 }
        for index in 256..<280 { lengths[index] = 7 }
        return (Table(lengths), Table([Int](repeating: 5, count: 30)))
    }()

    private struct Reader {
        let input: [UInt8]
        var position: Int
        var buffer = 0
        var have = 0

        mutating func bits(_ need: Int) throws -> Int {
            var value = buffer
            while have < need {
                guard position < input.count else { throw Failure.buffer }
                value |= Int(input[position]) << have
                position += 1
                have += 8
            }
            buffer = value >> need
            have -= need
            return value & ((1 << need) - 1)
        }

        mutating func decode(_ table: Table, _ message: String) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1...15 {
                code |= try bits(1)
                let count = table.count[length]
                if code - count < first { return table.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.data(message)
        }
    }

    static func inflate(_ input: [UInt8], from start: Int, capacity: Int) -> Outcome {
        var reader = Reader(input: input, position: start)
        var output: [UInt8] = []
        output.reserveCapacity(min(capacity, 1 << 24))
        do {
            try run(&reader, &output, capacity)
            return Outcome(output: output, end: reader.position, failure: nil)
        } catch let failure as Failure {
            return Outcome(output: output, end: reader.position, failure: failure)
        } catch {
            return Outcome(output: output, end: reader.position, failure: .data(""))
        }
    }

    private static func run(_ reader: inout Reader, _ output: inout [UInt8], _ capacity: Int) throws {
        var last = 0
        repeat {
            last = try reader.bits(1)
            switch try reader.bits(2) {
            case 0:
                reader.buffer = 0
                reader.have = 0
                let input = reader.input
                guard reader.position + 4 <= input.count else { throw Failure.buffer }
                let length = Int(input[reader.position]) | Int(input[reader.position + 1]) << 8
                let inverse = Int(input[reader.position + 2]) | Int(input[reader.position + 3]) << 8
                guard length == (~inverse & 0xFFFF) else { throw Failure.data("invalid stored block lengths") }
                reader.position += 4
                let available = min(length, input.count - reader.position)
                let room = min(available, max(capacity - output.count, 0))
                output.append(contentsOf: input[reader.position..<(reader.position + room)])
                reader.position += room
                if room < length { throw Failure.buffer }
            case 1:
                try codes(&reader, &output, fixedTables.0, fixedTables.1, capacity)
            case 2:
                let literals = try reader.bits(5) + 257
                let distances = try reader.bits(5) + 1
                let codeLengths = try reader.bits(4) + 4
                guard literals <= 286, distances <= 30 else { throw Failure.data("too many length or distance symbols") }
                var lengths = [Int](repeating: 0, count: 19)
                for index in 0..<codeLengths { lengths[order[index]] = try reader.bits(3) }
                let lengthTable = Table(lengths)
                guard lengthTable.left == 0 else { throw Failure.data("invalid code lengths set") }
                var all = [Int](repeating: 0, count: literals + distances)
                var index = 0
                while index < literals + distances {
                    let symbol = try reader.decode(lengthTable, "invalid code lengths set")
                    if symbol < 16 {
                        all[index] = symbol
                        index += 1
                    } else {
                        var repeated = 0
                        var count = 0
                        switch symbol {
                        case 16:
                            guard index > 0 else { throw Failure.data("invalid bit length repeat") }
                            repeated = all[index - 1]
                            count = 3 + (try reader.bits(2))
                        case 17: count = 3 + (try reader.bits(3))
                        default: count = 11 + (try reader.bits(7))
                        }
                        guard index + count <= literals + distances else { throw Failure.data("invalid bit length repeat") }
                        for _ in 0..<count {
                            all[index] = repeated
                            index += 1
                        }
                    }
                }
                guard all[256] != 0 else { throw Failure.data("invalid code -- missing end-of-block") }
                let literalTable = Table(Array(all[0..<literals]))
                if literalTable.left < 0 || (literalTable.left > 0 && literals != literalTable.count[0] + literalTable.count[1]) {
                    throw Failure.data("invalid literal/lengths set")
                }
                let distanceTable = Table(Array(all[literals...]))
                if distanceTable.left < 0 || (distanceTable.left > 0 && distances != distanceTable.count[0] + distanceTable.count[1]) {
                    throw Failure.data("invalid distances set")
                }
                try codes(&reader, &output, literalTable, distanceTable, capacity)
            default:
                throw Failure.data("invalid block type")
            }
        } while last == 0
    }

    private static func codes(_ reader: inout Reader, _ output: inout [UInt8], _ literals: Table, _ distances: Table, _ capacity: Int) throws {
        while true {
            var symbol = try reader.decode(literals, "invalid literal/length code")
            if symbol < 256 {
                guard output.count < capacity else { throw Failure.buffer }
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw Failure.data("invalid literal/length code") }
                let length = lengthBase[symbol] + (try reader.bits(lengthExtra[symbol]))
                let slot = try reader.decode(distances, "invalid distance code")
                guard slot < 30 else { throw Failure.data("invalid distance code") }
                let distance = distanceBase[slot] + (try reader.bits(distanceExtra[slot]))
                guard distance <= output.count else { throw Failure.data("invalid distance too far back") }
                guard output.count + length <= capacity else { throw Failure.buffer }
                for _ in 0..<length { output.append(output[output.count - distance]) }
            }
        }
    }

    static func prefersFast(_ body: ArraySlice<UInt8>) -> Bool {
        body.count > 256 * 1024 && (body[body.startIndex] & 0x06) != 0
    }

    static func trailerMatches(_ stream: [UInt8], _ output: [UInt8]) -> Bool {
        guard stream.count >= 6 else { return false }
        let trailer = stream.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return trailer == KittyInflate.adler32(output)
    }

    static func fast(_ body: ArraySlice<UInt8>, capacity: Int) -> [UInt8]? {
        let scratchOut = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let scratchIn = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            scratchOut.deallocate()
            scratchIn.deallocate()
        }
        var stream = compression_stream(dst_ptr: scratchOut, dst_size: 0, src_ptr: UnsafePointer(scratchIn), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }
        var output = [UInt8]()
        output.reserveCapacity(min(capacity, 64 << 20))
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let size = chunk.count
        let finished = body.withUnsafeBytes { source -> Bool in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return false }
            stream.src_ptr = base
            stream.src_size = body.count
            while true {
                let status = chunk.withUnsafeMutableBytes { destination -> compression_status in
                    stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = size
                    return compression_stream_process(&stream, 0)
                }
                let produced = size - stream.dst_size
                output.append(contentsOf: chunk[0..<produced])
                if output.count > capacity { return false }
                switch status {
                case COMPRESSION_STATUS_END:
                    return true
                case COMPRESSION_STATUS_OK:
                    if stream.src_size == 0, produced == 0 { return false }
                default:
                    return false
                }
            }
        }
        guard finished else { return nil }
        return output
    }
}

nonisolated enum KittyInflate {
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            while index < end {
                low &+= UInt32(bytes[index])
                high &+= low
                index += 1
            }
            low %= 65521
            high %= 65521
        }
        return high << 16 | low
    }

    static func header(_ bytes: [UInt8]) -> String? {
        let combined = Int(bytes[0]) << 8 | Int(bytes[1])
        if combined % 31 != 0 { return "incorrect header check" }
        if bytes[0] & 0x0F != 8 { return "unknown compression method" }
        if bytes[0] >> 4 > 7 { return "invalid window size" }
        return nil
    }

    static func inflate(_ input: Data, capacity: Int) -> Result<Data, KittyFailure> {
        func failed(_ name: String) -> Result<Data, KittyFailure> {
            .failure(KittyFailure(code: "EINVAL", message: "Failed to inflate image data with error: \(name)"))
        }
        let bytes = [UInt8](input)
        guard bytes.count >= 2 else { return failed("Z_BUF_ERROR") }
        guard header(bytes) == nil else { return failed("Z_DATA_ERROR") }
        guard bytes[1] & 0x20 == 0 else { return failed("Unknown error: 2") }
        if KittyDeflate.prefersFast(bytes[2...]), let output = KittyDeflate.fast(bytes[2...], capacity: capacity),
           output.count == capacity, KittyDeflate.trailerMatches(bytes, output) {
            return .success(Data(output))
        }
        let result = KittyDeflate.inflate(bytes, from: 2, capacity: capacity)
        switch result.failure {
        case .some(.buffer): return failed("Z_BUF_ERROR")
        case .some(.data): return failed("Z_DATA_ERROR")
        case nil: break
        }
        guard bytes.count - result.end >= 4 else { return failed("Z_BUF_ERROR") }
        let trailer = bytes[result.end..<(result.end + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard trailer == adler32(result.output) else { return failed("Z_DATA_ERROR") }
        guard result.output.count == capacity else {
            return .failure(KittyFailure(code: "EINVAL", message: "Image data size post inflation does not match expected size"))
        }
        return .success(Data(result.output))
    }
}
