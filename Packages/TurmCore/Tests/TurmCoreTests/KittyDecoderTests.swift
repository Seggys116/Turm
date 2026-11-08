import CoreGraphics
import Foundation
import Testing
@testable import TurmCore

struct KittyDecoderTests {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func command(format: Int, width: Int = 0, height: Int = 0, medium: Character? = nil) -> KittyCommand {
        var command = KittyCommand()
        command.format = format
        command.stateValue = width
        command.loopValue = height
        command.medium = medium
        return command
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let count = image.width * image.height * 4
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: count))
    }

    private func image(_ result: Result<CGImage, KittyFailure>) throws -> CGImage {
        try result.get()
    }

    @Test func rgbPixelsAreReadBackOpaque() throws {
        let data = Data([255, 0, 0, 0, 255, 0])
        let decoded = try image(KittyDecoder.decode(command: command(format: 24, width: 2, height: 1), bytes: data))
        #expect(decoded.width == 2 && decoded.height == 1)
        #expect(pixels(decoded) == [255, 0, 0, 255, 0, 255, 0, 255])
        #expect(KittyDecoder.opaque(command: command(format: 24, width: 2, height: 1)))
    }

    @Test func rgbaKeepsStraightAlpha() throws {
        let data = Data([10, 20, 30, 255, 200, 100, 50, 128])
        let decoded = try image(KittyDecoder.decode(command: command(format: 32, width: 2, height: 1), bytes: data))
        #expect(decoded.alphaInfo == .last)
        #expect(Array(decoded.dataProvider!.data! as Data) == [10, 20, 30, 255, 200, 100, 50, 128])
        let read = pixels(decoded)
        #expect(Array(read[0..<4]) == [10, 20, 30, 255])
        #expect(read[7] == 128)
        #expect(!KittyDecoder.opaque(command: command(format: 32, width: 2, height: 1)))
    }

    @Test func pngDecodesToOnePixel() throws {
        let data = try #require(Data(base64Encoded: Self.png))
        let decoded = try image(KittyDecoder.decode(command: command(format: 100), bytes: data))
        #expect(decoded.width == 1 && decoded.height == 1)
    }

    @Test func garbagePngIsRefused() {
        let result = KittyDecoder.decode(command: command(format: 100), bytes: Data([1, 2, 3, 4]))
        guard case .failure(let failure) = result else { Issue.record("decoded garbage"); return }
        #expect(failure.code == "EBADPNG")
    }

    @Test func oversizeIsRefused() {
        let result = KittyDecoder.decode(command: command(format: 32, width: 10_001, height: 1), bytes: Data())
        guard case .failure(let failure) = result else { Issue.record("accepted oversize"); return }
        #expect(failure == KittyFailure(code: "EINVAL", message: "Image too large, width or height greater than 10000"))
    }

    @Test func shortDataIsRefused() {
        let result = KittyDecoder.decode(command: command(format: 32, width: 2, height: 2), bytes: Data(count: 10))
        guard case .failure(let failure) = result else { Issue.record("accepted short data"); return }
        #expect(failure == KittyFailure(code: "ENODATA", message: "Insufficient image data: 10 < 16"))
    }

    @Test func localMediaIsRefusedWhenDisallowed() {
        for medium: Character in ["f", "t", "s"] {
            var state = KittyLoadState()
            let name = Array(Data("/tmp/tty-graphics-protocol-missing".utf8).base64EncodedString().utf8)
            let failure = KittyLoadCheck.accept(
                &state, chunk: name[...], command: command(format: 32, width: 1, height: 1, medium: medium), more: false,
                allowsLocalMedia: false
            )
            #expect(failure == KittyFailure(code: "EBADF", message: "Failed to read image file"))
            #expect(state.openedPath == nil)
        }
    }

    @Test func directBytesAreReturnedAfterLoad() throws {
        var state = KittyLoadState()
        let payload = Data([1, 2, 3, 4])
        let chunk = Array(payload.base64EncodedString().utf8)
        let cmd = command(format: 32, width: 1, height: 1)
        #expect(KittyLoadCheck.accept(&state, chunk: chunk[...], command: cmd, more: false) == nil)
        #expect(KittyLoadCheck.bytes(state, command: cmd) == payload)
    }
}
