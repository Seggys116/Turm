import Foundation

public nonisolated enum CompanionFrameError: Error, Equatable {
    case oversize(Int)
    case empty
    case malformed
}

public nonisolated struct CompanionFrameCoder {
    private var buffer: [UInt8] = []
    private var failed = false

    public init() {}

    public static func encode(_ message: CompanionMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= Companion.maxFrame else { throw CompanionFrameError.oversize(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    public mutating func feed(_ data: Data) throws -> [CompanionMessage] {
        guard !failed else { throw CompanionFrameError.malformed }
        buffer.append(contentsOf: data)
        var messages: [CompanionMessage] = []
        var offset = 0
        let decoder = JSONDecoder()
        while buffer.count - offset >= 4 {
            let length = buffer[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            if length > Companion.maxFrame {
                failed = true
                throw CompanionFrameError.oversize(length)
            }
            if length == 0 {
                failed = true
                throw CompanionFrameError.empty
            }
            guard buffer.count - offset - 4 >= length else { break }
            let body = Data(buffer[offset + 4..<offset + 4 + length])
            do {
                messages.append(try decoder.decode(CompanionMessage.self, from: body))
            } catch {
                guard Self.isUnknownKind(body) else {
                    failed = true
                    throw CompanionFrameError.malformed
                }
            }
            offset += 4 + length
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return messages
    }

    // a newer peer's message this build has no case for is skipped, not treated as corruption
    static func isUnknownKind(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object.count == 1,
              let key = object.keys.first
        else { return false }
        return CompanionMessage.Kind(rawValue: key) == nil
    }
}
