import Foundation
import Testing
@testable import Turm

private let api = Shortcut(kind: .directory, key: "api", name: "Backend", value: "/work/api")
private let web = Shortcut(kind: .directory, key: "web", name: "Frontend", value: "/work/web")
private let build = Shortcut(kind: .command, key: "build", name: "Build", value: "npm run build")
private let deploy = Shortcut(kind: .command, key: "deploy", name: "", value: "make deploy")
private let file = Shortcut(kind: .file, key: "cfg", name: "Config", value: "/work/api/config.json")
private let shortcuts = [api, web, build, deploy, file]
private let here = "/Users/tester"

private func label(_ path: String) -> String {
    shortcuts.first { $0.kind == .directory && $0.value == path }?.label ?? path
}

private func rows(_ query: String, history: [String] = []) -> [SpotlightRow] {
    SpotlightModel.rows(query: query, currentDirectory: here, shortcuts: shortcuts, history: history, label: label)
}

struct SpotlightModelTests {
    @Test func emptyQueryListsNewShellThenDirectoriesCommandsAndHistory() {
        let result = rows("", history: ["ls", "git status"])
        #expect(result.map(\.kind) == [.newShell, .directory, .directory, .command, .command, .history, .history])
        #expect(result[0].title == "New shell")
        #expect(result[0].detail == here)
        #expect(result[0].directory == nil)
        #expect(result[0].command == nil)
        #expect(result.map(\.title).suffix(2) == ["git status", "ls"])
    }

    @Test func emptyQueryRowsLaunchInTheCurrentDirectory() {
        let result = rows("   ", history: ["ls"])
        #expect(result.allSatisfy { $0.kind == .directory || $0.directory == nil })
        let dir = result.first { $0.token == "@api" }
        #expect(dir?.directory == "/work/api")
        #expect(dir?.command == nil)
        let command = result.first { $0.token == "!build" }
        #expect(command?.command == "!build")
        #expect(command?.directory == nil)
        #expect(result.first { $0.kind == .history }?.command == "ls")
    }

    @Test func emptyQueryHistoryIsUniqueRecentAndCapped() {
        let history = (0..<20).map { "cmd\($0)" } + ["cmd3", "cmd5"]
        let titles = rows("", history: history).filter { $0.kind == .history }.map(\.title)
        #expect(titles.count == 8)
        #expect(titles.prefix(2) == ["cmd5", "cmd3"])
        #expect(Set(titles).count == 8)
    }

    @Test func typedQueryStartsWithRunRow() {
        let first = rows("npm test")[0]
        #expect(first.kind == .run)
        #expect(first.title == "Run npm test")
        #expect(first.detail == here)
        #expect(first.command == "npm test")
        #expect(first.directory == nil)
    }

    @Test func leadingDirectoryWithCommandRunsThereWithoutExpandingShortcuts() {
        let first = rows("@api npm test")[0]
        #expect(first.kind == .run)
        #expect(first.directory == "/work/api")
        #expect(first.command == "npm test")
        #expect(first.detail == "Backend")
        let inline = rows("@api cat #cfg")[0]
        #expect(inline.command == "cat #cfg")
    }

    @Test func leadingDirectoryAloneOpensIt() {
        let result = rows("@api")
        #expect(result.count == 1)
        #expect(result[0].kind == .open)
        #expect(result[0].title == "Open Backend")
        #expect(result[0].directory == "/work/api")
        #expect(result[0].command == nil)
    }

    @Test func historyAndCommandRowsInheritTheLeadingDirectory() {
        let result = rows("@api bu", history: ["npm run build"])
        let command = result.first { $0.kind == .command }
        #expect(command?.command == "!build")
        #expect(command?.directory == "/work/api")
        let entry = result.first { $0.kind == .history }
        #expect(entry?.command == "npm run build")
        #expect(entry?.directory == "/work/api")
    }

    @Test func matchingIsCaseInsensitiveAcrossKeyNameAndValue() {
        #expect(rows("BACK").contains { $0.token == "@api" })
        #expect(rows("work/web").contains { $0.token == "@web" })
        #expect(rows("Build").contains { $0.token == "!build" })
        #expect(rows("run build").contains { $0.token == "!build" })
        #expect(!rows("zzz").contains { $0.kind == .directory || $0.kind == .command })
    }

    @Test func filesAreNeverListed() {
        #expect(!rows("cfg").contains { $0.token == "#cfg" })
        #expect(!rows("").contains { $0.title == "#cfg" })
    }

    @Test func prefixMatchesRankAheadOfSubsequenceMatches() {
        let pool = [
            Shortcut(kind: .directory, key: "xdeploy", name: "", value: "/x"),
            Shortcut(kind: .directory, key: "dpl", name: "", value: "/y"),
            Shortcut(kind: .directory, key: "deploy", name: "", value: "/z"),
        ]
        let result = SpotlightModel.rows(query: "dep", currentDirectory: here, shortcuts: pool, history: [], label: { $0 })
        let tokens = result.compactMap(\.token)
        #expect(tokens == ["@deploy", "@xdeploy"])
        let loose = SpotlightModel.rows(query: "dpl", currentDirectory: here, shortcuts: pool, history: [], label: { $0 })
        #expect(loose.compactMap(\.token) == ["@dpl", "@xdeploy", "@deploy"])
    }

    @Test func rankTiers() {
        #expect(SpotlightModel.rank("bu", in: ["build"]) == 0)
        #expect(SpotlightModel.rank("ild", in: ["build"]) == 1)
        #expect(SpotlightModel.rank("bld", in: ["build"]) == 2)
        #expect(SpotlightModel.rank("x", in: ["build"]) == nil)
        #expect(SpotlightModel.rank("bu", in: ["nope", "", "build"]) == 0)
    }

    @Test func sigilNarrowsShortcutKind() {
        let directories = rows("@").filter { $0.kind == .directory }
        #expect(directories.count == 2)
        #expect(!rows("@b").contains { $0.kind == .command })
        #expect(rows("!b").contains { $0.token == "!build" })
        #expect(!rows("!b").contains { $0.kind == .directory })
    }

    @Test func historyMatchesRankPrefixFirstThenRecency() {
        let history = ["git push", "echo git", "git pull"]
        let titles = rows("git", history: history).filter { $0.kind == .history }.map(\.title)
        #expect(titles == ["git pull", "git push", "echo git"])
    }

    @Test func tabCompletesTheTrailingWordWithAShortcutToken() {
        let command = rows("@api bu").first { $0.kind == .command }!
        #expect(SpotlightModel.completion(of: command, query: "@api bu") == "@api !build ")
        let directory = rows("ap").first { $0.kind == .directory }!
        #expect(SpotlightModel.completion(of: directory, query: "ap") == "@api ")
        #expect(SpotlightModel.completion(of: directory, query: "") == "@api ")
    }

    @Test func tabOnHistoryUsesTheCommandAndOtherRowsHaveNoCompletion() {
        let entry = rows("gi", history: ["git status"]).first { $0.kind == .history }!
        #expect(SpotlightModel.completion(of: entry, query: "gi") == "git status")
        #expect(SpotlightModel.completion(of: rows("x")[0], query: "x") == nil)
        #expect(SpotlightModel.completion(of: rows("")[0], query: "") == nil)
    }
}

struct SpotlightSearchTests {
    private let paneA = PaneID()
    private let paneB = PaneID()
    private let tabA = UUID()
    private let tabB = UUID()
    private let settings = UUID()

    private var shells: [SpotlightShell] {
        [
            SpotlightShell(tab: tabA, pane: paneA, title: "api", detail: "~/work/api  main", fields: ["api", "~/work/api", "main"],
                           commands: ["npm test", "git push", "npm test"], isSettings: false),
            SpotlightShell(tab: tabB, pane: paneB, title: "web", detail: "~/work/web", fields: ["web", "~/work/web"],
                           commands: ["pnpm dev"], isSettings: false),
            SpotlightShell(tab: settings, pane: nil, title: "Settings", detail: "", fields: ["Settings"], commands: [], isSettings: true),
        ]
    }

    @Test func questionMarkSwitchesToSearch() {
        #expect(SpotlightModel.isSearch("?"))
        #expect(SpotlightModel.isSearch("  ?api"))
        #expect(!SpotlightModel.isSearch("echo ?"))
        #expect(!SpotlightModel.isSearch(""))
    }

    @Test func emptySearchListsEveryShell() {
        let rows = SpotlightModel.searchRows(query: "?", shells: shells)
        #expect(rows.map(\.title) == ["api", "web", "Settings"])
        #expect(rows.allSatisfy { $0.kind == .shell })
        #expect(rows.last?.symbol == "gearshape")
        #expect(rows.first?.pane == paneA)
    }

    @Test func searchMatchesShellsThenCommands() {
        let rows = SpotlightModel.searchRows(query: "? npm", shells: shells)
        #expect(rows.map(\.kind) == [.block, .block])
        #expect(rows.map(\.title) == ["npm test", "pnpm dev"])
        #expect(rows.first?.detail == "in api")
        #expect(rows.first?.tab == tabA)

        let web = SpotlightModel.searchRows(query: "?web", shells: shells)
        #expect(web.first?.kind == .shell)
        #expect(web.first?.pane == paneB)
    }

    @Test func multiWordSearchNeedsEveryTerm() {
        let rows = SpotlightModel.searchRows(query: "?api main", shells: shells).filter { $0.kind == .shell }
        #expect(rows.map(\.title) == ["api"])
        #expect(SpotlightModel.searchRows(query: "?zzz", shells: shells).isEmpty)
    }

    @Test func searchRowsHaveNoCompletion() {
        let row = SpotlightModel.searchRows(query: "?", shells: shells)[0]
        #expect(SpotlightModel.completion(of: row, query: "?") == nil)
    }
}
