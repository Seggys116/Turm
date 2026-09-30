import Foundation

enum ShellEvent: Equatable {
    case commandStarted
    case promptReady(exitCode: Int32?, directory: String)
    case notification(title: String, body: String)
    case environment([String: String])
    case sshStarted(socket: String, target: String)
    case remoteHello(token: String, kind: String, host: String)
    case remotePrompt(token: String, exitCode: Int32?, directory: String)
}

enum StreamPiece: Equatable {
    case output([UInt8])
    case event(ShellEvent)
}

struct ShellStreamParser {
    private enum State {
        case ground
        case escape
        case osc
        case oscEscape
        case discard
        case discardEscape
    }

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let closeBracket: UInt8 = 0x5D
    private static let backslash: UInt8 = 0x5C
    private static let maxPayload = 4096
    private static let maxEnvironmentPayload = 400_000
    private static let prefixBytes = Array("7777;".utf8)
    private static let prefix = "7777;"

    private var state = State.ground
    private var payload: [UInt8] = []

    mutating func consume(_ bytes: some Sequence<UInt8>) -> [StreamPiece] {
        var pieces: [StreamPiece] = []
        var plain: [UInt8] = []

        func flush() {
            if !plain.isEmpty {
                pieces.append(.output(plain))
                plain.removeAll(keepingCapacity: true)
            }
        }

        for byte in bytes {
            switch state {
            case .ground:
                if byte == Self.esc {
                    state = .escape
                } else {
                    plain.append(byte)
                }
            case .escape:
                if byte == Self.closeBracket {
                    state = .osc
                    payload.removeAll(keepingCapacity: true)
                } else {
                    plain.append(Self.esc)
                    state = .ground
                    if byte == Self.esc {
                        state = .escape
                    } else {
                        plain.append(byte)
                    }
                }
            case .osc:
                if byte == Self.bel {
                    if let event = takeEvent() {
                        flush()
                        pieces.append(.event(event))
                    } else {
                        if let note = Self.notification(payload) {
                            flush()
                            pieces.append(.event(note))
                        }
                        release(into: &plain, terminator: [Self.bel])
                    }
                } else if byte == Self.esc {
                    state = .oscEscape
                } else {
                    payload.append(byte)
                    if payload.starts(with: Self.prefixBytes) {
                        if payload.count > Self.maxEnvironmentPayload {
                            payload.removeAll(keepingCapacity: false)
                            state = .discard
                        }
                    } else if payload.count > Self.maxPayload {
                        release(into: &plain, terminator: [])
                    }
                }
            case .oscEscape:
                if byte == Self.backslash {
                    if let event = takeEvent() {
                        flush()
                        pieces.append(.event(event))
                    } else {
                        if let note = Self.notification(payload) {
                            flush()
                            pieces.append(.event(note))
                        }
                        release(into: &plain, terminator: [Self.esc, Self.backslash])
                    }
                } else {
                    payload.append(Self.esc)
                    payload.append(byte)
                    state = .osc
                }
            case .discard:
                if byte == Self.bel {
                    state = .ground
                } else if byte == Self.esc {
                    state = .discardEscape
                }
            case .discardEscape:
                state = byte == Self.backslash ? .ground : .discard
            }
        }
        flush()
        return pieces
    }

    private mutating func takeEvent() -> ShellEvent? {
        guard let event = Self.decode(payload) else { return nil }
        payload.removeAll(keepingCapacity: true)
        state = .ground
        return event
    }

    /// An OSC that is not ours is passed through untouched so the emulator still sees it.
    private mutating func release(into plain: inout [UInt8], terminator: [UInt8]) {
        plain.append(Self.esc)
        plain.append(Self.closeBracket)
        plain.append(contentsOf: payload)
        plain.append(contentsOf: terminator)
        payload.removeAll(keepingCapacity: true)
        state = .ground
    }

    private static func notification(_ payload: [UInt8]) -> ShellEvent? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        if text.hasPrefix("777;notify;") {
            let parts = text.dropFirst("777;notify;".count).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard let title = parts.first else { return nil }
            return .notification(title: String(title), body: parts.count > 1 ? String(parts[1]) : "")
        }
        if text.hasPrefix("9;"), !text.hasPrefix("9;4;") {
            return .notification(title: "", body: String(text.dropFirst(2)))
        }
        return nil
    }

    private static func decode(_ payload: [UInt8]) -> ShellEvent? {
        guard let text = String(bytes: payload, encoding: .utf8), text.hasPrefix(prefix) else { return nil }
        let body = text.dropFirst(prefix.count)
        let fields = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        let remote = body.split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false)
        switch fields.first {
        case "C":
            return .commandStarted
        case "P":
            guard fields.count == 3 else { return nil }
            return .promptReady(exitCode: Int32(fields[1]), directory: String(fields[2]))
        case "E":
            return .environment(fields.count > 1 ? environment(fromBase64: fields[1]) : [:])
        case "S":
            guard fields.count == 3, !fields[1].isEmpty else { return nil }
            return .sshStarted(socket: String(fields[1]), target: String(fields[2]))
        case "H":
            guard remote.count == 4, !remote[1].isEmpty else { return nil }
            return .remoteHello(token: String(remote[1]), kind: String(remote[2]), host: String(remote[3]))
        case "R":
            guard remote.count == 4, !remote[1].isEmpty else { return nil }
            return .remotePrompt(token: String(remote[1]), exitCode: Int32(remote[2]), directory: String(remote[3]))
        default:
            return nil
        }
    }

    private static func environment(fromBase64 text: Substring) -> [String: String] {
        guard let data = Data(base64Encoded: String(text), options: .ignoreUnknownCharacters) else { return [:] }
        var variables: [String: String] = [:]
        for entry in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: 0x3D) else { continue }
            let key = String(decoding: entry[entry.startIndex..<equals], as: UTF8.self)
            guard isIdentifier(key) else { continue }
            variables[key] = String(decoding: entry[entry.index(after: equals)...], as: UTF8.self)
        }
        return variables
    }

    private static func isIdentifier(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard let first = bytes.first, first == 0x5F || isLetter(first) else { return false }
        return bytes.allSatisfy { $0 == 0x5F || isLetter($0) || (0x30...0x39).contains($0) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

enum AltScreenSequence {
    private static let modes: Set<Int> = [1049, 1047, 47]

    static func firstSwitch(in bytes: ArraySlice<UInt8>, entering: Bool) -> Int? {
        let final: UInt8 = entering ? 0x68 : 0x6C
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == 0x1B,
                  index + 2 < bytes.endIndex,
                  bytes[index + 1] == 0x5B,
                  bytes[index + 2] == 0x3F
            else {
                index += 1
                continue
            }
            var end = index + 3
            while end < bytes.endIndex, bytes[end] < 0x40 { end += 1 }
            guard end < bytes.endIndex else { return nil }
            if bytes[end] == final {
                let params = bytes[(index + 3)..<end].split(separator: 0x3B).compactMap {
                    Int(String(decoding: $0, as: UTF8.self))
                }
                if params.contains(where: modes.contains) { return end + 1 }
            }
            index = end + 1
        }
        return nil
    }
}
