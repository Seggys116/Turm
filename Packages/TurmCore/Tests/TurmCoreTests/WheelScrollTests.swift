import Testing
@testable import TurmCore

struct WheelScrollTests {
    @Test func smallTranslationsAccumulateIntoWholeLines() {
        var scroll = WheelScroll()
        #expect(scroll.lines(translation: 6, cellHeight: 20) == 0)
        #expect(scroll.lines(translation: 6, cellHeight: 20) == 0)
        #expect(scroll.lines(translation: 10, cellHeight: 20) == 1)
        #expect(scroll.lines(translation: 5, cellHeight: 20) == 0)
    }

    @Test func largeTranslationYieldsSeveralLinesAndKeepsRemainder() {
        var scroll = WheelScroll()
        #expect(scroll.lines(translation: 50, cellHeight: 20) == 2)
        #expect(scroll.lines(translation: 10, cellHeight: 20) == 1)
    }

    @Test func negativeTranslationScrollsTheOtherWay() {
        var scroll = WheelScroll()
        #expect(scroll.lines(translation: -45, cellHeight: 20) == -2)
        #expect(scroll.lines(translation: -15, cellHeight: 20) == -1)
    }

    @Test func resetDropsTheRemainder() {
        var scroll = WheelScroll()
        _ = scroll.lines(translation: 15, cellHeight: 20)
        scroll.reset()
        #expect(scroll.lines(translation: 10, cellHeight: 20) == 0)
    }

    @Test(arguments: [0.0, -3.0])
    func invalidCellHeightProducesNothing(height: Double) {
        var scroll = WheelScroll()
        #expect(scroll.lines(translation: 100, cellHeight: height) == 0)
    }

    @Test func wheelButtons() {
        #expect(WheelScroll.wheelButton(lines: 3) == 64)
        #expect(WheelScroll.wheelButton(lines: -1) == 65)
    }

    @Test func arrowKeysRepeatPerLine() {
        #expect(WheelScroll.arrowKeys(lines: 2, applicationCursor: false) == Array("\u{1B}[A\u{1B}[A".utf8))
        #expect(WheelScroll.arrowKeys(lines: -3, applicationCursor: false) == Array("\u{1B}[B\u{1B}[B\u{1B}[B".utf8))
        #expect(WheelScroll.arrowKeys(lines: 1, applicationCursor: true) == Array("\u{1B}OA".utf8))
        #expect(WheelScroll.arrowKeys(lines: -1, applicationCursor: true) == Array("\u{1B}OB".utf8))
        #expect(WheelScroll.arrowKeys(lines: 0, applicationCursor: false).isEmpty)
    }
}
