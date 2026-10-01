import Foundation
import Testing
import TurmCore
@testable import Turm

private let home = "/Users/tester"
private let longCommand = "npm run build --workspaces"

private func stats(visits: [String: Int] = [:], commands: [String: Int] = [:]) -> ShortcutStats {
    ShortcutStats(directories: visits, commands: commands)
}

private func suggest(
    _ stats: ShortcutStats, directory: String = "/work/api", command: String? = nil, shortcuts: [Shortcut] = []
) -> ShortcutSuggestion? {
    stats.suggestion(currentDirectory: directory, lastCommand: command, shortcuts: shortcuts, home: home)
}

struct ShortcutStatsTests {
    @Test func sameDirectoryIsCountedOnce() {
        var value = ShortcutStats()
        value.recordVisit("/work/api")
        value.recordVisit("/work/api")
        #expect(value.directories["/work/api"] == 1)
        value.recordVisit("/work/web")
        value.recordVisit("/work/api")
        #expect(value.directories["/work/api"] == 2)
        #expect(value.directories["/work/web"] == 1)
    }

    @Test func commandsNeedMinimumLengthAndNoSigil() {
        var value = ShortcutStats()
        value.recordCommand("ls -la")
        value.recordCommand("!" + longCommand)
        value.recordCommand("@api " + longCommand)
        value.recordCommand("#cfg " + longCommand)
        #expect(value.commands.isEmpty)
        value.recordCommand("  " + longCommand + "  \n")
        value.recordCommand(longCommand)
        #expect(value.commands[longCommand] == 2)
        value.recordCommand(String(repeating: "a", count: 19))
        #expect(value.commands.count == 1)
        value.recordCommand(String(repeating: "a", count: 20))
        #expect(value.commands.count == 2)
    }

    @Test func navigationCommandsAreNeverTracked() {
        var value = ShortcutStats()
        let cd = "cd /Users/tester/Projects/rust/appleutils"
        for _ in 0..<9 {
            value.recordCommand(cd)
            value.recordCommand("pushd /Users/tester/Projects/rust")
        }
        #expect(value.commands.isEmpty)
        #expect(suggest(stats(commands: [cd: 9]), command: cd) == nil)
    }

    @Test func directorySuggestionThreshold() {
        #expect(suggest(stats(visits: ["/work/api": 4])) == nil)
        let found = suggest(stats(visits: ["/work/api": 5]))
        #expect(found?.kind == .directory)
        #expect(found?.value == "/work/api")
        #expect(found?.draft.token == "@api")
        #expect(found?.draft.name == "api")
        #expect(found?.draft.value == "/work/api")
    }

    @Test func homeAndRootAreNeverSuggested() {
        let visits = [home: 50, "/": 50, home + "/": 50]
        #expect(suggest(stats(visits: visits), directory: home) == nil)
        #expect(suggest(stats(visits: visits), directory: home + "/") == nil)
        #expect(suggest(stats(visits: visits), directory: "/") == nil)
    }

    @Test func existingDirectoryShortcutSuppressesSuggestion() {
        let existing = Shortcut(kind: .directory, key: "x", name: "", value: "/work/api")
        #expect(suggest(stats(visits: ["/work/api": 9]), shortcuts: [existing]) == nil)
        let other = Shortcut(kind: .directory, key: "x", name: "", value: "/work/web")
        #expect(suggest(stats(visits: ["/work/api": 9]), shortcuts: [other]) != nil)
        let fileWithSamePath = Shortcut(kind: .file, key: "x", name: "", value: "/work/api")
        #expect(suggest(stats(visits: ["/work/api": 9]), shortcuts: [fileWithSamePath]) != nil)
    }

    @Test func directoryKeyAvoidsExistingKeys() {
        let taken = Shortcut(kind: .directory, key: "API", name: "", value: "/elsewhere")
        let taken2 = Shortcut(kind: .directory, key: "api2", name: "", value: "/elsewhere2")
        let found = suggest(stats(visits: ["/work/My Api": 5]), directory: "/work/My Api")
        #expect(found?.draft.key == "myapi")
        let clash = suggest(stats(visits: ["/work/api": 5]), shortcuts: [taken, taken2])
        #expect(clash?.draft.key == "api3")
    }

    @Test func commandSuggestionThreshold() {
        #expect(suggest(stats(commands: [longCommand: 3]), command: longCommand) == nil)
        let found = suggest(stats(commands: [longCommand: 4]), command: longCommand)
        #expect(found?.kind == .command)
        #expect(found?.value == longCommand)
        #expect(found?.draft.token == "!npm-build")
        #expect(found?.draft.name == "npm build")
        #expect(found?.draft.value == longCommand)
        #expect(suggest(stats(commands: [longCommand: 9]), command: nil) == nil)
    }

    @Test func commandSuggestionWinsOverDirectory() {
        let value = stats(visits: ["/work/api": 9], commands: [longCommand: 9])
        #expect(suggest(value, command: longCommand)?.kind == .command)
        #expect(suggest(value, command: "ls")?.kind == .directory)
    }

    @Test func existingCommandShortcutSuppressesCommandSuggestion() {
        let existing = Shortcut(kind: .command, key: "b", name: "", value: " " + longCommand + " ")
        let value = stats(commands: [longCommand: 9])
        #expect(suggest(value, command: longCommand, shortcuts: [existing]) == nil)
    }

    @Test func dismissedSuggestionsAreExcluded() throws {
        var value = stats(visits: ["/work/api": 9], commands: [longCommand: 9])
        let command = try #require(suggest(value, command: longCommand))
        value.dismiss(command)
        value.dismiss(command)
        #expect(value.dismissed.count == 1)
        #expect(suggest(value, command: longCommand)?.kind == .directory)
        let directory = try #require(suggest(value, command: longCommand))
        value.dismiss(directory)
        #expect(suggest(value, command: longCommand) == nil)
    }

    @Test func commandKeyRules() {
        func key(_ command: String, _ shortcuts: [Shortcut] = []) -> String {
            ShortcutSuggestions.commandKey(for: command, in: shortcuts)
        }
        #expect(key("npm run build") == "npm-build")
        #expect(key("make") == "make")
        #expect(key("  Docker   Compose up -d") == "docker-compose")
        #expect(key("ls -la") == "ls")
        #expect(key("!!") == "command")
        let make = Shortcut(kind: .command, key: "make", name: "", value: "make")
        let make2 = Shortcut(kind: .command, key: "make2", name: "", value: "make all")
        let fileMake = Shortcut(kind: .file, key: "npm-build", name: "", value: "/x")
        #expect(key("make", [make]) == "make2")
        #expect(key("make", [make, make2]) == "make3")
        #expect(key("npm run build", [fileMake]) == "npm-build")
        #expect(key("sudo FOO=1 make install") == "make-install")
        #expect(key("/usr/local/bin/cargo test --release") == "cargo-test")
        #expect(key("python3 scripts/deploy.py staging") == "deploy-staging")
        #expect(key("git -C ~/src status") == "git")
        #expect(key("swift test --filter Foo") == "swift-test")
        #expect(key("npm run lint:fix") == "npm-lint-fix")
        #expect(key("ssh user@host.example.com") == "ssh")
    }

    @Test func statsAreCapped() {
        var value = ShortcutStats()
        for index in 0..<(ShortcutStats.capacity + 30) {
            value.recordVisit("/dir/\(index)")
        }
        #expect(value.directories.count == ShortcutStats.capacity)
        var hot = ShortcutStats()
        hot.recordVisit("/hot")
        for index in 0..<ShortcutStats.capacity + 30 {
            hot.recordVisit("/cold/\(index)")
            hot.recordVisit("/hot")
        }
        #expect(hot.directories["/hot"] == ShortcutStats.capacity + 31)
        #expect(hot.directories.count == ShortcutStats.capacity)
        var commands = ShortcutStats()
        for index in 0..<(ShortcutStats.capacity + 30) {
            commands.recordCommand("echo a long command number \(index)")
        }
        #expect(commands.commands.count == ShortcutStats.capacity)
    }
}

struct ShortcutSuggestionTrackerTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "turm.tests.suggestions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func persistsRoundTrip() throws {
        try withDefaults { defaults in
            let tracker = ShortcutSuggestionTracker(defaults: defaults)
            for index in 0..<5 {
                tracker.recordVisit("/work/api")
                tracker.recordVisit("/work/other\(index)")
            }
            for _ in 0..<4 { tracker.recordCommand(longCommand) }
            let dismissed = try #require(tracker.suggestion(currentDirectory: "/work/api", lastCommand: nil, shortcuts: [], home: home))
            tracker.dismiss(dismissed)

            let reloaded = ShortcutSuggestionTracker(defaults: defaults)
            #expect(reloaded.stats == tracker.stats)
            #expect(reloaded.stats.directories["/work/api"] == 5)
            #expect(reloaded.stats.commands[longCommand] == 4)
            #expect(reloaded.stats.dismissed == [dismissed.identifier])
            #expect(reloaded.suggestion(currentDirectory: "/work/api", lastCommand: nil, shortcuts: [], home: home) == nil)
            #expect(reloaded.suggestion(currentDirectory: "/work/api", lastCommand: longCommand, shortcuts: [], home: home)?.kind == .command)
        }
    }

    @Test func storesJSONUnderDocumentedKey() throws {
        try withDefaults { defaults in
            let tracker = ShortcutSuggestionTracker(defaults: defaults)
            tracker.recordVisit("/work/api")
            let text = try #require(defaults.string(forKey: "turm.shortcutStats"))
            let decoded = try JSONDecoder().decode(ShortcutStats.self, from: Data(text.utf8))
            #expect(decoded.directories == ["/work/api": 1])
        }
    }

    @Test func corruptDataStartsEmpty() throws {
        try withDefaults { defaults in
            defaults.set("not json", forKey: "turm.shortcutStats")
            #expect(ShortcutSuggestionTracker(defaults: defaults).stats == ShortcutStats())
        }
    }

    @Test func lastDirectorySurvivesReload() throws {
        try withDefaults { defaults in
            ShortcutSuggestionTracker(defaults: defaults).recordVisit("/work/api")
            let reloaded = ShortcutSuggestionTracker(defaults: defaults)
            reloaded.recordVisit("/work/api")
            #expect(reloaded.stats.directories["/work/api"] == 1)
        }
    }
}
