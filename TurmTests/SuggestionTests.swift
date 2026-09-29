import Foundation
import Testing
@testable import Turm

private func step(_ text: String, _ ghost: String, env: FakeEnvironment = .standard) -> String {
    GhostStep.next(text: text, ghost: ghost, directory: "/work", env: env)
}

private var stepEnvironment: FakeEnvironment {
    var env = FakeEnvironment.standard
    env.files["/home/tester/Projects"] = [DirectoryEntry(name: "Turm", isDirectory: true)]
    env.files["/home/tester/Projects/Turm"] = [DirectoryEntry(name: "Package.swift", isDirectory: false)]
    env.files["/home/tester"]?.append(DirectoryEntry(name: "Projects", isDirectory: true))
    env.files["/work/src"]?.append(DirectoryEntry(name: "main.o", isDirectory: false))
    env.files["/work/My Folder"] = [DirectoryEntry(name: "a.txt", isDirectory: false)]
    env.files["/work"]?.append(DirectoryEntry(name: "My Folder", isDirectory: true))
    return env
}

struct GhostStepTests {
    @Test func stepsOneFolderAtATime() {
        let env = stepEnvironment
        #expect(step("cd ", "~/Projects/Turm", env: env) == "~/")
        #expect(step("cd ~/", "Projects/Turm", env: env) == "Projects/")
        #expect(step("cd ~/Projects/", "Turm", env: env) == "Turm")
        #expect(step("cd ~/Pro", "jects/Turm", env: env) == "jects/")
    }

    @Test func stepsWholeArgumentsForCommands() {
        #expect(step("git", " commit -m done") == " commit")
        #expect(step("git commit", " -m done") == " -m")
        #expect(step("git com", "mit -m done") == "mit")
        #expect(step("echo", "   ") == "   ")
    }

    @Test func nonDirectorySlashesStayInOneStep() {
        #expect(step("git checkout ", "feature/login") == "feature/login")
        #expect(step("curl ", "https://example.com/a") == "https://example.com/a")
    }

    @Test func flagValuesStepAtTheEqualsSign() {
        #expect(step("ls", " --color=auto") == " --color=")
        #expect(step("ls --color=", "auto") == "auto")
        #expect(step("cat --file=", "src/main.swift") == "src/")
    }

    @Test func extensionWaitsWhenTheStemIsShared() {
        let env = stepEnvironment
        #expect(step("vim src/ma", "in.swift", env: env) == "in")
        #expect(step("vim src/main", ".swift", env: env) == ".swift")
        #expect(step("vim src/", "util.swift", env: env) == "util.swift")
        #expect(step("cat README", ".md", env: env) == ".md")
        #expect(step("cat ", "README.md", env: env) == "README.md")
    }

    @Test func escapedAndQuotedSpacesStayInsideTheWord() {
        let env = stepEnvironment
        #expect(step("cat My\\ ", "Folder/a.txt", env: env) == "Folder/")
        #expect(step("cat ", "\"My Folder/a.txt\"", env: env) == "\"My Folder/")
    }
}

struct SuggestionListTests {
    @Test func historyComesFirstAndDuplicatesCollapse() {
        let items = [
            CompletionItem(insert: "src/", kind: .directory, terminator: ""),
            CompletionItem(insert: "docs/", kind: .directory, terminator: ""),
        ]
        let text = "cd s"
        let merged = SuggestionList.merge(
            text: text, range: NSRange(location: 3, length: 1), items: items, history: ["cd src/", "cd src/lib", "ls"]
        )
        #expect(merged.items.map(\.insert) == ["src/lib", "src/", "docs/"])
        #expect(merged.items[0].kind == .history)
        #expect(merged.items[0].display == "cd src/lib")
    }

    @Test func historyAloneUsesAnEmptyRangeAtTheEnd() {
        let merged = SuggestionList.merge(text: "git ", range: nil, items: [], history: ["git push", "git pull", "git push"])
        #expect(merged.range == NSRange(location: 4, length: 0))
        #expect(merged.items.map(\.insert) == ["push", "pull"])
    }

    @Test func ghostAndSoleItem() {
        let file = CompletionItem(insert: "README.md", kind: .file)
        #expect(SuggestionList.ghost(for: file, typed: "REA") == "DME.md")
        #expect(SuggestionList.ghost(for: file, typed: "README.md") == nil)
        #expect(SuggestionList.ghost(for: file, typed: "rea") == nil)
        let history = CompletionItem(insert: "x", kind: .history, terminator: "")
        #expect(SuggestionList.sole([history, file]) == file)
        #expect(SuggestionList.sole([file, file]) == nil)
    }

    @Test func historySuggestionsAreUniqueAndLimited() {
        let entries = ["git status", "git stash", "git status", "git stage", "git st"]
        #expect(CommandHistory.suggestions(for: "git st", in: entries, limit: 5) == ["age", "atus", "ash"])
        #expect(CommandHistory.suggestions(for: "git st", in: entries, limit: 1) == ["age"])
        #expect(CommandHistory.suggestions(for: "", in: entries, limit: 5).isEmpty)
    }
}

struct SiblingCompletionTests {
    private func siblings(_ line: String) -> CompletionResult? {
        CommandCompleter.siblings(line: line, cursor: line.endIndex, directory: "/work", environment: FakeEnvironment.standard)
    }

    @Test func completeFileListsItsFolder() throws {
        let line = "vim src/main.swift"
        let result = try #require(siblings(line))
        #expect(result.items.map(\.insert) == ["src/lib/", "src/main.swift", "src/util.swift"])
        #expect(String(line[result.range]) == "src/main.swift")
        #expect(!SuggestionList.extends(result, line: line))
    }

    @Test func topLevelFileListsWorkingDirectory() throws {
        let result = try #require(siblings("cat notes.txt"))
        #expect(result.items.map(\.display).contains("README.md"))
        #expect(!result.items.map(\.display).contains(".hidden"))
    }

    @Test func directoryCommandsListOnlyFolders() throws {
        let result = try #require(siblings("cd src"))
        #expect(result.items.allSatisfy { $0.kind == .directory })
    }

    @Test func nonPathWordsHaveNoSiblings() {
        #expect(siblings("git checkout main") == nil)
        #expect(siblings("ls -l") == nil)
        #expect(siblings("cat ") == nil)
    }

    @MainActor @Test func hintedPopupSkipsThePreviewedRow() {
        let model = CompletionModel()
        let items = [CompletionItem(insert: "a", kind: .history), CompletionItem(insert: "b", kind: .file)]
        model.show(items, engaged: false)
        model.hinted = true
        model.move(by: 1)
        #expect(model.selected == 1)
        model.show(items, engaged: false)
        #expect(!model.hinted)
        model.move(by: 1)
        #expect(model.selected == 0)
    }
}
