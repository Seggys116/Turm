import Foundation
import Testing
@testable import Turm

@MainActor
struct OutputCursorTests {
    private func emulator(_ output: String, cols: Int = 20) -> (BlockEmulator, [OutputSegment]) {
        let emulator = BlockEmulator(cols: cols, rows: 10)
        emulator.tracksCursor = true
        emulator.feed(Array(output.utf8))
        return (emulator, emulator.renderSegments())
    }

    private func text(_ segments: [OutputSegment]) -> String {
        segments.compactMap { if case .text(let text) = $0 { text.string } else { nil } }.joined()
    }

    @Test func cursorSitsAfterAPrompt() throws {
        let (emulator, _) = emulator("Password: ")
        let cursor = try #require(emulator.cursor)
        #expect(cursor.line == 0)
        #expect(cursor.cell == 10)
        #expect(cursor.offset == nil)
        #expect(cursor.shape == .block)
        #expect(cursor.blinks)
    }

    @Test func emptyCursorLineIsKeptOnlyWhileTracking() {
        let (emulator, segments) = emulator("done\r\n")
        #expect(text(segments) == "done\n")
        #expect(emulator.cursor?.line == 1)
        #expect(emulator.cursor?.cell == 0)
        emulator.tracksCursor = false
        #expect(text(emulator.renderSegments()) == "done")
        #expect(emulator.cursor == nil)
    }

    @Test func cursorOverTextPointsAtTheCharacter() {
        let (emulator, _) = emulator("héllo\u{1B}[3D")
        #expect(emulator.cursor?.cell == 2)
        #expect(emulator.cursor?.offset == 2)
    }

    @Test func softWrappedRowsShareOneLine() {
        let (emulator, _) = emulator(String(repeating: "x", count: 25), cols: 20)
        #expect(emulator.cursor?.line == 0)
        #expect(emulator.cursor?.cell == 25)
    }

    @Test func programsCanHideAndRestyleTheCursor() {
        let (emulator, _) = emulator("\u{1B}[?25lloading")
        #expect(emulator.cursor == nil)
        emulator.feed(Array("\u{1B}[?25h\u{1B}[6 q".utf8))
        _ = emulator.renderSegments()
        #expect(emulator.cursor?.shape == .bar)
        #expect(emulator.cursor?.blinks == false)
    }

    @Test func alternateScreenHasNoBlockCursor() {
        let (emulator, _) = emulator("\u{1B}[?1049hfull screen")
        #expect(emulator.cursor == nil)
    }
}
