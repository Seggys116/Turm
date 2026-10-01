import Foundation
import Testing
@testable import TurmCore

struct CompanionFrameCoderTests {
    private let sample: [CompanionMessage] = [
        .ping,
        .submit(id: UUID(), text: "echo hello"),
        .output(id: UUID(), blockID: UUID(), bytes: Data([0, 1, 2, 0xFF])),
    ]

    private func frames(_ messages: [CompanionMessage]) throws -> Data {
        try messages.reduce(into: Data()) { $0.append(try CompanionFrameCoder.encode($1)) }
    }

    @Test func decodesOneFrame() throws {
        var coder = CompanionFrameCoder()
        let decoded = try coder.feed(CompanionFrameCoder.encode(sample[1]))
        #expect(decoded == [sample[1]])
    }

    @Test func prefixIsBigEndianLength() throws {
        let frame = try CompanionFrameCoder.encode(.ping)
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(length == frame.count - 4)
    }

    @Test func handlesSplitReads() throws {
        var coder = CompanionFrameCoder()
        var decoded: [CompanionMessage] = []
        for byte in try frames(sample) {
            decoded += try coder.feed(Data([byte]))
        }
        #expect(decoded == sample)
    }

    @Test func handlesCoalescedReads() throws {
        var coder = CompanionFrameCoder()
        let decoded = try coder.feed(frames(sample))
        #expect(decoded == sample)
    }

    @Test func handlesPartialTrailingFrame() throws {
        var coder = CompanionFrameCoder()
        let data = try frames(sample)
        let cut = data.count - 3
        let first = try coder.feed(data.prefix(cut))
        #expect(first == Array(sample.prefix(2)))
        let rest = try coder.feed(data.suffix(from: cut))
        #expect(rest == [sample[2]])
    }

    @Test func rejectsOversizeHeader() {
        var coder = CompanionFrameCoder()
        var length = UInt32(Companion.maxFrame + 1).bigEndian
        let header = Data(bytes: &length, count: 4)
        #expect(throws: CompanionFrameError.oversize(Companion.maxFrame + 1)) { try coder.feed(header) }
        #expect(throws: CompanionFrameError.self) { try coder.feed(Data([0])) }
    }

    @Test func rejectsOversizeEncode() {
        let big = CompanionMessage.input(id: UUID(), bytes: Data(count: Companion.maxFrame))
        #expect(throws: CompanionFrameError.self) { try CompanionFrameCoder.encode(big) }
    }

    @Test func rejectsEmptyFrame() {
        var coder = CompanionFrameCoder()
        #expect(throws: CompanionFrameError.empty) { try coder.feed(Data([0, 0, 0, 0])) }
    }

    @Test func rejectsGarbageBody() {
        var coder = CompanionFrameCoder()
        let body = Data("not json".utf8)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        #expect(throws: CompanionFrameError.malformed) { try coder.feed(frame) }
    }
}
