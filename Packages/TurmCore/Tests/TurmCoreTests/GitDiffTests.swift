import Foundation
import Testing
@testable import TurmCore

private let twoFileDiff = """
    diff --git a/Sources/Foo.swift b/Sources/Foo.swift
    --- a/Sources/Foo.swift
    +++ b/Sources/Foo.swift
    @@ -1,3 +1,3 @@
     context line
    -removed line
    +added line
    diff --git a/Sources/Bar.swift b/Sources/Bar.swift
    new file mode 100644
    --- /dev/null
    +++ b/Sources/Bar.swift
    @@ -0,0 +1,1 @@
    +new line
    """

private let deletedFileDiff = """
    diff --git a/Old.swift b/Old.swift
    deleted file mode 100644
    --- a/Old.swift
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -gone
    """

private let renamedFileDiff = """
    diff --git a/Old.swift b/New.swift
    similarity index 100%
    rename from Old.swift
    rename to New.swift
    """

private let binaryFileDiff = """
    diff --git a/icon.png b/icon.png
    index abc1234..def5678 100644
    Binary files a/icon.png and b/icon.png differ
    """

private let fiveLineDiff = """
    diff --git a/Big.swift b/Big.swift
    --- a/Big.swift
    +++ b/Big.swift
    @@ -1,5 +1,5 @@
    +line1
    +line2
    +line3
    +line4
    +line5
    """

struct GitDiffParserTests {
    @Test func twoFileDiffParsesStatusPathsAndLineKinds() {
        let doc = GitDiffParser.parse(twoFileDiff, lineCap: nil)
        #expect(doc.files.count == 2)

        let foo = doc.files[0]
        #expect(foo.path == "Sources/Foo.swift")
        #expect(foo.status == .modified)
        #expect(foo.oldPath == nil)
        #expect(foo.hunks.count == 1)
        #expect(foo.hunks[0].oldStart == 1)
        #expect(foo.hunks[0].newStart == 1)
        #expect(foo.hunks[0].lines == [
            GitDiffLine(kind: .context, text: "context line"),
            GitDiffLine(kind: .removed, text: "removed line"),
            GitDiffLine(kind: .added, text: "added line"),
        ])

        let bar = doc.files[1]
        #expect(bar.path == "Sources/Bar.swift")
        #expect(bar.status == .added)
        #expect(bar.oldPath == nil)
        #expect(bar.hunks.count == 1)
        #expect(bar.hunks[0].oldStart == 0)
        #expect(bar.hunks[0].newStart == 1)
        #expect(bar.hunks[0].lines == [GitDiffLine(kind: .added, text: "new line")])
    }

    @Test func deletedFileStatusFromDevNull() {
        let doc = GitDiffParser.parse(deletedFileDiff, lineCap: nil)
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.status == .deleted)
        #expect(file.path == "Old.swift")
        #expect(file.oldPath == nil)
    }

    @Test func renamedFileStatusAndBothPaths() {
        let doc = GitDiffParser.parse(renamedFileDiff, lineCap: nil)
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.status == .renamed)
        #expect(file.path == "New.swift")
        #expect(file.oldPath == "Old.swift")
        #expect(file.hunks.isEmpty)
    }

    @Test func binaryFileStatusWithNoHunks() {
        let doc = GitDiffParser.parse(binaryFileDiff, lineCap: nil)
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.status == .binary)
        #expect(file.hunks.isEmpty)
    }

    @Test func lineCapTruncatesFile() {
        let doc = GitDiffParser.parse(fiveLineDiff, lineCap: 2)
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.truncated == true)
        #expect(file.shownLines == 2)
    }

    @Test func nilLineCapKeepsAllLines() {
        let doc = GitDiffParser.parse(fiveLineDiff, lineCap: nil)
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.truncated == false)
        #expect(file.shownLines == 5)
    }

    @Test func emptyInputProducesNoFiles() {
        let doc = GitDiffParser.parse("")
        #expect(doc.files.isEmpty)
    }
}

struct GitDiffSideBySideTests {
    @Test func sideBySidePairsRemovalsWithAdditionsAndLeavesLeftoverNil() {
        let hunk = GitHunk(
            id: "test:@@ -1,5 +1,4 @@",
            header: "@@ -1,5 +1,4 @@",
            oldStart: 1,
            newStart: 1,
            lines: [
                GitDiffLine(kind: .context, text: "ctx1"),
                GitDiffLine(kind: .removed, text: "rem1"),
                GitDiffLine(kind: .removed, text: "rem2"),
                GitDiffLine(kind: .added, text: "add1"),
                GitDiffLine(kind: .context, text: "ctx2"),
            ]
        )
        let rows = GitDiffParser.sideBySide(hunk)
        #expect(rows.count == 4)
        #expect(rows[0] == SideBySideRow(
            left: GitDiffLine(kind: .context, text: "ctx1"),
            right: GitDiffLine(kind: .context, text: "ctx1")
        ))
        #expect(rows[1] == SideBySideRow(
            left: GitDiffLine(kind: .removed, text: "rem1"),
            right: GitDiffLine(kind: .added, text: "add1")
        ))
        #expect(rows[2] == SideBySideRow(
            left: GitDiffLine(kind: .removed, text: "rem2"),
            right: nil
        ))
        #expect(rows[3] == SideBySideRow(
            left: GitDiffLine(kind: .context, text: "ctx2"),
            right: GitDiffLine(kind: .context, text: "ctx2")
        ))
    }
}

struct GitInlineChangeTests {
    @Test func insertionInTheMiddleIsBoldOnlyOnTheAddedLine() {
        let old = "case .pairBegin, .switchBranch, .revealInFinder, .title: false"
        let new = "case .pairBegin, .switchBranch, .diff, .diffResult, .listDirectory, .revealInFinder, .title: false"
        let change = GitDiffParser.inlineChanges(old: old, new: new)
        #expect(change.removed.isEmpty)
        #expect(change.added.map { String(new[$0]) } == [", .diff, .diffResult, .listDirectory"])
    }

    @Test func replacedWordsAreBoldOnBothLines() {
        let old = "let value = 1"
        let new = "let value = 2"
        let change = GitDiffParser.inlineChanges(old: old, new: new)
        #expect(change.removed.map { String(old[$0]) } == ["1"])
        #expect(change.added.map { String(new[$0]) } == ["2"])
    }

    @Test func severalEditsStaySeparateSpans() {
        let old = "alpha beta gamma"
        let new = "alpha BETA gamma delta"
        let change = GitDiffParser.inlineChanges(old: old, new: new)
        #expect(change.removed.map { String(old[$0]) } == ["beta"])
        #expect(change.added.map { String(new[$0]) } == ["BETA", " delta"])
    }

    @Test func aRemovalWithoutAPartnerIsNotMarked() {
        let lines = [
            GitDiffLine(kind: .removed, text: "only gone"),
            GitDiffLine(kind: .context, text: "stays"),
        ]
        let marks = GitDiffParser.inlineChanges(for: lines)
        #expect(marks == [[], []])
    }
}

struct GitDiffLogParserTests {
    @Test func parseLogExtractsRefsInOrderIgnoringBlanks() {
        let text = "abc123\tFirst commit\ndef456\tSecond commit\n\n"
        let refs = GitDiffParser.parseLog(text)
        #expect(refs.count == 2)
        #expect(refs[0] == GitCommitRef(sha: "abc123", subject: "First commit"))
        #expect(refs[1] == GitCommitRef(sha: "def456", subject: "Second commit"))
    }
}
