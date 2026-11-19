import Foundation
import Testing

@testable import TurmCore

struct DCSRequestPassThroughTests {
    private static let requests = [
        "\u{1B}P$qm\u{1B}\\", "\u{1B}P$q q\u{1B}\\", "\u{1B}P$qr\u{1B}\\", "\u{1B}P$q\"p\u{1B}\\", "\u{1B}P+q544E\u{1B}\\",
    ]

    @Test func requestStatusAndTermcapQueriesAreNotTakenForSixel() {
        for request in Self.requests {
            let bytes = Array(("a" + request + "b").utf8)
            let split = TerminalGraphics.split(bytes)
            #expect(split.remainder.isEmpty, "\(request.debugDescription)")
            #expect(split.pieces == [.bytes(bytes[...])], "\(request.debugDescription)")
            #expect(SixelSequence.split(bytes).count == 1, "\(request.debugDescription)")
            var hold = GraphicHold()
            #expect(hold.intake(Array(request.utf8.dropLast(2))) == Array(request.utf8.dropLast(2)), "\(request.debugDescription)")
        }
    }

    @Test func sixelWithParametersIsStillRecognised() {
        let sixel = Array("\u{1B}P0;1;0q\"1;1;1;1#0;2;100;0;0#0~\u{1B}\\".utf8)
        let split = TerminalGraphics.split(Array("a".utf8) + sixel)
        #expect(split.pieces == [.bytes(Array("a".utf8)[...]), .sixel(sixel[...])])
    }
}
