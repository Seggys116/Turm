import Foundation
import Testing
@testable import TurmCore

struct InlineGraphicsTests {
    private let cell = InlineGraphics.Cell(height: 17.5, width: 8, scale: 2)
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    @Test func reportsCellSizeAndCapabilities() {
        var session = InlineGraphicsSession()
        guard case .reply(let size) = session.receive(Array("ReportCellSize".utf8)[...], cell: cell) else {
            Issue.record("cell size query produced no reply")
            return
        }
        #expect(text(size) == "\u{1B}]1337;ReportCellSize=17.50;8.00;2.0\u{1B}\\")
        guard case .reply(let features) = session.receive(Array("Capabilities".utf8)[...], cell: cell) else {
            Issue.record("capability query produced no reply")
            return
        }
        let report = text(features)
        #expect(report.hasPrefix("\u{1B}]1337;Capabilities="))
        #expect(report.contains("Sx"))
        #expect(report.contains("F"))
        #expect(report.hasSuffix("\u{1B}\\"))
    }

    @Test func singleInlineImageKeepsTheRequestedSize() {
        var session = InlineGraphicsSession()
        guard case .image(let placement) = session.receive(Array("File=inline=1;width=4;height=2px:\(png)".utf8)[...], cell: cell) else {
            Issue.record("inline file was not an image")
            return
        }
        #expect(placement.width == .cells(4))
        #expect(placement.height == .pixels(2))
        #expect(!placement.data.isEmpty)
    }

    @Test func commandsComeOutOfTheByteStream() {
        let bytes = Array("ab\u{1B}]1337;ReportCellSize\u{07}cd\u{1B}]1337;FileEnd\u{1B}\\".utf8)
        let pieces = OSC1337.split(bytes)
        #expect(pieces.count == 4)
        guard case .command(let probe) = pieces[1], case .command(let end) = pieces[3] else {
            Issue.record("commands were not separated")
            return
        }
        #expect(String(decoding: probe, as: UTF8.self) == "ReportCellSize")
        #expect(String(decoding: end, as: UTF8.self) == "FileEnd")
    }

    @Test func sixelImagesAreSeparatedFromText() {
        let bytes = Array("go\u{1B}Pq#1~~\u{1B}\\next".utf8)
        let pieces = SixelSequence.split(bytes)
        #expect(pieces.count == 3)
        guard case .image(let image) = pieces[1] else {
            Issue.record("sixel was not separated")
            return
        }
        #expect(String(decoding: image, as: UTF8.self).hasPrefix("\u{1B}Pq"))
    }

    @Test func downloadsAreNotDisplayed() {
        var session = InlineGraphicsSession()
        #expect(session.receive(Array("File=name=YQ==:\(png)".utf8)[...], cell: cell) == nil)
    }

    @Test func multipartImageIsAssembledOnce() {
        var session = InlineGraphicsSession()
        let cut = png.index(png.startIndex, offsetBy: 16)
        #expect(session.receive(Array("MultipartFile=inline=1;width=3;height=10%".utf8)[...], cell: cell) == nil)
        #expect(session.receive(Array("FilePart=\(png[..<cut])".utf8)[...], cell: cell) == nil)
        #expect(session.receive(Array("FilePart=\(png[cut...])".utf8)[...], cell: cell) == nil)
        guard case .image(let placement) = session.receive(Array("FileEnd".utf8)[...], cell: cell) else {
            Issue.record("completed multipart transfer was not an image")
            return
        }
        #expect(placement.width == .cells(3))
        #expect(placement.height == .percent(10))
        #expect(placement.data == Data(base64Encoded: Data(png.utf8)))
        #expect(session.receive(Array("FileEnd".utf8)[...], cell: cell) == nil)
    }

    @Test func anUnfinishedImageIsReturnedSeparatelyFromTheTextBeforeIt() {
        let full = Array("go\u{1B}]1337;ReportCellSize\u{07}ok".utf8)
        let cut = full.firstIndex(of: UInt8(ascii: "R")) ?? 0
        let split = TerminalGraphics.split(Array(full[..<cut]))
        #expect(split.remainder.first == 0x1B)
        guard case .bytes(let text) = split.pieces.first else {
            Issue.record("text before the image was not kept")
            return
        }
        #expect(String(decoding: text, as: UTF8.self) == "go")
        let rest = TerminalGraphics.split(Array(split.remainder) + Array(full[cut...]))
        #expect(rest.remainder.isEmpty)
        #expect(rest.pieces.count == 2)
    }

    @Test func anUnfinishedSixelIsHeldBack() {
        let bytes = Array("\u{1B}Pq#1~~".utf8)
        let split = TerminalGraphics.split(bytes)
        #expect(split.pieces.isEmpty)
        #expect(split.remainder == bytes[...])
    }

    @Test func multipartDownloadIsDiscarded() {
        var session = InlineGraphicsSession()
        #expect(session.receive(Array("MultipartFile=size=4".utf8)[...], cell: cell) == nil)
        #expect(session.receive(Array("FilePart=\(png)".utf8)[...], cell: cell) == nil)
        #expect(session.receive(Array("FileEnd".utf8)[...], cell: cell) == nil)
    }
}
