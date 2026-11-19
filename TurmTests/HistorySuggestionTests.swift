import Foundation
import Testing
import TurmCore
@testable import Turm

struct HistorySuggestionTests {
    private func environment() -> FakeEnvironment {
        var env = FakeEnvironment.standard
        env.symbols.append(ShellSymbol(name: "touch", kind: .executable, detail: "/usr/bin"))
        env.symbols.append(ShellSymbol(name: "pushd", kind: .builtin, detail: nil))
        return env
    }

    private func suggest(_ text: String, _ items: [HistoryEntry], in directory: String = "/work") -> String? {
        HistorySuggester.suggestion(for: text, in: items, directory: directory, environment: environment())
    }

    private func entry(_ command: String, _ directory: String? = nil) -> HistoryEntry {
        HistoryEntry(command: command, directory: directory)
    }

    private func valid(_ command: String, in directory: String = "/work") -> Bool {
        HistorySuggester.isValid(command, directory: directory, environment: environment())
    }

    @Test func prefersEntryRunInThisDirectory() {
        let items = [entry("git status", "/work"), entry("git stash", "/elsewhere")]
        #expect(suggest("git sta", items) == "tus")
    }

    @Test func fallsBackToGlobalEntry() {
        let items = [entry("git status"), entry("git stash", "/elsewhere")]
        #expect(suggest("git sta", items, in: "/work") == "sh")
        #expect(suggest("git sta", [entry("git status", "/work")], in: "/work/src") == "tus")
    }

    @Test func directoryMatchBeatsNewerGlobalEntry() {
        let items = [entry("ls docs", "/work"), entry("ls dist", "/other")]
        #expect(suggest("ls d", items) == "ocs")
    }

    @Test func skipsInvalidNewestAndUsesOlderValid() {
        let items = [entry("cd src", "/work"), entry("cd gone", "/work")]
        #expect(suggest("cd ", items) == "src")
    }

    @Test func nothingWhenNoCandidateIsValid() {
        #expect(suggest("cd ", [entry("cd gone", "/work")]) == nil)
    }

    @Test func excludesMultilineAndExactMatches() {
        #expect(suggest("echo a", [entry("echo a\nb")]) == nil)
        #expect(suggest("ls", [entry("ls")]) == nil)
        #expect(suggest("", [entry("ls -l")]) == nil)
    }

    @Test func rejectsMissingCdTarget() {
        #expect(!valid("cd nowhere"))
        #expect(!valid("cd ../elsewhere"))
        #expect(!valid("pushd nowhere"))
    }

    @Test func acceptsResolvableCdTargets() {
        #expect(valid("cd src"))
        #expect(valid("cd ./src"))
        #expect(valid("cd .."))
        #expect(valid("cd /work/src"))
        #expect(valid("cd ~/Documents"))
        #expect(valid("cd"))
        #expect(valid("cd -"))
        #expect(valid("cd ~"))
        #expect(valid("cd $PROJECT"))
        #expect(valid("cd \"$(pwd)\""))
    }

    @Test func rejectsMissingScript() {
        #expect(!valid("./build.sh"))
        #expect(!valid("./build.sh --release"))
        #expect(!valid("sudo ./build.sh"))
        #expect(valid("./tool.sh"))
    }

    @Test func rejectsMissingCommand() {
        #expect(!valid("frobnicate --now"))
        #expect(!valid("FOO=1 frobnicate"))
        #expect(!valid("sudo -u root frobnicate"))
        #expect(!valid("env X=1 frobnicate"))
        #expect(valid("sudo -u root git status"))
        #expect(valid("FOO=1 git status"))
    }

    @Test func unknownLookupIsAllowed() {
        var env = environment()
        env.loaded = false
        #expect(HistorySuggester.isValid("frobnicate", directory: "/work", environment: env))
    }

    @Test func rejectsPathArgumentWithMissingParent() {
        #expect(!valid("cat ../other-project/x"))
        #expect(!valid("cat /nowhere/file"))
        #expect(!valid("git add ./missing/file.txt"))
        #expect(!valid("echo hi > ./missing/out.txt"))
        #expect(valid("cat ./src/main.swift"))
        #expect(valid("cat ~/Documents/x"))
    }

    @Test func acceptsNewFileInExistingDirectory() {
        #expect(valid("touch ./new.txt"))
        #expect(valid("touch ./src/new.txt"))
        #expect(valid("echo hi > ./out.txt"))
    }

    @Test func acceptsOrdinaryCommands() {
        #expect(valid("git push"))
        #expect(valid("git push origin main"))
        #expect(valid("ls -la"))
        #expect(valid("cat README.md | grep foo"))
    }

    @Test func validatesEachCommandInList() {
        #expect(valid("cd src && ls"))
        #expect(!valid("cd src && frobnicate"))
        #expect(!valid("cd nowhere && ls"))
        #expect(!valid("ls | frobnicate"))
    }

    @Test func laterSegmentsUseTheNewDirectory() {
        #expect(valid("cd src && cat ./main.swift"))
        #expect(!valid("cd src && cat ../../x/y"))
        #expect(valid("cd - && cat ./anything/file"))
    }

    @Test func compoundSyntaxOnlyChecksFirstCommand() {
        #expect(valid("for f in *.txt; do frobnicate $f; done"))
        #expect(valid("if true; then frobnicate; fi"))
        #expect(valid("ls & frobnicate"))
        #expect(!valid("frobnicate & ls"))
    }

    @Test func ignoresWordsItCannotResolve() {
        #expect(valid("cat ./*/file"))
        #expect(valid("cat $HOME/../x/y"))
        #expect(valid("echo \"unterminated ./missing/x"))
    }

    @Test func normalizesPaths() {
        #expect(HistorySuggester.normalize("/work/./src/../docs") == "/work/docs")
        #expect(HistorySuggester.normalize("/../x") == "/x")
        #expect(HistorySuggester.normalize("/") == "/")
    }

    @Test func historyAppliesSuggester() {
        let history = CommandHistory(entries: [])
        history.record("cd src", directory: "/work")
        history.record("cd gone", directory: "/work")
        #expect(history.suggestion(for: "cd ", directory: "/work", environment: environment()) == "src")
    }
}

struct HistoryStorageTests {
    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("turm-history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func parsesBashHistoryAndSkipsTimestamps() {
        let text = "#1700000000\nls\n#1700000001\ncd /tmp\n\nls\n#not a timestamp\n"
        #expect(CommandHistory.parseBash(text) == ["cd /tmp", "ls", "#not a timestamp"])
    }

    @Test func parsesFishHistory() {
        let text = """
        - cmd: echo hi
          when: 1700000000
        - cmd: echo a\\nb
          when: 1700000001
        - cmd: ls C:\\\\dir
          when: 1700000002
          paths:
            - /tmp
        - cmd: echo hi
          when: 1700000003

        """
        #expect(CommandHistory.parseFish(text) == ["echo a\nb", "ls C:\\dir", "echo hi"])
    }

    @Test func picksShellFromEnvironment() {
        #expect(HistoryShell.detect(environment: ["SHELL": "/bin/bash"]) == .bash)
        #expect(HistoryShell.detect(environment: ["SHELL": "/opt/homebrew/bin/fish"]) == .fish)
        #expect(HistoryShell.detect(environment: ["SHELL": "/bin/zsh"]) == .zsh)
        #expect(HistoryShell.detect(environment: ["SHELL": "/bin/tcsh"]) == .zsh)
        #expect(HistoryShell.detect(environment: [:]) == .zsh)
    }

    @Test func resolvesHistoryPaths() {
        #expect(HistoryShell.zsh.historyPath(environment: [:], home: "/h") == "/h/.zsh_history")
        #expect(HistoryShell.zsh.historyPath(environment: ["ZDOTDIR": "/z"], home: "/h") == "/z/.zsh_history")
        #expect(HistoryShell.zsh.historyPath(environment: ["HISTFILE": "/x"], home: "/h") == "/x")
        #expect(HistoryShell.bash.historyPath(environment: [:], home: "/h") == "/h/.bash_history")
        #expect(HistoryShell.fish.historyPath(environment: [:], home: "/h") == "/h/.local/share/fish/fish_history")
        #expect(HistoryShell.fish.historyPath(environment: ["XDG_DATA_HOME": "/d"], home: "/h") == "/d/fish/fish_history")
    }

    @Test func loadsHistoryOfTheConfiguredShell() {
        var requested: [String] = []
        let loaded = CommandHistory.loadShellHistory(environment: ["SHELL": "/bin/bash"], home: "/h") { path in
            requested.append(path)
            return Data("#1\nmake\nmake test\n".utf8)
        }
        #expect(requested == ["/h/.bash_history"])
        #expect(loaded == ["make", "make test"])
        #expect(CommandHistory.loadShellHistory(environment: [:], home: "/h") { _ in nil }.isEmpty)
    }

    @Test func recordKeepsMostRecentLast() {
        let history = CommandHistory(entries: ["a", "b"])
        history.record("a", directory: "/x")
        #expect(history.entries == ["b", "a"])
        history.record("b", directory: "/x")
        #expect(history.entries == ["a", "b"])
    }

    @Test func dedupesPerCommandAndDirectory() {
        let history = CommandHistory(entries: [])
        history.record("ls", directory: "/a")
        history.record("ls", directory: "/b")
        history.record("ls", directory: "/a")
        #expect(history.items == [
            HistoryEntry(command: "ls", directory: "/b"),
            HistoryEntry(command: "ls", directory: "/a"),
        ])
        #expect(history.entries == ["ls"])
    }

    @Test func capsAtTheLimitDroppingOldest() {
        let history = CommandHistory(entries: [])
        for index in 0..<(CommandHistory.limit + 100) { history.record("c\(index)", directory: "/w") }
        #expect(history.items.count == CommandHistory.limit)
        #expect(history.entries.count == CommandHistory.limit)
        #expect(history.entries.first == "c100")
        #expect(history.entries.last == "c\(CommandHistory.limit + 99)")
    }

    @Test func mergesShellFileBeforeTurmEntries() {
        let merged = CommandHistory.merge(
            base: ["a", "b", "c"],
            persisted: [HistoryEntry(command: "b", directory: "/w"), HistoryEntry(command: "d", directory: "/w")]
        )
        #expect(merged == [
            HistoryEntry(command: "a", directory: nil),
            HistoryEntry(command: "c", directory: nil),
            HistoryEntry(command: "b", directory: "/w"),
            HistoryEntry(command: "d", directory: "/w"),
        ])
    }

    @Test func persistenceRoundTrip() throws {
        let url = tempStore()
        defer { cleanUp(url) }
        let first = CommandHistory(entries: [], store: url)
        first.record("make build", directory: "/proj")
        first.record("ls", directory: "/home")
        first.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))

        let second = CommandHistory(entries: ["old"], store: url)
        #expect(second.items == [
            HistoryEntry(command: "old", directory: nil),
            HistoryEntry(command: "make build", directory: "/proj"),
            HistoryEntry(command: "ls", directory: "/home"),
        ])
        #expect(second.entries == ["old", "make build", "ls"])
    }

    @Test func untaggedEntriesAreNotPersisted() {
        let url = tempStore()
        defer { cleanUp(url) }
        let history = CommandHistory(entries: ["from shell"], store: url)
        history.record("plain")
        history.flush()
        #expect(HistoryStore.load(url).isEmpty)
    }

    @Test func missingOrCorruptStoreLoadsEmpty() throws {
        let url = tempStore()
        defer { cleanUp(url) }
        #expect(HistoryStore.load(url).isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(HistoryStore.load(url).isEmpty)
    }
}
