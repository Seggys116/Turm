import AppKit
import Foundation
import SwiftTerm
import Testing
import TurmCore
@testable import Turm

struct KittyInflateSizeTests {
    private func stored(_ payload: [UInt8]) -> Data {
        let length = payload.count
        var stream: [UInt8] = [0x78, 0x01, 0x01, UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)]
        stream += payload
        let checksum = KittyInflate.adler32(payload)
        stream += [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)]
        return Data(stream)
    }

    @Test func unknownSizeStreamEndsWhereTheStreamEnds() {
        guard case .success(let data) = KittyInflate.inflate(stored([1, 2, 3, 4]), capacity: 1000, exact: false) else {
            Issue.record("a stream of unknown size should inflate")
            return
        }
        #expect([UInt8](data) == [1, 2, 3, 4])
    }

    @Test func knownSizeStreamStillMustMatch() {
        if case .success = KittyInflate.inflate(stored([1, 2, 3, 4]), capacity: 1000) {
            Issue.record("a short stream should not satisfy a larger expected size")
        }
    }

    @Test func unknownSizeStreamIsStillBounded() {
        if case .success = KittyInflate.inflate(stored([1, 2, 3, 4]), capacity: 2, exact: false) {
            Issue.record("output past the capacity should fail")
        }
    }
}

struct BlockEmulatorGraphicsGuardTests {
    private func replies(for bytes: [UInt8]) -> (emulator: BlockEmulator, text: () -> String) {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        var collected: [UInt8] = []
        emulator.onResponse = { collected.append(contentsOf: $0) }
        emulator.feed(bytes)
        return (emulator, { String(decoding: collected, as: UTF8.self) })
    }

    @Test func graphicsAttributeQueryIsAnsweredAndNeverScrolls() {
        let (emulator, answer) = replies(for: Array("one\r\ntwo\u{1B}[?2;1;0Sx".utf8))
        #expect(answer() == "\u{1B}[?2;0;10000;10000S")
        let text = String(emulator.render().characters)
        #expect(text.contains("one"))
        #expect(text.contains("two"))
    }

    @Test func oversizedSixelIsDroppedAndTextAroundItSurvives() {
        let (emulator, _) = replies(for: Array("a\u{1B}Pq\"1;1;20000;20000#0!9999999~\u{1B}\\b".utf8))
        let text = String(emulator.render().characters)
        #expect(text.contains("a"))
        #expect(text.contains("b"))
        #expect(emulator.images.isEmpty)
    }

    @Test func smallSixelBecomesAnImageOfItsOwnSize() {
        let (emulator, _) = replies(for: Array("a\u{1B}Pq\"1;1;4;12#1;2;100;0;0!4~\u{1B}\\b".utf8))
        #expect(emulator.images.count == 1)
        #expect(emulator.images.first?.pixelSize == CGSize(width: 4, height: 12))
        let text = String(emulator.render().characters)
        #expect(text.contains("a"))
        #expect(text.contains("b"))
    }

    @Test func sixelWithoutAspectParameterIsNotDoubled() {
        let (emulator, _) = replies(for: Array("\u{1B}Pq#1;2;100;0;0!3~\u{1B}\\".utf8))
        #expect(emulator.images.first?.pixelSize == CGSize(width: 3, height: 6))
    }

    @Test func sixelMovesTheCursorPastTheImage() {
        let plain = BlockEmulator(cols: 40, rows: 10)
        plain.feed(Array("x".utf8))
        let drawn = BlockEmulator(cols: 40, rows: 10)
        drawn.feed(Array("\u{1B}Pq\"1;1;4;60#1;2;100;0;0!4~\u{1B}\\".utf8))
        #expect(drawn.terminal.buffer.y > plain.terminal.buffer.y)
    }

    @Test func preserveAspectRatioIsKeptOnTheRecordedImage() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(Array("\u{1B}]1337;File=inline=1;preserveAspectRatio=0;width=4;height=2:\(png)\u{07}".utf8))
        #expect(emulator.images.count == 1)
        #expect(emulator.images.first?.preserveAspectRatio == false)
    }

    @Test func percentSizesUseTheWidthOfThePane() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(Array("\u{1B}]1337;File=inline=1;width=50%:\(png)\u{07}".utf8))
        guard let image = emulator.images.first else {
            Issue.record("the image was not recorded")
            return
        }
        let size = image.requestedSize(cellWidth: TerminalMetrics.cellWidth, lineHeight: TerminalMetrics.lineHeight)
        #expect(abs(size.width - 20 * TerminalMetrics.cellWidth) < 0.01)
    }

    @Test func doNotMoveCursorKeepsTheCursorWhereItWas() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let moved = BlockEmulator(cols: 40, rows: 10)
        moved.feed(Array("\u{1B}]1337;File=inline=1;height=3:\(png)\u{07}".utf8))
        let still = BlockEmulator(cols: 40, rows: 10)
        still.feed(Array("\u{1B}]1337;File=inline=1;height=3;doNotMoveCursor=1:\(png)\u{07}".utf8))
        #expect(moved.terminal.buffer.y > still.terminal.buffer.y)
    }
}
