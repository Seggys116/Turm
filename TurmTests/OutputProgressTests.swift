import Testing
@testable import Turm

struct OutputProgressTests {
    private func percent(after chunks: String...) -> Double? {
        var tracker = OutputProgress()
        for chunk in chunks { tracker.feed(Array(chunk.utf8)) }
        return tracker.percent
    }

    @Test func readsCarriageReturnRedraws() {
        #expect(percent(after: "Receiving objects:  12% (12/100)\r", "Receiving objects:  47% (47/100)\r") == 47)
    }

    @Test func keepsTheLineUntilNewTextOverwritesIt() {
        #expect(percent(after: " 30%|███       | 30/100\r") == 30)
    }

    @Test func readsDecimalsAndSpacedPercentSigns() {
        #expect(percent(after: "######## 45.3%") == 45.3)
        #expect(percent(after: "progress 80 %") == 80)
    }

    @Test func takesTheLastPercentOnTheLine() {
        #expect(percent(after: "step 1 100% done, step 2 25%") == 25)
    }

    @Test func ignoresEscapeSequencesAroundTheValue() {
        #expect(percent(after: "\u{1B}[2K\u{1B}[1G\u{1B}[32m 64%\u{1B}[0m \u{1B}]0;title\u{07}") == 64)
    }

    @Test func cursorToColumnOneActsLikeCarriageReturn() {
        #expect(percent(after: "download 10%", "\u{1B}[1Gunpacking") == nil)
    }

    @Test func aFinishedLineStaysUntilTextWithoutAPercentFollows() {
        #expect(percent(after: "Downloading 90%\n") == 90)
        #expect(percent(after: "Downloading 90%\n", "\n") == 90)
        #expect(percent(after: "Downloading 90%\n", "Installing\n") == nil)
    }

    @Test func rejectsValuesThatAreNotPercentages() {
        #expect(percent(after: "load 250%") == nil)
        #expect(percent(after: "printf %d") == nil)
        #expect(percent(after: "path/to/file%20name") == nil)
        #expect(percent(after: "x86%") == nil)
    }

    @Test func longLinesKeepOnlyTheLastFiveHundredTwelveBytes() {
        for tail in [0, 1, 100, 400, 507, 508, 509, 600, 1023, 1024, 1025, 5000] {
            let input = Array("a 12% ".utf8) + Array(repeating: UInt8(ascii: "b"), count: tail)
            var tracker = OutputProgress()
            for start in stride(from: 0, to: input.count, by: 97) {
                tracker.feed(input[start..<min(start + 97, input.count)])
            }
            #expect(tracker.percent == OutputProgress.percent(in: Array(input.suffix(512))))
        }
    }

    @Test func aLongLineStillEndsWithTheLatestPercent() {
        let input = Array(repeating: UInt8(ascii: "x"), count: 4000) + Array(" 73%".utf8)
        var tracker = OutputProgress()
        tracker.feed(input)
        #expect(tracker.percent == 73)
        tracker.feed(Array("\n".utf8))
        #expect(tracker.percent == 73)
    }

    @Test func combinesPanesWithLiveWorkFirst() {
        #expect(ShellActivity.combined([.succeeded, .progress(70), .progress(20)]) == .progress(20))
        #expect(ShellActivity.combined([.failed, .working]) == .working)
        #expect(ShellActivity.combined([.succeeded, .failed, .inactive]) == .failed)
        #expect(ShellActivity.combined([.inactive, .succeeded]) == .succeeded)
        #expect(ShellActivity.combined([.inactive]) == .inactive)
    }
}
