import Foundation
import Testing
@testable import TurmCore

struct StyledOutputTests {
    private let esc = "\u{1B}["

    private func encoded(_ lines: [StyledLine]) -> String {
        String(decoding: StyledOutput.encode(lines), as: UTF8.self)
    }

    private func line(_ runs: (String, TextStyle)...) -> StyledLine {
        StyledLine(runs: runs.map { StyledRun(text: $0.0, style: $0.1) })
    }

    @Test func plainTextCarriesNoEscapes() {
        #expect(encoded([line(("hello", .plain))]) == "hello")
    }

    @Test func standardColoursUseTheShortCodes() {
        let red = TextStyle(foreground: .indexed(1))
        #expect(encoded([line(("red", red))]) == "\(esc)31mred\(esc)0m")
        let brightOnBlue = TextStyle(foreground: .indexed(9), background: .indexed(4))
        #expect(encoded([line(("x", brightOnBlue))]) == "\(esc)91;44mx\(esc)0m")
    }

    @Test func extendedColoursUseTheIndexedAndTruecolourForms() {
        let indexed = TextStyle(foreground: .indexed(202), background: .indexed(236))
        #expect(encoded([line(("a", indexed))]) == "\(esc)38;5;202;48;5;236ma\(esc)0m")
        let rgb = TextStyle(foreground: .rgb(1, 2, 3), background: .rgb(255, 128, 0))
        #expect(encoded([line(("b", rgb))]) == "\(esc)38;2;1;2;3;48;2;255;128;0mb\(esc)0m")
    }

    @Test func attributesEncodeInSGROrder() {
        let all = TextStyle(bold: true, dim: true, italic: true, underline: true, blink: true, inverse: true, hidden: true, strikethrough: true)
        #expect(encoded([line(("z", all))]) == "\(esc)1;2;3;4;5;7;8;9mz\(esc)0m")
    }

    @Test func changingStyleResetsFirstAndReturningToPlainResets() {
        let bold = TextStyle(bold: true)
        let green = TextStyle(foreground: .indexed(2))
        let text = encoded([line(("a", .plain), ("b", bold), ("c", green), ("d", .plain))])
        #expect(text == "a\(esc)1mb\(esc)0;32mc\(esc)0md")
    }

    @Test func everyRowEndsInTheDefaultStyleAndRowsJoinWithCRLF() {
        let red = TextStyle(foreground: .indexed(1))
        let text = encoded([line(("a", red)), line(("b", .plain))])
        #expect(text == "\(esc)31ma\(esc)0m\r\nb")
    }

    @Test func wrappedRowsContinueTheRowBefore() {
        let rows = [line(("abc", .plain)), StyledLine(runs: [StyledRun(text: "def", style: .plain)], wrapped: true), line(("g", .plain))]
        #expect(encoded(rows) == "abcdef\r\ng")
    }

    @Test func emptyRowsKeepTheirLineBreaks() {
        #expect(encoded([line(("a", .plain)), StyledLine(runs: []), line(("b", .plain))]) == "a\r\n\r\nb")
    }
}
