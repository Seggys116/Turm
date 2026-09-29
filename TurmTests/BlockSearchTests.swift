import Foundation
import Testing
@testable import Turm

private func document(_ command: String, _ parts: [String], id: UUID = UUID()) -> SearchDocument {
    SearchDocument(
        id: id,
        command: command,
        parts: parts.enumerated().map { SearchDocument.Part(index: $0.offset, text: $0.element) }
    )
}

private func found(_ query: String, in documents: [SearchDocument], _ options: SearchOptions = SearchOptions()) -> [SearchMatch] {
    guard case .matches(let matches, _) = SearchEngine.find(query: query, options: options, in: documents) else { return [] }
    return matches
}

private func substrings(_ matches: [SearchMatch], in text: String) -> [String] {
    matches.map { (text as NSString).substring(with: $0.range) }
}

@MainActor
struct BlockSearchTests {
    @Test func plainSearchIsCaseInsensitiveByDefault() {
        let text = "Hello hello HELLO"
        let matches = found("hello", in: [document("", [text])])
        #expect(matches.count == 3)
        #expect(matches.map(\.range.location) == [0, 6, 12])
    }

    @Test func caseSensitiveOnlyMatchesExactCase() {
        let text = "Hello hello HELLO"
        let matches = found("hello", in: [document("", [text])], SearchOptions(caseSensitive: true))
        #expect(matches.map(\.range.location) == [6])
    }

    @Test func plainQueryTreatsRegexCharactersLiterally() {
        let matches = found("a.b", in: [document("", ["a.b axb a+b"])])
        #expect(matches.count == 1)
        #expect(matches[0].range == NSRange(location: 0, length: 3))
    }

    @Test func wholeWordSkipsSubstrings() {
        let text = "cat concat cat. cats"
        let matches = found("cat", in: [document("", [text])], SearchOptions(wholeWord: true))
        #expect(matches.map(\.range.location) == [0, 11])
    }

    @Test func wholeWordWorksForQueriesStartingWithSymbols() {
        let matches = found("-v", in: [document("", ["run -v now -verbose"])], SearchOptions(wholeWord: true))
        #expect(matches.map(\.range.location) == [4])
    }

    @Test func regexMatchesPattern() {
        let text = "error 12, warn 7, error 305"
        let matches = found("error \\d+", in: [document("", [text])], SearchOptions(useRegex: true))
        #expect(substrings(matches, in: text) == ["error 12", "error 305"])
    }

    @Test func regexAnchorsApplyPerLine() {
        let text = "one\ntwo\nthree"
        let matches = found("^t", in: [document("", [text])], SearchOptions(useRegex: true))
        #expect(matches.map(\.range.location) == [4, 8])
    }

    @Test func invalidRegexReportsFailure() {
        let outcome = SearchEngine.find(query: "(unclosed", options: SearchOptions(useRegex: true), in: [document("", ["(unclosed"])])
        guard case .invalid(let message) = outcome else {
            Issue.record("expected an invalid outcome")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func emptyQueryFindsNothing() {
        #expect(found("", in: [document("cmd", ["text"])]).isEmpty)
    }

    @Test func matchesDoNotOverlap() {
        let matches = found("aa", in: [document("", ["aaaaa"])])
        #expect(matches.map(\.range.location) == [0, 2])
    }

    @Test func zeroLengthRegexMatchesAreIgnored() {
        let matches = found("x*", in: [document("", ["abc"])], SearchOptions(useRegex: true))
        #expect(matches.isEmpty)
    }

    @Test func unicodeRangesUseUTF16Offsets() {
        let text = "caf\u{E9} na\u{EF}ve \u{4E2D}\u{6587} caf\u{E9}"
        let matches = found("caf\u{E9}", in: [document("", [text])])
        #expect(matches.count == 2)
        #expect(substrings(matches, in: text) == ["caf\u{E9}", "caf\u{E9}"])
        #expect(matches[1].range.location == (text as NSString).length - 4)
    }

    @Test func cjkTextIsSearchable() {
        let text = "\u{4E2D}\u{6587}\u{6D4B}\u{8BD5} \u{4E2D}\u{6587}"
        let matches = found("\u{4E2D}\u{6587}", in: [document("", [text])])
        #expect(matches.map(\.range.location) == [0, 5])
    }

    @Test func matchesMapToBlockAndSegment() {
        let first = UUID()
        let second = UUID()
        let documents = [
            document("echo needle", ["nothing", "a needle here"], id: first),
            document("ls", ["needle"], id: second),
        ]
        let matches = found("needle", in: documents)
        #expect(matches.count == 3)
        #expect(matches[0].blockID == first)
        #expect(matches[0].target == .command)
        #expect(matches[0].range == NSRange(location: 5, length: 6))
        #expect(matches[1].blockID == first)
        #expect(matches[1].target == .segment(1))
        #expect(matches[1].range == NSRange(location: 2, length: 6))
        #expect(matches[2].blockID == second)
        #expect(matches[2].target == .segment(0))
    }

    @Test func segmentIndicesFollowPartIndices() {
        let id = UUID()
        let doc = SearchDocument(id: id, command: "", parts: [SearchDocument.Part(index: 2, text: "hit")])
        let matches = found("hit", in: [doc])
        #expect(matches.first?.target == .segment(2))
    }

    @Test func positionGrowsThroughTheBlock() {
        let doc = document("cmd", ["mark", String(repeating: "x", count: 100), "mark"])
        let matches = found("mark", in: [doc])
        #expect(matches.count == 2)
        #expect(matches[0].position < matches[1].position)
        #expect(matches[1].position < 1)
    }

    @Test func navigationWrapsAround() {
        let search = BlockSearch()
        let id = UUID()
        search.isPresented = true
        search.apply(SearchEngine.find(query: "a", options: SearchOptions(), in: [document("", ["a a a"], id: id)]), reveal: true)
        #expect(search.matchCount == 3)
        #expect(search.activeIndex == 2)
        search.next()
        #expect(search.activeIndex == 0)
        search.previous()
        #expect(search.activeIndex == 2)
        search.previous()
        #expect(search.activeIndex == 1)
    }

    @Test func navigationRequestsScrollToTheActiveBlock() {
        let search = BlockSearch()
        let first = UUID()
        let second = UUID()
        search.isPresented = true
        let documents = [document("", ["hit"], id: first), document("", ["hit"], id: second)]
        search.apply(SearchEngine.find(query: "hit", options: SearchOptions(), in: documents), reveal: true)
        #expect(search.scrollRequest?.blockID == second)
        search.next()
        #expect(search.scrollRequest?.blockID == first)
    }

    @Test func refreshAgainstSourceBuildsMatches() async {
        let search = BlockSearch()
        let id = UUID()
        search.source = { [document("run", ["one two one"], id: id)] }
        search.isPresented = true
        search.query = "one"
        await search.refresh(reveal: true)
        #expect(search.matchCount == 2)
        #expect(search.activeMatch?.blockID == id)
        #expect(search.invalidPattern == nil)
    }

    @Test func invalidRegexClearsMatchesAndSetsMessage() async {
        let search = BlockSearch()
        search.source = { [document("", ["text"])] }
        search.isPresented = true
        search.useRegex = true
        search.query = "["
        await search.refresh(reveal: true)
        #expect(search.matchCount == 0)
        #expect(search.invalidPattern != nil)
    }

    @Test func contentUpdateKeepsActiveMatch() {
        let search = BlockSearch()
        let id = UUID()
        search.isPresented = true
        search.apply(SearchEngine.find(query: "a", options: SearchOptions(), in: [document("", ["a a a"], id: id)]), reveal: true)
        search.previous()
        let before = search.activeMatch
        search.apply(SearchEngine.find(query: "a", options: SearchOptions(), in: [document("", ["a a a a"], id: id)]), reveal: false)
        #expect(search.matchCount == 4)
        #expect(search.activeMatch.map { before?.sameSpot(as: $0) } == true)
    }

    @Test func closingClearsResults() {
        let search = BlockSearch()
        search.isPresented = true
        search.apply(SearchEngine.find(query: "a", options: SearchOptions(), in: [document("", ["a"])]), reveal: true)
        search.close()
        #expect(search.matchCount == 0)
        #expect(!search.isPresented)
        #expect(search.activeMatch == nil)
    }

    @Test func useSelectionTakesFirstLineAndDisablesRegex() {
        let search = BlockSearch()
        search.useRegex = true
        search.useSelection("first line\nsecond")
        #expect(search.query == "first line")
        #expect(!search.useRegex)
        #expect(search.isPresented)
    }

    private func stackBlock() -> Block {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let image = "\u{1B}_Ga=T,f=24,s=1,v=1,i=1,c=3,r=2,C=1;AAAA\u{1B}\\"
        emulator.feed(Array((image + "needle over image").utf8))
        let block = Block(command: "show", directory: "/tmp", git: nil, emulator: emulator)
        block.refreshOutput()
        return block
    }

    @Test func stackTextIsIncludedInDocuments() {
        let block = stackBlock()
        guard let index = block.segments.firstIndex(where: { if case .stack = $0 { return true } else { return false } }) else {
            Issue.record("expected a stack segment")
            return
        }
        let doc = SearchDocument(block: block)
        #expect(doc.parts.contains { $0.index == index && $0.text.contains("needle over image") })
    }

    @Test func stackMatchesMapToTheStackSegmentIndex() {
        let block = stackBlock()
        let doc = SearchDocument(block: block)
        let matches = found("needle", in: [doc])
        #expect(matches.count == 1)
        guard case .segment(let index) = matches[0].target, case .stack = block.segments[index] else {
            Issue.record("match should target the stack segment")
            return
        }
        let search = BlockSearch()
        search.isPresented = true
        search.apply(SearchEngine.find(query: "needle", options: SearchOptions(), in: [doc]), reveal: true)
        let highlights = search.highlights(for: block, segment: index)
        #expect(highlights.ranges == [matches[0].range])
        #expect(highlights.active == matches[0].range)
    }
}
