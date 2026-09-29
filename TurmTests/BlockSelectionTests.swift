import Foundation
import Testing
@testable import Turm

private func doc(_ command: String, _ parts: [String], id: UUID = UUID()) -> SearchDocument {
    SearchDocument(
        id: id,
        command: command,
        parts: parts.enumerated().map { SearchDocument.Part(index: $0.offset, text: $0.element) }
    )
}

private func point(_ id: UUID, _ target: SearchMatch.Target, _ offset: Int) -> SelectionPoint {
    SelectionPoint(piece: PieceID(blockID: id, target: target), offset: offset)
}

@MainActor
struct BlockSelectionTests {
    private let first = UUID()
    private let second = UUID()

    private func layout() -> SelectionLayout {
        SelectionLayout(documents: [
            doc("echo one", ["alpha beta", "gamma"], id: first),
            doc("ls -la", ["file-one.txt  \nfile_two"], id: second),
        ])
    }

    @Test func piecesFollowReadingOrder() {
        let ids = layout().pieces.map(\.id)
        #expect(ids == [
            PieceID(blockID: first, target: .command),
            PieceID(blockID: first, target: .segment(0)),
            PieceID(blockID: first, target: .segment(1)),
            PieceID(blockID: second, target: .command),
            PieceID(blockID: second, target: .segment(0)),
        ])
    }

    @Test func orderingIgnoresWhichEndIsTheAnchor() {
        let layout = layout()
        let early = point(first, .segment(0), 3)
        let late = point(second, .command, 2)
        #expect(layout.ordered(early, late) == (early, late))
        #expect(layout.ordered(late, early) == (early, late))
        #expect(layout.isBefore(early, late))
        #expect(!layout.isBefore(late, early))
        #expect(layout.isBefore(point(first, .command, 1), point(first, .command, 2)))
    }

    @Test func rangesSliceAcrossPieces() {
        let layout = layout()
        let anchor = point(first, .segment(0), 6)
        let focus = point(second, .command, 2)
        #expect(layout.range(of: PieceID(blockID: first, target: .command), anchor: anchor, focus: focus) == nil)
        #expect(layout.range(of: PieceID(blockID: first, target: .segment(0)), anchor: anchor, focus: focus) == NSRange(location: 6, length: 4))
        #expect(layout.range(of: PieceID(blockID: first, target: .segment(1)), anchor: anchor, focus: focus) == NSRange(location: 0, length: 5))
        #expect(layout.range(of: PieceID(blockID: second, target: .command), anchor: anchor, focus: focus) == NSRange(location: 0, length: 2))
        #expect(layout.range(of: PieceID(blockID: second, target: .segment(0)), anchor: anchor, focus: focus) == nil)
    }

    @Test func rangeInsideOnePieceIsTheSpanBetweenPoints() {
        let layout = layout()
        let range = layout.range(
            of: PieceID(blockID: first, target: .segment(0)),
            anchor: point(first, .segment(0), 8),
            focus: point(first, .segment(0), 2)
        )
        #expect(range == NSRange(location: 2, length: 6))
    }

    @Test func emptySelectionHasNoRanges() {
        let layout = layout()
        let spot = point(first, .segment(0), 4)
        #expect(layout.range(of: spot.piece, anchor: spot, focus: spot) == nil)
        #expect(layout.text(anchor: spot, focus: spot) == "")
    }

    @Test func copyTextIncludesCommandLinesAndSeparatesBlocksWithNewlines() {
        let layout = layout()
        let text = layout.text(anchor: point(first, .command, 5), focus: point(second, .command, 2))
        #expect(text == "one\nalpha beta\ngamma\nls")
    }

    @Test func copyTextTrimsTrailingSpacesAndBlankTails() {
        let layout = layout()
        let text = layout.text(anchor: point(second, .segment(0), 0), focus: point(second, .segment(0), 24))
        #expect(text == "file-one.txt\nfile_two")
    }

    @Test func selectingBackwardsCopiesTheSameText() {
        let layout = layout()
        let a = point(first, .command, 5)
        let b = point(second, .command, 2)
        #expect(layout.text(anchor: b, focus: a) == layout.text(anchor: a, focus: b))
    }

    @Test func selectAllCoversEveryPiece() {
        let layout = layout()
        guard let all = layout.everything() else {
            Issue.record("expected a selection")
            return
        }
        #expect(all.anchor == point(first, .command, 0))
        #expect(all.focus == point(second, .segment(0), 23))
        #expect(layout.text(anchor: all.anchor, focus: all.focus) == "echo one\nalpha beta\ngamma\nls -la\nfile-one.txt\nfile_two")
    }

    @Test func selectAllOfNothingIsNil() {
        #expect(SelectionLayout(pieces: []).everything() == nil)
    }

    @Test func wordGranularitySelectsTheWordUnderThePoint() {
        let layout = layout()
        let unit = layout.unit(at: point(first, .segment(0), 7), granularity: .word)
        #expect(unit.start.offset == 6 && unit.end.offset == 10)
        let path = layout.unit(at: point(second, .segment(0), 3), granularity: .word)
        #expect(path.start.offset == 0 && path.end.offset == 12)
    }

    @Test func wordGranularityOnWhitespaceSelectsTheRun() {
        let layout = layout()
        let unit = layout.unit(at: point(first, .segment(0), 5), granularity: .word)
        #expect(unit.start.offset == 5 && unit.end.offset == 6)
    }

    @Test func lineGranularitySelectsTheWholeRow() {
        let layout = layout()
        let unit = layout.unit(at: point(second, .segment(0), 18), granularity: .line)
        #expect(unit.start.offset == 15 && unit.end.offset == 23)
        let single = layout.unit(at: point(first, .command, 2), granularity: .line)
        #expect(single.start.offset == 0 && single.end.offset == 8)
    }

    @Test func characterGranularityIsAPoint() {
        let layout = layout()
        let spot = point(first, .command, 3)
        #expect(layout.unit(at: spot, granularity: .character) == SelectionUnit(start: spot, end: spot))
    }

    @Test func clickCountsMapToGranularity() {
        #expect(SelectionGranularity(clicks: 1) == .character)
        #expect(SelectionGranularity(clicks: 2) == .word)
        #expect(SelectionGranularity(clicks: 3) == .line)
        #expect(SelectionGranularity(clicks: 5) == .line)
    }

    @Test func draggingByWordKeepsTheAnchorWordSelected() {
        let layout = layout()
        let anchor = layout.unit(at: point(first, .segment(0), 7), granularity: .word)
        let forward = layout.extend(from: anchor, to: point(first, .segment(1), 2), granularity: .word)
        #expect(forward.anchor == point(first, .segment(0), 6))
        #expect(forward.focus == point(first, .segment(1), 5))
        let backward = layout.extend(from: anchor, to: point(first, .segment(0), 1), granularity: .word)
        #expect(backward.anchor == point(first, .segment(0), 10))
        #expect(backward.focus == point(first, .segment(0), 0))
    }

    @Test func unknownPiecesAreNotSelectable() {
        let layout = layout()
        let stranger = point(UUID(), .command, 0)
        #expect(layout.range(of: stranger.piece, anchor: point(first, .command, 0), focus: point(second, .command, 1)) == nil)
        #expect(layout.text(anchor: stranger, focus: stranger) == "")
    }

    @Test func tidyTrimsTrailingSpacesPerLineAndBlankTails() {
        #expect(SelectionLayout.tidy("a  \n\tb \t\n\n") == "a\n\tb")
        #expect(SelectionLayout.tidy("caf\u{E9}  ") == "caf\u{E9}")
        #expect(SelectionLayout.tidy("\n\n") == "")
        #expect(SelectionLayout.tidy("") == "")
    }

    @Test func largeSelectionsAssembleEveryLineInOrder() {
        let documents = (0..<5000).map { doc("cmd \($0)", ["line \($0)   "]) }
        let layout = SelectionLayout(documents: documents)
        guard let all = layout.everything() else {
            Issue.record("expected a selection")
            return
        }
        let lines = layout.text(anchor: all.anchor, focus: all.focus).components(separatedBy: "\n")
        #expect(lines.count == 10_000)
        #expect(lines.first == "cmd 0")
        #expect(lines.last == "line 4999")
        #expect(lines[2501] == "line 1250")
    }

    @Test func partialSelectionOnlyTouchesItsOwnPieces() {
        let documents = (0..<1000).map { doc("cmd \($0)", ["out \($0)"]) }
        let layout = SelectionLayout(documents: documents)
        let text = layout.text(
            anchor: point(documents[500].id, .command, 4),
            focus: point(documents[502].id, .command, 3)
        )
        #expect(text == "500\nout 500\ncmd 501\nout 501\ncmd")
    }

    @Test func imagesAreNotPieces() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let image = "\u{1B}_Ga=T,f=24,s=1,v=1,i=1,c=3,r=2;AAAA\u{1B}\\"
        emulator.feed(Array((image + "after image").utf8))
        let block = Block(command: "show", directory: "/tmp", git: nil, emulator: emulator)
        block.refreshOutput()
        let layout = SelectionLayout(documents: [SearchDocument(block: block)])
        let imageCount = block.segments.filter { if case .image = $0 { return true } else { return false } }.count
        #expect(imageCount == 1)
        #expect(layout.pieces.count == 1 + block.segments.count - imageCount)
        let all = layout.everything()
        #expect(all.map { layout.text(anchor: $0.anchor, focus: $0.focus) }?.hasPrefix("show\n") == true)
    }
}
