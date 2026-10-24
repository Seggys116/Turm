import Foundation
import SwiftTerm
import Testing
@testable import Turm

struct GraphicalTTYTests {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func osc(_ body: String) -> [UInt8] {
        Array("\u{1B}]1337;\(body)\u{07}".utf8)
    }

    @Test func kittyQueryIsAnsweredAndStoresNothing() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        var replies: [String] = []
        emulator.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        emulator.feed(Array("\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\".utf8))
        emulator.feed(Array("\u{1B}_Ga=p,i=31\u{1B}\\".utf8))
        #expect(replies.contains { $0.contains("i=31;OK") })
        #expect(emulator.images.isEmpty)
    }

    @Test func kittyQueryReportsAMissingFile() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        var replies: [String] = []
        emulator.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        let path = Data("/no/such/turm-image".utf8).base64EncodedString()
        emulator.feed(Array("\u{1B}_Ga=q,i=9,t=f,f=100;\(path)\u{1B}\\".utf8))
        #expect(replies.contains { $0.contains("i=9;") && $0.contains("EBADF") })
        #expect(emulator.images.isEmpty)
    }

    @Test func itermMultipartImageOccupiesRowsBelowTheCursor() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let cut = png.index(png.startIndex, offsetBy: 20)
        emulator.feed(osc("MultipartFile=inline=1;width=4;height=2"))
        emulator.feed(osc("FilePart=\(png[..<cut])"))
        emulator.feed(osc("FilePart=\(png[cut...])"))
        emulator.feed(osc("FileEnd"))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].rowSpan >= 1)
        #expect(emulator.terminal.buffer.y >= emulator.images[0].rowSpan)
        #expect(emulator.terminal.buffer.x == 0)
    }

    @Test func itermReportsCellSizeAndGraphicsCapabilities() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        var replies: [String] = []
        emulator.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        emulator.feed(osc("ReportCellSize"))
        emulator.feed(osc("Capabilities"))
        #expect(replies.contains { $0.contains("ReportCellSize=") && $0.contains(";") })
        #expect(replies.contains { $0.contains("Capabilities=") && $0.contains("Sx") })
    }

    @Test func textAfterAnImageSplitAcrossReadsStartsBelowTheImage() {
        let emulator = BlockEmulator(cols: 40, rows: 12)
        let sequence = Array("\u{1B}]1337;File=inline=1;width=4;height=2:\(png)\u{07}after".utf8)
        let cut = sequence.count / 2
        emulator.feed(Array(sequence[..<cut]))
        #expect(emulator.images.isEmpty)
        emulator.feed(Array(sequence[cut...]))
        #expect(emulator.images.count == 1)
        let cursor = emulator.terminal.buffer.y
        #expect(cursor >= emulator.images[0].rowSpan)
        let line = emulator.terminal.getLine(row: cursor)?.translateToString(trimRight: true) ?? ""
        #expect(line.hasPrefix("after"))
    }

    @Test func aHugeFrameIsNotDecodedAsAnAnimation() {
        #expect(MotionPicture.framesToKeep(width: 10_000, height: 10_000, count: 240) == 0)
        #expect(MotionPicture.framesToKeep(width: 100, height: 100, count: 1_000) == 240)
    }

    @Test func sixelDrawsAtTheCursorAndClearRemovesIt() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(Array("\u{1B}Pq#1;2;100;0;0#1~~\u{1B}\\".utf8))
        #expect(emulator.images.count == 1)
        #expect(emulator.terminal.buffer.y >= 1)
        emulator.feed(Array("\u{1B}[2J".utf8))
        #expect(emulator.images.isEmpty)
    }
}
