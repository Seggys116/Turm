import Foundation
import Testing
@testable import TurmCore

struct SixelPrescanTests {
    private func sequence(_ body: String) -> ArraySlice<UInt8> {
        Array("\u{1B}Pq\(body)\u{1B}\\".utf8)[...]
    }

    @Test func ordinaryImagesPass() {
        #expect(SixelPrescan.admits(sequence("#0;2;0;0;0#1~~~~$#2??~-#1~~")))
        #expect(SixelPrescan.admits(sequence("\"1;1;8;12#1!8~")))
    }

    @Test func repeatCountsAreBounded() {
        #expect(SixelPrescan.admits(sequence("#1!10000~")))
        #expect(!SixelPrescan.admits(sequence("#1!10001~")))
        #expect(!SixelPrescan.admits(sequence("#1!999999999999999999999~")))
    }

    @Test func declaredRasterSizeIsBounded() {
        #expect(!SixelPrescan.admits(sequence("\"1;1;20000;10~")))
        #expect(!SixelPrescan.admits(sequence("\"1;1;10;20000~")))
        #expect(!SixelPrescan.admits(sequence("\"1;1;10000;10000~")))
    }

    @Test func tallImagesAreBoundedByBands() {
        let band = "~-"
        #expect(SixelPrescan.admits(sequence(String(repeating: band, count: 1000))))
        #expect(!SixelPrescan.admits(sequence(String(repeating: band, count: 1700))))
    }

    @Test func totalPixelsAreBounded() {
        #expect(SixelPrescan.admits(sequence("\"1;1;4096;4096~")))
        #expect(!SixelPrescan.admits(sequence("\"1;1;5000;5000~")))
    }

    @Test func absurdRegisterNumbersAreRefused() {
        #expect(SixelPrescan.admits(sequence("#255~")))
        #expect(!SixelPrescan.admits(sequence("#99999999999~")))
    }

    @Test func aTrailingBandBreakDoesNotCountAsHeight() {
        #expect(SixelPrescan.admits(sequence(String(repeating: "~-", count: 1666))))
    }

    @Test func arbitraryBytesNeverTrap() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        let alphabet: [UInt8] = Array("!\"#$-;0123456789~?@\u{1B}\\".utf8) + [0x9C, 0x00, 0xFF]
        for _ in 0..<500 {
            var body: [UInt8] = [0x1B, 0x50, 0x71]
            for _ in 0..<(next() % 200) { body.append(alphabet[next() % alphabet.count]) }
            _ = SixelPrescan.admits(body[...])
            _ = SixelPrescan.admits(body.dropFirst(2))
        }
    }
}

struct GraphicsAttributeTests {
    private func text(_ parameters: [Int]) -> String? {
        GraphicsAttributes.reply(for: parameters).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func colorRegistersReportTheirCount() {
        #expect(text([1, 1]) == "\u{1B}[?1;0;256S")
        #expect(text([1, 4]) == "\u{1B}[?1;0;256S")
        #expect(text([1, 2]) == "\u{1B}[?1;0;256S")
    }

    @Test func sixelGeometryReportsTheLimit() {
        #expect(text([2, 1]) == "\u{1B}[?2;0;10000;10000S")
    }

    @Test func regisIsNotSupported() {
        #expect(text([3, 1]) == "\u{1B}[?3;1;0S")
    }

    @Test func settingToAnythingElseFails() {
        #expect(text([1, 3, 16]) == "\u{1B}[?1;3;0S")
        #expect(text([1, 3, 256]) == "\u{1B}[?1;0;256S")
        #expect(text([2, 3, 20000, 20000]) == "\u{1B}[?2;3;0S")
    }

    @Test func unknownItemsAndActionsAreErrors() {
        #expect(text([9, 1]) == "\u{1B}[?9;1;0S")
        #expect(text([1, 7]) == "\u{1B}[?1;2;0S")
        #expect(text([1]) == nil)
    }

    @Test func theQueryIsTakenOutOfTheStream() {
        let split = TerminalGraphics.split(Array("a\u{1B}[?2;1;0Sb".utf8))
        #expect(split.remainder.isEmpty)
        #expect(split.pieces.count == 3)
        guard case .query(let reply) = split.pieces[1] else {
            Issue.record("the query was not separated")
            return
        }
        #expect(String(decoding: reply, as: UTF8.self) == "\u{1B}[?2;0;10000;10000S")
    }

    @Test func otherPrivateSequencesPassThrough() {
        let bytes = Array("\u{1B}[?25h\u{1B}[?2004l\u{1B}[S".utf8)
        let split = TerminalGraphics.split(bytes)
        #expect(split.pieces == [.bytes(bytes[...])])
    }

    @Test func aSplitQueryIsHeldUntilItCompletes() {
        let split = TerminalGraphics.split(Array("x\u{1B}[?2;1".utf8))
        #expect(split.pieces == [.bytes(Array("x".utf8)[...])])
        #expect(split.remainder == Array("\u{1B}[?2;1".utf8)[...])
    }
}

struct TerminatorTests {
    @Test func cancelDropsAnUnfinishedSixel() {
        let bytes = Array("a\u{1B}Pq#1~~\u{18}b".utf8)
        let split = TerminalGraphics.split(bytes)
        #expect(split.remainder.isEmpty)
        #expect(split.pieces == [.bytes(Array("a".utf8)[...]), .bytes(Array("b".utf8)[...])])
    }

    @Test func substituteDropsAnUnfinishedOSC() {
        let bytes = Array("a\u{1B}]1337;File=inline=1:AAAA\u{1A}b".utf8)
        let split = TerminalGraphics.split(bytes)
        #expect(split.remainder.isEmpty)
        #expect(split.pieces == [.bytes(Array("a".utf8)[...]), .bytes(Array("b".utf8)[...])])
    }

    @Test func c1StringTerminatorEndsASixel() {
        let bytes = Array("\u{1B}Pq#1~~".utf8) + [0x9C] + Array("z".utf8)
        let split = TerminalGraphics.split(bytes)
        #expect(split.remainder.isEmpty)
        #expect(split.pieces.count == 2)
    }

    @Test func aBellDoesNotEndADiscardedSixel() {
        var hold = GraphicHold()
        let long = [0x1B, 0x50, 0x71] + [UInt8](repeating: 0x7E, count: TerminalGraphics.byteLimit + 1)
        hold.hold(long[...])
        #expect(hold.intake(Array("~~\u{07}~~".utf8)) == nil)
        #expect(hold.intake(Array("~~\u{1B}\\after".utf8)) == Array("after".utf8))
    }

    @Test func aBellEndsADiscardedOSC() {
        var hold = GraphicHold()
        let long = [0x1B, 0x5D] + Array("1337;File=:".utf8) + [UInt8](repeating: 0x41, count: TerminalGraphics.byteLimit + 1)
        hold.hold(long[...])
        #expect(hold.intake(Array("AA\u{07}after".utf8)) == Array("after".utf8))
    }

    @Test func cancelEndsADiscardedSequence() {
        var hold = GraphicHold()
        let long = [0x1B, 0x50, 0x71] + [UInt8](repeating: 0x7E, count: TerminalGraphics.byteLimit + 1)
        hold.hold(long[...])
        #expect(hold.intake([0x7E, 0x18] + Array("ok".utf8)) == Array("ok".utf8))
    }
}

struct InlineFileKeyTests {
    private let cell = InlineGraphics.Cell(height: 17.5, width: 8, scale: 2)
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    @Test func doNotMoveCursorAndSizeAreParsed() {
        var session = InlineGraphicsSession()
        guard case .image(let placement) = session.receive(
            Array("File=inline=1;size=68;doNotMoveCursor=1:\(png)".utf8)[...], cell: cell
        ) else {
            Issue.record("inline file was not an image")
            return
        }
        #expect(!placement.moveCursor)
        #expect(placement.declaredSize == 68)
    }

    @Test func theCursorMovesByDefault() {
        var session = InlineGraphicsSession()
        guard case .image(let placement) = session.receive(Array("File=inline=1:\(png)".utf8)[...], cell: cell) else {
            Issue.record("inline file was not an image")
            return
        }
        #expect(placement.moveCursor)
        #expect(placement.declaredSize == nil)
    }

    @Test func multipartKeepsTheSameKeys() {
        var session = InlineGraphicsSession()
        _ = session.receive(Array("MultipartFile=inline=1;doNotMoveCursor=1;preserveAspectRatio=0".utf8)[...], cell: cell)
        _ = session.receive(Array("FilePart=\(png)".utf8)[...], cell: cell)
        guard case .image(let placement) = session.receive(Array("FileEnd".utf8)[...], cell: cell) else {
            Issue.record("completed multipart transfer was not an image")
            return
        }
        #expect(!placement.moveCursor)
        #expect(!placement.preserveAspectRatio)
    }
}

struct LinkPolicyTests {
    @Test func webAndMailLinksAreAlwaysAllowed() {
        for text in ["https://example.com", "http://example.com", "mailto:a@b.c", "ssh://host"] {
            let url = URL(string: text)!
            #expect(LinkPolicy.allows(url, remote: false))
            #expect(LinkPolicy.allows(url, remote: true))
        }
    }

    @Test func fileLinksAreLocalOnly() {
        let url = URL(string: "file:///etc/hosts")!
        #expect(LinkPolicy.allows(url, remote: false))
        #expect(!LinkPolicy.allows(url, remote: true))
    }

    @Test func otherSchemesAreRefused() {
        for text in ["javascript:alert(1)", "x-apple.systempreferences:", "tel:123", "data:text/plain,hi"] {
            #expect(!LinkPolicy.allows(URL(string: text)!, remote: false))
        }
    }
}

struct KittyFilePolicyTests {
    @Test func deviceAndProcessPathsAreNotReadable() {
        for path in ["/proc/self/mem", "/sys/kernel/x", "/dev/zero", "/dev"] {
            #expect(!KittyFilePolicy.mayRead(path))
        }
        #expect(!KittyFilePolicy.mayRead("relative/file"))
        #expect(KittyFilePolicy.mayRead("/tmp/example.png"))
    }

    @Test func onlyNamedFilesInTemporaryDirectoriesMayBeDeleted() {
        let temporary = NSTemporaryDirectory() + "tty-graphics-protocol-abc"
        #expect(KittyFilePolicy.mayDelete("/tmp/tty-graphics-protocol-abc"))
        #expect(KittyFilePolicy.mayDelete("/private/tmp/tty-graphics-protocol-abc"))
        #expect(KittyFilePolicy.mayDelete(temporary))
        #expect(!KittyFilePolicy.mayDelete("/tmp/other-file"))
        #expect(!KittyFilePolicy.mayDelete("/Users/someone/tty-graphics-protocol-abc"))
        #expect(!KittyFilePolicy.mayDelete("/etc/tty-graphics-protocol-abc"))
    }

    @Test func aSymlinkOutOfTheTemporaryDirectoryIsNotDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("tty-graphics-protocol-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        #expect(!KittyFilePolicy.mayDelete(link.path))
    }
}

struct GraphicsBoundsTests {
    @Test func sidesAndAreaAreBounded() {
        #expect(GraphicsBounds.admits(width: 4096, height: 4096))
        #expect(!GraphicsBounds.admits(width: 10_001, height: 1))
        #expect(!GraphicsBounds.admits(width: 10_000, height: 10_000))
        #expect(!GraphicsBounds.admits(width: 0, height: 5))
        #expect(!GraphicsBounds.admits(width: -1, height: 5))
    }

    @Test func imageHeadersAreChecked() {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        #expect(GraphicsBounds.admits(imageData: png))
        #expect(!GraphicsBounds.admits(imageData: Data([1, 2, 3])))
    }
}
