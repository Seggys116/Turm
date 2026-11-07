import Testing
@testable import TurmCore

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let square = [9, 1]

private func decode(_ text: String, params: [Int] = square, limits: SixelLimits = SixelLimits()) -> SixelImage? {
    SixelDecoder.decode(Array(text.utf8), params: params, limits: limits)
}

private func pixel(_ image: SixelImage, _ x: Int, _ y: Int) -> [UInt8] {
    let offset = (y * image.width + x) * 4
    return Array(image.rgba[offset..<offset + 4])
}

@Suite struct SixelDecoderTests {
    let red: [UInt8] = [255, 0, 0, 255]
    let clear: [UInt8] = [0, 0, 0, 0]

    @Test func singlePixelTopOfBand() throws {
        let image = try #require(decode("#1;2;100;0;0@"))
        #expect(image.width == 1)
        #expect(image.height == 6)
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 0, 1) == clear)
        #expect(pixel(image, 0, 5) == clear)
    }

    @Test func fullColumn() throws {
        let image = try #require(decode("#1;2;0;100;0~"))
        #expect(image.width == 1 && image.height == 6)
        for y in 0..<6 { #expect(pixel(image, 0, y) == [0, 255, 0, 255]) }
    }

    @Test func bitsMapTopToBottom() throws {
        let image = try #require(decode("#1;2;100;0;0H"))
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 0, 3) == red)
        #expect(pixel(image, 0, 1) == clear)
    }

    @Test func repeatIntroducer() throws {
        let image = try #require(decode("#1;2;100;100;100!5~"))
        #expect(image.width == 5 && image.height == 6)
        #expect(image.rgba.allSatisfy { $0 == 255 })
    }

    @Test func carriageReturnOverlaysSecondColour() throws {
        let image = try #require(decode("#1;2;100;0;0~~$#2;2;0;0;100A"))
        #expect(image.width == 2)
        #expect(pixel(image, 0, 1) == [0, 0, 255, 255])
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 1, 1) == red)
    }

    @Test func newlineStartsNextBand() throws {
        let image = try #require(decode("#1;2;100;0;0@-@"))
        #expect(image.height == 12)
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 0, 6) == red)
        #expect(pixel(image, 0, 1) == clear)
    }

    @Test func trailingNewlineAddsNoRows() throws {
        let image = try #require(decode("#1;2;100;0;0@--"))
        #expect(image.height == 6)
    }

    @Test func redefinitionAffectsLaterPixelsOnly() throws {
        let image = try #require(decode("#1;2;100;0;0@#1;2;0;0;100@"))
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 1, 0) == [0, 0, 255, 255])
    }

    @Test func rgbScalesWithRounding() throws {
        let image = try #require(decode("#1;2;50;50;50@"))
        #expect(pixel(image, 0, 0) == [128, 128, 128, 255])
    }

    @Test func hlsPrimaries() throws {
        let cases: [(String, [UInt8])] = [
            ("#1;1;120;50;100@", [255, 0, 0, 255]),
            ("#1;1;240;50;100@", [0, 255, 0, 255]),
            ("#1;1;0;50;100@", [0, 0, 255, 255]),
            ("#1;1;0;100;0@", [255, 255, 255, 255]),
            ("#1;1;0;0;0@", [0, 0, 0, 255]),
        ]
        for (text, expected) in cases {
            let image = try #require(decode(text))
            #expect(pixel(image, 0, 0) == expected)
        }
    }

    @Test func defaultPaletteRegisters() throws {
        let image = try #require(decode("#2@#15@#200@"))
        #expect(pixel(image, 0, 0) == [204, 33, 33, 255])
        #expect(pixel(image, 1, 0) == [204, 204, 204, 255])
        #expect(pixel(image, 2, 0) == [0, 0, 0, 255])
    }

    @Test func registersWrapModulo256() throws {
        let image = try #require(decode("#257;2;100;0;0@#1@"))
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 1, 0) == red)
    }

    @Test func rasterAttributesSizeImage() throws {
        let image = try #require(decode("\"1;1;4;12#1;2;100;0;0@"))
        #expect(image.width == 4 && image.height == 12)
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 3, 11) == clear)
    }

    @Test func rasterAttributesFillWithBackground() throws {
        let image = try #require(decode("\"1;1;3;6#0;2;0;0;100#1;2;100;0;0@", params: [9, 0]))
        #expect(image.width == 3 && image.height == 6)
        #expect(pixel(image, 0, 0) == red)
        #expect(pixel(image, 1, 0) == [0, 0, 255, 255])
        #expect(pixel(image, 2, 5) == [0, 0, 255, 255])
    }

    @Test func backgroundSelectTwoAlsoFills() throws {
        let image = try #require(decode("\"1;1;2;6#1;2;100;0;0@", params: [9, 2]))
        #expect(pixel(image, 1, 3) == [0, 0, 0, 255])
    }

    @Test func backgroundSelectOneStaysTransparent() throws {
        let image = try #require(decode("\"1;1;2;6#1;2;100;0;0@", params: [9, 1]))
        #expect(pixel(image, 1, 3) == clear)
    }

    @Test func aspectRatioFromDCSParameter() throws {
        let doubled = try #require(decode("#1;2;100;0;0@", params: [5, 1]))
        #expect(doubled.height == 12)
        #expect(pixel(doubled, 0, 0) == red)
        #expect(pixel(doubled, 0, 1) == red)
        #expect(pixel(doubled, 0, 2) == clear)

        #expect(try #require(decode("@", params: [2, 1])).height == 30)
        #expect(try #require(decode("@", params: [3, 1])).height == 18)
        #expect(try #require(decode("@", params: [4, 1])).height == 18)
        #expect(try #require(decode("@", params: [6, 1])).height == 12)
        #expect(try #require(decode("@", params: [8, 1])).height == 6)
    }

    @Test func rasterAspectOverridesDCSParameter() throws {
        let image = try #require(decode("\"2;1;1;6#1;2;100;0;0@"))
        #expect(image.height == 12)
        #expect(pixel(image, 0, 1) == red)
    }

    @Test func repeatBombReturnsNil() {
        #expect(decode("#1;2;100;0;0!2000000000~") == nil)
        #expect(decode("!2000000000?") == nil)
    }

    @Test func hugeRasterReturnsNil() {
        #expect(decode("\"1;1;100000;100000@") == nil)
        #expect(decode("\"1;1;99999999999999999999;99999999999999999999@") == nil)
        #expect(decode("\"1;1;10000;10000@") == nil)
    }

    @Test func customLimitsApply() {
        let small = SixelLimits(maxWidth: 4, maxHeight: 12, maxBytes: 1 << 20)
        #expect(decode("!4~", limits: small) != nil)
        #expect(decode("!5~", limits: small) == nil)
        #expect(decode("~-~-~", limits: small) == nil)
        let tight = SixelLimits(maxWidth: 100, maxHeight: 100, maxBytes: 100)
        #expect(decode("!5~", limits: tight) == nil)
        #expect(decode("!4~", limits: tight) != nil)
    }

    @Test func aspectRepeatCountsTowardLimits() {
        let limits = SixelLimits(maxWidth: 100, maxHeight: 10, maxBytes: 1 << 20)
        #expect(decode("~", params: [5, 1], limits: limits) == nil)
        #expect(decode("~", params: [9, 1], limits: limits) != nil)
    }

    @Test func missingAspectParameterIsSquare() throws {
        for params in [[], [0], [1], [0, 1], [1, 1]] {
            #expect(try #require(decode("@", params: params)).height == 6)
        }
        #expect(try #require(decode("@", params: [5])).height == 12)
    }

    @Test func rasterAspectStillAppliesWithMissingParameter() throws {
        let image = try #require(decode("\"2;1;1;6#1;2;100;0;0@", params: []))
        #expect(image.height == 12)
    }

    @Test func sequenceParametersAndBodyAreParsed() throws {
        let sequence = Array("\u{1B}P5;1;0q#1;2;100;0;0@\u{1B}\\".utf8)
        let image = try #require(SixelDecoder.decode(sequence: sequence[...]))
        #expect(image.width == 1 && image.height == 12)
        #expect(pixel(image, 0, 0) == red)
        let bare = Array("\u{1B}Pq@\u{1B}\\".utf8)
        #expect(try #require(SixelDecoder.decode(sequence: bare[...])).height == 6)
        #expect(SixelDecoder.decode(sequence: Array("plain".utf8)[...]) == nil)
    }

    @Test func premultipliedPixelsScaleByAlpha() {
        let image = SixelImage(width: 2, height: 1, rgba: [200, 100, 50, 255, 200, 100, 50, 0])
        #expect(image.premultipliedRGBA == [200, 100, 50, 255, 0, 0, 0, 0])
        let half = SixelImage(width: 1, height: 1, rgba: [200, 100, 50, 128])
        #expect(half.premultipliedRGBA == [100, 50, 25, 128])
    }

    @Test func truncatedSequencesKeepWhatTheyHave() throws {
        let image = try #require(decode("#1;2;100;0;0~~~#2;2;1"))
        #expect(image.width == 3)
        #expect(pixel(image, 2, 5) == red)
        #expect(decode("#1;2;100;0;0!3") == nil)
        #expect(decode("") == nil)

        let partial = try #require(decode("#1;2;100~"))
        #expect(pixel(partial, 0, 0) == [51, 51, 204, 255])
    }

    @Test func whitespaceAndUnknownBytesAreIgnored() throws {
        let image = try #require(decode("#1;2;1\n00;0;\r0~\n \t~\u{1}\u{7}"))
        #expect(image.width == 2)
        #expect(pixel(image, 1, 0) == red)
    }

    @Test func generatedStreamsKeepBufferSizeConsistent() {
        var rng = SplitMix(state: 42)
        let limits = SixelLimits(maxWidth: 200, maxHeight: 200, maxBytes: 1 << 18)
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<Int.random(in: 1...40, using: &rng) {
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    text += "#\(Int.random(in: 0...300, using: &rng));\(Int.random(in: 1...2, using: &rng));\(Int.random(in: 0...360, using: &rng));\(Int.random(in: 0...100, using: &rng));\(Int.random(in: 0...100, using: &rng))"
                case 1: text += "#\(Int.random(in: 0...20, using: &rng))"
                case 2: text += "!\(Int.random(in: 1...30, using: &rng))"
                case 3: text += ["$", "-"].randomElement(using: &rng)!
                case 4: text += "\"\(Int.random(in: 1...3, using: &rng));1;\(Int.random(in: 0...50, using: &rng));\(Int.random(in: 0...50, using: &rng))"
                default: text += String(UnicodeScalar(UInt8.random(in: 0x3F...0x7E, using: &rng)))
                }
            }
            let params = [Int.random(in: 0...9, using: &rng), Int.random(in: 0...2, using: &rng), 0]
            if let image = decode(text, params: params, limits: limits) {
                #expect(image.width > 0 && image.height > 0)
                #expect(image.rgba.count == image.width * image.height * 4)
            }
        }
    }

    @Test func randomBytesNeverCrash() {
        var rng = SplitMix(state: 7)
        let limits = SixelLimits(maxWidth: 300, maxHeight: 300, maxBytes: 1 << 20)
        for _ in 0..<300 {
            let bytes = (0..<Int.random(in: 0...400, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if let image = SixelDecoder.decode(bytes, params: [Int.random(in: -5...12, using: &rng)], limits: limits) {
                #expect(image.rgba.count == image.width * image.height * 4)
            }
        }
    }
}
