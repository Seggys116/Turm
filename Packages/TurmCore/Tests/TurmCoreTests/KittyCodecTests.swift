import Compression
import CoreGraphics
import Foundation
import Testing

@testable import TurmCore

private let pngSignature = KittyFixtures.pngSignature
private let zlibFixtures = KittyFixtures.zlibFixtures

private func bigEndian(_ value: UInt32) -> [UInt8] { KittyFixtures.bigEndian(value) }
private func solidImage() -> CGImage { KittyFixtures.solidImage() }
private func pngChunk(_ name: String, _ body: [UInt8], badChecksum: Bool = false) -> [UInt8] {
    KittyFixtures.pngChunk(name, body, badChecksum: badChecksum)
}
private func header(width: UInt32, height: UInt32, depth: UInt8 = 8, color: UInt8 = 6, interlace: UInt8 = 0) -> [UInt8] {
    KittyFixtures.header(width: width, height: height, depth: depth, color: color, interlace: interlace)
}

private func zlibStored(_ raw: [UInt8], checksum: UInt32? = nil) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01]
    var offset = 0
    repeat {
        let count = min(65535, raw.count - offset)
        let final: UInt8 = offset + count >= raw.count ? 1 : 0
        out += [final, UInt8(count & 255), UInt8(count >> 8), UInt8(~count & 255), UInt8((~count >> 8) & 255)]
        out += raw[offset..<(offset + count)]
        offset += count
    } while offset < raw.count
    return out + bigEndian(checksum ?? KittyInflate.adler32(raw))
}

private func png(
    rows: [[UInt8]], stream: [UInt8]? = nil, interlace: UInt8 = 0, color: UInt8 = 6, width: UInt32 = 2,
    height: UInt32 = 2, badChecksum: Bool = false
) -> [UInt8] {
    let raw = rows.flatMap { $0 }
    return pngSignature + pngChunk("IHDR", header(width: width, height: height, color: color, interlace: interlace))
        + pngChunk("IDAT", stream ?? zlibStored(raw), badChecksum: badChecksum) + pngChunk("IEND", [])
}

private func rgbaRows(_ filters: [UInt8]) -> [[UInt8]] {
    filters.map { [$0] + [UInt8](repeating: 0, count: 8) }
}

struct KittyPNGDataTests {
    private func check(_ bytes: [UInt8]) -> KittyFailure? {
        KittyPNGCheck.validate(bytes, maxDimension: 10_000)
    }

    @Test func wellFormedImageDataPasses() {
        #expect(check(png(rows: rgbaRows([0, 4]))) == nil)
    }

    @Test func badFilterBytesAreRejected() {
        #expect(check(png(rows: rgbaRows([0, 9])))?.message == "bad adaptive filter value")
        #expect(check(png(rows: rgbaRows([5, 0])))?.code == "EBADPNG")
    }

    @Test func missingRowsAreNotEnoughImageData() {
        #expect(check(png(rows: rgbaRows([0])))?.message == "Not enough image data")
    }

    @Test func extraDecodedDataIsToleratedLikeLibpng() {
        #expect(check(png(rows: rgbaRows([0, 0, 0]))) == nil)
    }

    @Test func zlibDamageIsReportedWithZlibsText() {
        let rows = rgbaRows([0, 0])
        let raw = rows.flatMap { $0 }
        #expect(check(png(rows: rows, stream: zlibStored(raw, checksum: 1)))?.message == "IDAT: incorrect data check")
        var badBlock = zlibStored(raw)
        badBlock[2] = 7
        #expect(check(png(rows: rows, stream: badBlock))?.message == "IDAT: invalid block type")
        var badHeader = zlibStored(raw)
        badHeader[0] = 0
        badHeader[1] = 0
        #expect(check(png(rows: rows, stream: badHeader))?.message == "IDAT: unknown compression method")
        var badCheck = zlibStored(raw)
        badCheck[1] = 0x02
        #expect(check(png(rows: rows, stream: badCheck))?.message == "IDAT: incorrect header check")
        var storedLength = zlibStored(raw)
        storedLength[5] ^= 0xFF
        #expect(check(png(rows: rows, stream: storedLength))?.message == "IDAT: invalid stored block lengths")
    }

    @Test func truncatedStreamsFollowedByAnotherChunkAreNotEnoughData() {
        let rows = rgbaRows([0, 0])
        let stream = zlibStored(rows.flatMap { $0 })
        #expect(check(png(rows: rows, stream: Array(stream.dropLast(12))))?.message == "Not enough image data")
    }

    @Test func missingChecksumAfterAllRowsIsNotAnError() {
        let rows = rgbaRows([0, 0])
        #expect(check(png(rows: rows, stream: Array(zlibStored(rows.flatMap { $0 }).dropLast(4)))) == nil)
    }

    @Test func idatChunkCRCCorruptionIsACRCError() {
        #expect(check(png(rows: rgbaRows([0, 0]), badChecksum: true))?.message == "IDAT: CRC error")
    }

    @Test func zlibChecksumCorruptionIsNotACRCError() {
        let rows = rgbaRows([0, 0])
        let raw = rows.flatMap { $0 }
        #expect(check(png(rows: rows, stream: zlibStored(raw, checksum: 7)))?.message == "IDAT: incorrect data check")
    }

    @Test func rowSizesFollowBitDepthAndAdam7() {
        #expect(KittyPNGCheck.rowLengths(width: 3, height: 2, depth: 16, color: 2, interlaced: false) == [19, 19])
        #expect(KittyPNGCheck.rowLengths(width: 3, height: 3, depth: 8, color: 0, interlaced: true) == [2, 2, 3, 2, 2, 4])
        #expect(KittyPNGCheck.rowLengths(width: 9, height: 1, depth: 1, color: 0, interlaced: false) == [3])
        let interlaced = png(rows: [[UInt8](repeating: 0, count: 15)], interlace: 1, color: 0, width: 3, height: 3)
        #expect(check(interlaced) == nil)
        let short = png(rows: [[UInt8](repeating: 0, count: 14)], interlace: 1, color: 0, width: 3, height: 3)
        #expect(check(short)?.message == "Not enough image data")
    }
}

struct KittyInflateTests {
    private func inflate(_ name: String, capacity: Int = 40) -> Result<Data, KittyFailure> {
        KittyInflate.inflate(Data(base64Encoded: zlibFixtures[name]!)!, capacity: capacity)
    }

    private func failure(_ result: Result<Data, KittyFailure>) -> String? {
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    @Test func inflaterHandlesStoredFixedAndDynamicBlocks() {
        let stored = Data([0x78, 0x01, 0x01, 0x03, 0x00, 0xFC, 0xFF, 1, 2, 3, 0x00, 0x0D, 0x00, 0x07])
        if case .success(let bytes) = KittyInflate.inflate(stored, capacity: 3) {
            #expect([UInt8](bytes) == [1, 2, 3])
        } else {
            Issue.record("stored block should inflate")
        }
        if case .success(let bytes) = inflate("good") {
            #expect([UInt8](bytes) == Array(0..<40))
        } else {
            Issue.record("fixed block stream should inflate")
        }
    }

    @Test func truncatedStreamsAreBufferErrors() {
        for name in ["truncatedBody", "missingTrailer", "partialTrailer", "headerOnly", "oneByte"] {
            #expect(failure(inflate(name)) == "Failed to inflate image data with error: Z_BUF_ERROR", "\(name)")
        }
    }

    @Test func corruptStreamsAreDataErrors() {
        for name in ["badChecksum", "badHeader", "corruptBody"] {
            #expect(failure(inflate(name)) == "Failed to inflate image data with error: Z_DATA_ERROR", "\(name)")
        }
    }

    @Test func outputLargerThanCapacityIsABufferError() {
        #expect(failure(inflate("good", capacity: 16)) == "Failed to inflate image data with error: Z_BUF_ERROR")
    }

    @Test func outputSmallerThanCapacityIsASizeMismatch() {
        #expect(failure(inflate("good", capacity: 72)) == "Image data size post inflation does not match expected size")
    }

    @Test func inexactCapacityLetsTheStreamDecideItsLength() {
        let data = Data(base64Encoded: zlibFixtures["good"]!)!
        if case .success(let bytes) = KittyInflate.inflate(data, capacity: 72, exact: false) {
            #expect([UInt8](bytes) == Array(0..<40))
        } else {
            Issue.record("a stream shorter than the capacity should inflate when the size is not exact")
        }
    }

    @Test func trailingBytesAreAccepted() {
        if case .success(let bytes) = inflate("trailing") {
            #expect([UInt8](bytes) == Array(0..<40))
        } else {
            Issue.record("bytes after the checksum should be ignored")
        }
    }

    @Test func checksumAlgorithmMatchesKnownValues() {
        #expect(KittyInflate.adler32(Array("Wikipedia".utf8)) == 0x11E60398)
        #expect(KittyInflate.adler32([]) == 1)
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

struct KittyFastInflateTests {
    private func stream(_ raw: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: raw.count + raw.count / 8 + 4096)
        let size = compression_encode_buffer(&output, output.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + output[0..<size] + bigEndian(KittyInflate.adler32(raw))
    }

    @Test func fastPathAndPuffPortAgreeOnALargeStream() throws {
        var generator = SplitMix64(state: 0x1234_5678_9ABC_DEF0)
        let raw = (0..<4_000_000).map { _ in UInt8(truncatingIfNeeded: generator.next() & 0x0F) }
        let packed = stream(raw)
        try #require(packed.count - 6 > 256 * 1024, "the fixture must compress to more than the 256 KB fast-path threshold")
        try #require(packed[2] & 0x06 != 0, "the first deflate block must not be a stored block")
        #expect(KittyDeflate.prefersFast(packed[2...]))
        #expect(KittyDeflate.fast(packed[2...], capacity: raw.count) == raw)
        #expect(KittyDeflate.trailerMatches(packed, raw))
        let slow = KittyDeflate.inflate(packed, from: 2, capacity: raw.count)
        #expect(slow.failure == nil && slow.output == raw)
        if case .success(let data) = KittyInflate.inflate(Data(packed), capacity: raw.count) {
            #expect([UInt8](data) == raw)
        } else {
            Issue.record("a valid stream should inflate")
        }
    }

    @Test func fastPathRefusesStreamsLargerThanExpected() {
        let raw = [UInt8](repeating: 7, count: 1000)
        #expect(KittyDeflate.fast(stream(raw)[2...], capacity: 10) == nil)
    }
}

struct KittyAnimationPlaybackTests {
    @Test func playbackFollowsGapsAndLoops() {
        let animation = KittyAnimation(root: solidImage())
        animation.append(solidImage(), gap: 100)
        animation.setGap(100, of: 0)
        let start = Date(timeIntervalSince1970: 1000)
        animation.setState(3, now: start)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.05)) == 0)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.15)) == 1)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.25)) == 0)
        animation.setLoops(2)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.25)) == 1)
        animation.setState(1)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.05)) == animation.current)
    }

    @Test func gaplessFramesAreSkippedAndLoadingModeWaits() {
        let animation = KittyAnimation(root: solidImage())
        animation.setGap(40, of: 0)
        animation.append(solidImage(), gap: 0)
        animation.append(solidImage(), gap: 50)
        let start = Date(timeIntervalSince1970: 1000)
        animation.setState(2, now: start)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.01)) == 0)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.05)) == 2)
        #expect(animation.frameIndex(at: start.addingTimeInterval(5)) == 2)
        #expect(animation.duration == 90)
    }

    @Test func removingFramesFollowsKittyRules() {
        func make(_ gaps: [Int]) -> KittyAnimation {
            let animation = KittyAnimation(root: solidImage())
            animation.setGap(gaps[0], of: 0)
            for gap in gaps.dropFirst() { animation.append(solidImage(), gap: gap) }
            return animation
        }
        let single = make([5])
        #expect(!single.removeFrame(1))
        let root = make([5, 10, 20])
        #expect(root.removeFrame(1))
        #expect(root.frames.map(\.gap) == [10, 20] && root.duration == 30)
        let middle = make([5, 10, 20])
        middle.removeFrame(2)
        #expect(middle.frames.map(\.gap) == [5, 20] && middle.duration == 25)
        let clamped = make([5, 10, 20])
        clamped.removeFrame(99)
        #expect(clamped.frames.map(\.gap) == [5, 10])
        let zero = make([5, 10, 20])
        zero.removeFrame(0)
        #expect(zero.frames.map(\.gap) == [10, 20])
    }

    @Test func removingFramesAdjustsTheCurrentFrame() {
        func make() -> KittyAnimation {
            let animation = KittyAnimation(root: solidImage())
            animation.append(solidImage(), gap: 10)
            animation.append(solidImage(), gap: 20)
            return animation
        }
        let before = make()
        before.show(2)
        before.removeFrame(2)
        #expect(before.current == 1)
        let last = make()
        last.show(2)
        last.removeFrame(3)
        #expect(last.current == 1)
        let same = make()
        same.show(1)
        same.removeFrame(3)
        #expect(same.current == 1)
        let earlier = make()
        earlier.show(1)
        earlier.removeFrame(2)
        #expect(earlier.current == 0)
        let root = make()
        root.removeFrame(1)
        #expect(root.current == 0)
    }
}
