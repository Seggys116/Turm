import AppKit
import Foundation
import Testing
@testable import Turm

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func numbered(_ range: Range<Int>) -> [UInt8] {
    Array(range.map { "\u{1B}[3\($0 % 7 + 1)mline \($0)\u{1B}[0m tail\r\n" }.joined().utf8)
}

private func texts(_ segments: [OutputSegment]) -> [OutputText] {
    segments.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
}

private func signature(_ segments: [OutputSegment]) -> [String] {
    segments.map { segment in
        switch segment {
        case .text(let text): "text:" + text.string
        case .stack(let stack): "stack:" + String(stack.text.characters)
        case .image: "image"
        }
    }
}

@MainActor
struct OutputChunkTests {
    @Test func settledChunksAreReusedWhileOutputStreams() {
        let emulator = BlockEmulator(cols: 80, rows: 24)
        emulator.feed(numbered(0..<1000))
        let before = texts(emulator.renderSegments()).first!.chunks
        emulator.feed(numbered(1000..<1010))
        let after = texts(emulator.renderSegments()).first!.chunks
        let settled = before.dropLast(2)
        #expect(!settled.isEmpty)
        for chunk in settled {
            #expect(after.contains { $0 === chunk })
        }
        #expect(after.last !== before.last)
    }

    @Test func chunksSplitOnRowBoundariesAndHangTheirSeparator() {
        let emulator = BlockEmulator(cols: 80, rows: 24)
        emulator.feed(numbered(0..<600))
        let text = texts(emulator.renderSegments()).first!
        #expect(text.chunks.count > 1)
        for chunk in text.chunks.dropLast() {
            #expect(chunk.hangs)
            #expect(chunk.string.hasSuffix("\n"))
            #expect(chunk.id % BlockEmulator.chunkRows == 0)
        }
        #expect(!text.chunks.last!.hangs)
        let expected = (0..<600).map { "line \($0) tail" }.joined(separator: "\n")
        #expect(text.string == expected)
        #expect(text.length == (expected as NSString).length)
    }

    @Test func wrappedLinesStayInOneChunk() {
        let emulator = BlockEmulator(cols: 20, rows: 10)
        let long = String(repeating: "abcdefghij", count: 7)
        var input = ""
        for index in 0..<300 { input += index % 5 == 0 ? long + "\r\n" : "short \(index)\r\n" }
        emulator.feed(Array(input.utf8))
        let text = texts(emulator.renderSegments()).first!
        for chunk in text.chunks.dropFirst() {
            let head = chunk.string.prefix { $0 != "\n" }
            #expect(head == long || head.hasPrefix("short "))
        }
        let lines = text.string.components(separatedBy: "\n")
        #expect(lines.count == 300)
        #expect(lines.filter { $0 == long }.count == 60)
    }

    @Test func incrementalRendersMatchAColdRender() {
        var generator = SplitMix64(state: 7)
        for trial in 0..<16 {
            let scrollback = trial.isMultiple(of: 2) ? 150 : BlockEmulator.scrollback
            let warm = BlockEmulator(cols: 40, rows: 12, scrollback: scrollback)
            let cold = BlockEmulator(cols: 40, rows: 12, scrollback: scrollback)
            for step in 0..<40 {
                var piece = ""
                for _ in 0..<Int.random(in: 1...60, using: &generator) {
                    let width = Int.random(in: 0...90, using: &generator)
                    piece += "\u{1B}[3\(width % 8)m" + String(repeating: "x", count: width) + "\u{1B}[0m \(trial)-\(step)\r\n"
                }
                switch Int.random(in: 0..<14, using: &generator) {
                case 0: piece += "\u{1B}[3J"
                case 1: piece += "\u{1B}[H\u{1B}[2J"
                case 2: piece += "\u{1B}c"
                case 3: piece += "\u{1B}[5A\u{1B}[2Kedited\u{1B}[5B"
                default: break
                }
                let bytes = Array(piece.utf8)
                let split = Int.random(in: 0...bytes.count, using: &generator)
                warm.feed(Array(bytes[..<split]))
                cold.feed(Array(bytes[..<split]))
                for _ in 0..<(Int.random(in: 0..<6, using: &generator) == 0 ? Int.random(in: 1...3, using: &generator) : 0) {
                    let cols = Int.random(in: 10...60, using: &generator)
                    let rows = Int.random(in: 4...20, using: &generator)
                    warm.resize(cols: cols, rows: rows)
                    cold.resize(cols: cols, rows: rows)
                }
                warm.feed(Array(bytes[split...]))
                cold.feed(Array(bytes[split...]))
                _ = warm.renderSegments()
            }
            let fresh = signature(cold.renderSegments())
            let seen = signature(warm.renderSegments())
            #expect(seen == fresh, "trial \(trial)")
        }
    }

    @Test func overflowingScrollbackKeepsRenderingTheTail() {
        let emulator = BlockEmulator(cols: 60, rows: 10, scrollback: 300)
        for start in stride(from: 0, to: 1000, by: 50) {
            emulator.feed(numbered(start..<(start + 50)))
            _ = emulator.renderSegments()
        }
        let text = texts(emulator.renderSegments()).first!.string
        #expect(text.hasSuffix("line 999 tail"))
        #expect(!text.contains("line 400 tail"))
        let cold = BlockEmulator(cols: 60, rows: 10, scrollback: 300)
        cold.feed(numbered(0..<1000))
        #expect(texts(cold.renderSegments()).first!.string == text)
    }

    @Test func fixedHeightsMatchTextKitLayout() {
        var generator = SplitMix64(state: 42)
        let alphabet = Array("ab cd-ef.gh/ij  ┌─┐│é")
        for _ in 0..<400 {
            var text = AttributedString()
            let lines = Int.random(in: 1...6, using: &generator)
            for line in 0..<lines {
                if line > 0 { text.append(AttributedString("\n")) }
                for _ in 0..<Int.random(in: 0...4, using: &generator) {
                    let run = String((0..<Int.random(in: 0...40, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
                    var container = AttributeContainer()
                    container[FontStyleKey.self] = Int.random(in: 0...3, using: &generator)
                    container.appKit.foregroundColor = .red
                    if Bool.random(using: &generator) { container.appKit.underlineStyle = .single }
                    text.append(AttributedString(run, attributes: container))
                }
            }
            let hangs = Bool.random(using: &generator)
            if hangs { text.append(AttributedString("\n")) }
            let chunk = TextChunk(text, hangs: hangs)
            let width = CGFloat(Int.random(in: 3...60, using: &generator)) * TerminalMetrics.cellWidth
                + CGFloat(Int.random(in: 0...3, using: &generator)) * TerminalMetrics.cellWidth / 4
            guard let fixed = chunk.fixedHeight(width: width) else { continue }
            let view = BlockTextNSView()
            view.setChunk(chunk)
            #expect(view.measuredSize(width: width).height == fixed, "\(chunk.string.debugDescription) at \(width)")
        }
    }

    @Test func irregularTextFallsBackToLayout() {
        #expect(TextChunk(AttributedString("")).fixedHeight(width: 400) == nil)
        #expect(TextChunk(AttributedString("emoji 😀")).fixedHeight(width: 400) == nil)
        #expect(TextChunk(AttributedString("e\u{301}")).fixedHeight(width: 400) == nil)
        #expect(TextChunk(AttributedString("tab\there")).fixedHeight(width: 400) == nil)
        #expect(TextChunk(AttributedString("plain")).fixedHeight(width: 400) == TerminalMetrics.lineHeight)
    }

    @Test func hangingSeparatorAddsNoHeight() {
        let view = BlockTextNSView()
        let chunk = TextChunk(AttributedString("🙂 one\ntwo\n"), hangs: true)
        view.setChunk(chunk)
        #expect(view.measuredSize(width: 400).height == 2 * TerminalMetrics.lineHeight)
    }

    @Test func highlightsAreSlicedPerChunk() {
        let highlights = SegmentHighlights(
            ranges: [NSRange(location: 2, length: 3), NSRange(location: 8, length: 6), NSRange(location: 20, length: 2)],
            active: NSRange(location: 8, length: 6)
        )
        let first = highlights.local(offset: 0, length: 10)
        #expect(first.ranges == [NSRange(location: 2, length: 3), NSRange(location: 8, length: 2)])
        #expect(first.active == NSRange(location: 8, length: 2))
        let second = highlights.local(offset: 10, length: 10)
        #expect(second.ranges == [NSRange(location: 0, length: 4)])
        #expect(second.active == NSRange(location: 0, length: 4))
        let third = highlights.local(offset: 20, length: 5)
        #expect(third.ranges == [NSRange(location: 0, length: 2)])
        #expect(third.active == nil)
    }

    @Test func selectionRangesAreSlicedPerChunk() {
        let piece = PieceRef(id: PieceID(blockID: UUID(), target: .segment(0)), host: BlockSelection())
        let selected = NSRange(location: 5, length: 20)
        #expect(piece.slice(slot: 0, offset: 0).local(selected, length: 10) == NSRange(location: 5, length: 5))
        #expect(piece.slice(slot: 128, offset: 10).local(selected, length: 10) == NSRange(location: 0, length: 10))
        #expect(piece.slice(slot: 256, offset: 20).local(selected, length: 10) == NSRange(location: 0, length: 5))
        #expect(piece.slice(slot: 384, offset: 30).local(selected, length: 10) == nil)
    }

    @Test func searchAndCopySeeTheWholeRun() {
        let emulator = BlockEmulator(cols: 80, rows: 24)
        emulator.feed(numbered(0..<400))
        let segments = emulator.renderSegments()
        let text = texts(segments).first!
        #expect(text.chunks.count > 2)
        #expect(segments.plainText == text.string)
        let boundary = text.starts[1]
        let spanning = (text.string as NSString).substring(with: NSRange(location: boundary - 9, length: 17))
        #expect(spanning.contains("\n"))
        let regex = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: spanning))
        #expect(SearchEngine.ranges(in: text.string, regex: regex).count == 1)
    }
}

@MainActor
struct PaneLayoutTests {
    @Test func singlePaneFillsTheArea() {
        let pane = PaneID()
        let layout = PaneLayout(node: .leaf(pane), size: CGSize(width: 300, height: 200))
        #expect(layout.panes == [PaneLayout.Pane(id: pane, frame: CGRect(x: 0, y: 0, width: 300, height: 200))])
        #expect(layout.dividers.isEmpty)
    }

    @Test func splitsTileTheAreaAroundTheirDivider() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        let node = PaneNode.leaf(a)
            .splitting(a, axis: .horizontal, inserting: b)
            .splitting(b, axis: .vertical, inserting: c)
        let layout = PaneLayout(node: node, size: CGSize(width: 401, height: 301))
        #expect(layout.panes.map(\.id) == [a, b, c])
        let frames = layout.panes.map(\.frame)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 200, height: 301))
        #expect(frames[1] == CGRect(x: 201, y: 0, width: 200, height: 150))
        #expect(frames[2] == CGRect(x: 201, y: 151, width: 200, height: 150))
        #expect(layout.dividers.count == 2)
        let outer = layout.dividers.first { $0.axis == .horizontal }!
        #expect(outer.frame == CGRect(x: 200, y: 0, width: 1, height: 301))
        let inner = layout.dividers.first { $0.axis == .vertical }!
        #expect(inner.frame == CGRect(x: 201, y: 150, width: 200, height: 1))
    }

    @Test func dividerRatioInvertsItsPosition() {
        let a = PaneID()
        let node = PaneNode.leaf(a).splitting(a, axis: .horizontal, inserting: PaneID())
        let layout = PaneLayout(node: node, size: CGSize(width: 501, height: 100))
        let divider = layout.dividers[0]
        #expect(abs(divider.ratio(at: CGPoint(x: divider.position, y: 10)) - 0.5) < 1e-9)
        #expect(abs(divider.ratio(at: CGPoint(x: 125, y: 10)) - 0.25) < 1e-9)
    }

    @Test func paneIdentityIsStableAcrossSplitsAndCloses() {
        let a = PaneID()
        let b = PaneID()
        let split = PaneNode.leaf(a).splitting(a, axis: .vertical, inserting: b)
        let size = CGSize(width: 300, height: 300)
        #expect(PaneLayout(node: split, size: size).panes.map(\.id) == [a, b])
        #expect(PaneLayout(node: split.removing(b)!, size: size).panes.map(\.id) == [a])
    }
}
