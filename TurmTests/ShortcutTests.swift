import Foundation
import Testing
@testable import Turm

private let api = Shortcut(kind: .directory, key: "api", name: "Backend", value: "/work/api")
private let web = Shortcut(kind: .directory, key: "Web", name: "", value: "/work/web app")
private let core = Shortcut(kind: .directory, key: "core", name: "Core", value: "/work/api/core")
private let config = Shortcut(kind: .file, key: "cfg", name: "Config", value: "/work/api/config.json")
private let notes = Shortcut(kind: .file, key: "api", name: "", value: "/home/tester/api notes.txt")
private let build = Shortcut(kind: .command, key: "build", name: "Build", value: "npm run build")
private let all = [api, web, core, config, notes, build]

private func posix(_ text: String) -> String { ShellIntegration.quoted(text) }

private func expand(_ line: String, _ shortcuts: [Shortcut] = all) -> String? {
    Shortcuts.expand(line, in: shortcuts, quote: posix)
}

private func scanned(_ line: String) -> [String] {
    Shortcuts.scan(line, in: all).map { String(line[$0.range]) }
}

struct ShortcutModelTests {
    @Test func sanitizeStripsSigilsAndInvalidCharacters() {
        #expect(Shortcuts.sanitize("  @@my api! ") == "myapi")
        #expect(Shortcuts.sanitize("#cfg") == "cfg")
        #expect(Shortcuts.sanitize("!build") == "build")
        #expect(Shortcuts.sanitize("front-end_v2.1") == "front-end_v2.1")
        #expect(Shortcuts.sanitize("caf\u{E9}") == "caf")
    }

    @Test func labelFallsBackToKey() {
        #expect(api.label == "Backend")
        #expect(web.label == "Web")
        #expect(Shortcut(kind: .directory, key: "x", name: "   ", value: "/x").label == "x")
    }

    @Test func sigilsMapToKinds() {
        #expect(ShortcutKind(sigil: "@") == .directory)
        #expect(ShortcutKind(sigil: "!") == .command)
        #expect(ShortcutKind(sigil: "#") == .file)
        #expect(ShortcutKind(sigil: "$") == nil)
        #expect(config.token == "#cfg")
    }

    @Test func keysAreUniquePerKind() {
        #expect(Shortcuts.find("API", kind: .directory, in: all) == api)
        #expect(Shortcuts.find("api", kind: .file, in: all) == notes)
        #expect(Shortcuts.conflict(for: "API", kind: .directory, excluding: nil, in: all) == api)
        #expect(Shortcuts.conflict(for: "api", kind: .directory, excluding: api.id, in: all) == nil)
        #expect(Shortcuts.conflict(for: "build", kind: .file, excluding: nil, in: all) == nil)
    }

    @Test func matchPrefersTheDeepestDirectory() {
        #expect(Shortcuts.match(path: "/work/api", in: all)?.shortcut == api)
        #expect(Shortcuts.match(path: "/work/api/src/x", in: all).map { [$0.shortcut.key, $0.rest] } == ["api", "src/x"])
        #expect(Shortcuts.match(path: "/work/api/core/lib", in: all).map { [$0.shortcut.key, $0.rest] } == ["core", "lib"])
        #expect(Shortcuts.match(path: "/work/apiary", in: all) == nil)
        #expect(Shortcuts.match(path: "/work/api/config.json", in: [config]) == nil)
    }
}

struct ShortcutScanTests {
    @Test func findsShortcutsAtWordStarts() {
        #expect(scanned("cat #cfg | grep x") == ["#cfg"])
        #expect(scanned("cp #api @web/src") == ["#api", "@web/src"])
        #expect(scanned("!build && ls") == ["!build"])
        #expect(scanned("tool --config=#cfg;echo @api") == ["#cfg", "@api"])
        #expect(scanned("(cd @core)") == ["@core"])
    }

    @Test func ignoresQuotedEscapedAndEmbeddedText() {
        #expect(scanned("echo '#cfg' \"@api\" \\#cfg") == [])
        #expect(scanned("mail me@api x#cfg") == [])
        #expect(scanned("echo #cfgx #nope !nope @api.") == [])
        #expect(scanned("echo #cfg/x !build/y") == [])
    }

    @Test func marksOnlyTheLeadingDirectoryAsAChangeOfDirectory() {
        let lead = Shortcuts.scan("  @api ls @web", in: all)
        #expect(lead.map(\.changesDirectory) == [true, false])
        #expect(Shortcuts.scan("#api", in: all).first?.changesDirectory == false)
    }

    @Test func partialFindsTheWordBeingTyped() {
        let line = "cat #cf"
        let partial = Shortcuts.partial(atEndOf: line)
        #expect(partial?.kind == .file)
        #expect(partial?.key == "cf")
        #expect(partial.map { String(line[$0.range]) } == "#cf")
        #expect(Shortcuts.partial(atEndOf: "x --file=#")?.key == "")
        #expect(Shortcuts.partial(atEndOf: "@api/src/r")?.subpath == "src/r")
        #expect(Shortcuts.partial(atEndOf: "echo '#cf") == nil)
        #expect(Shortcuts.partial(atEndOf: "echo a#cf") == nil)
        #expect(Shortcuts.partial(atEndOf: "#cfg/x") == nil)
        #expect(Shortcuts.partial(atEndOf: "echo ") == nil)
    }

    @Test func maskKeepsUTF16Offsets() {
        let line = "cat #cfg @web/caf\u{E9} x"
        let masked = Shortcuts.masked(line, matches: Shortcuts.scan(line, in: all))
        #expect(masked.utf16.count == line.utf16.count)
        #expect(masked.hasPrefix("cat ____ "))
        #expect(masked.hasSuffix(" x"))
        #expect(Shortcuts.masked("@api ls", matches: Shortcuts.scan("@api ls", in: all)) == "     ls")
    }
}

struct ShortcutExpansionTests {
    @Test func leadingDirectoryChangesDirectory() {
        #expect(expand("@api") == "cd '/work/api'")
        #expect(expand("@web/src") == "cd '/work/web app/src'")
        #expect(expand("@api npm test") == "cd '/work/api' && npm test")
        #expect(expand("@api; ls") == "cd '/work/api'; ls")
    }

    @Test func inlineShortcutsBecomePathsAndCommands() {
        #expect(expand("cat #cfg") == "cat '/work/api/config.json'")
        #expect(expand("cp #api @web/src") == "cp '/home/tester/api notes.txt' '/work/web app/src'")
        #expect(expand("!build --watch") == "npm run build --watch")
        #expect(expand("time !build && open #cfg") == "time npm run build && open '/work/api/config.json'")
        #expect(expand("@api !build") == "cd '/work/api' && npm run build")
    }

    @Test func leavesUnknownShortcutsAlone() {
        #expect(expand("echo #nope !nope") == nil)
        #expect(expand("git log @{u}") == nil)
        #expect(expand("ls") == nil)
    }

    @Test func quotesForTheShell() {
        let odd = [Shortcut(kind: .file, key: "odd", name: "", value: "/tmp/it's\\here")]
        #expect(expand("cat #odd", odd) == "cat '/tmp/it'\\''s\\here'")
        #expect(Shortcuts.expand("cat #odd", in: odd) { ShellIntegration.quoted($0, for: .fish) } == "cat '/tmp/it\\'s\\\\here'")
    }
}

struct ShortcutStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "turm.tests.shortcuts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func savesValidatesAndRemoves() throws {
        try withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            var dir = Shortcut(kind: .directory, key: "@api", name: " Backend ", value: "/work/api")
            #expect(store.save(dir))
            #expect(store.save(Shortcut(kind: .file, key: "api", name: "", value: "/work/api/a.txt")))
            #expect(!store.save(Shortcut(kind: .directory, key: "API", name: "", value: "/other")))
            #expect(!store.save(Shortcut(kind: .command, key: "x", name: "", value: "   ")))
            #expect(!store.save(Shortcut(kind: .command, key: "!!", name: "", value: "ls")))
            #expect(store.save(Shortcut(kind: .command, key: "ll", name: "", value: " ls -la \n")))

            dir.key = "server"
            #expect(store.save(dir))
            #expect(store.items.map(\.token) == ["@server", "#api", "!ll"])
            #expect(store.items.last?.value == "ls -la")
            #expect(store.directory(at: "/work/api")?.name == "Backend")
            #expect(store.label(for: "/work/api/src") == "Backend/src")
            #expect(store.label(for: "/nowhere") == "/nowhere")
            #expect(ShortcutStore(defaults: defaults).items == store.items)

            store.remove(dir.id)
            #expect(ShortcutStore(defaults: defaults).items.map(\.token) == ["#api", "!ll"])
        }
    }

    @Test func migratesLegacyKnownDirectories() throws {
        try withDefaults { defaults in
            defaults.set(#"[{"key":"api","name":"Backend","path":"/work/api"}]"#, forKey: Shortcuts.legacyKey)
            let loaded = Shortcuts.load(from: defaults)
            #expect(loaded.map(\.token) == ["@api"])
            #expect(loaded.first?.value == "/work/api")
            Shortcuts.save(loaded, to: defaults)
            #expect(defaults.string(forKey: Shortcuts.legacyKey) == nil)
            #expect(Shortcuts.load(from: defaults) == loaded)
        }
    }

    @Test func ignoresCorruptData() throws {
        try withDefaults { defaults in
            defaults.set("not json", forKey: Shortcuts.key)
            #expect(Shortcuts.load(from: defaults).isEmpty)
        }
    }
}

struct ShortcutCompletionTests {
    private var environment: FakeEnvironment {
        var env = FakeEnvironment.standard
        env.shortcutList = all
        env.files["/work/api"] = [
            DirectoryEntry(name: "src", isDirectory: true),
            DirectoryEntry(name: "scripts", isDirectory: true),
            DirectoryEntry(name: "server.js", isDirectory: false),
        ]
        env.files["/work/api/src"] = [DirectoryEntry(name: "routes", isDirectory: true)]
        env.files["/work/api"]?.append(DirectoryEntry(name: "config.json", isDirectory: false))
        return env
    }

    private func complete(_ line: String) -> CompletionResult? {
        CommandCompleter.complete(line: line, cursor: line.endIndex, directory: "/work", history: [], environment: environment)
    }

    private func inserts(_ line: String) -> [String]? {
        complete(line)?.items.map(\.insert)
    }

    @Test func sigilsListTheirShortcuts() {
        #expect(inserts("@") == ["@api", "@core", "@Web"])
        #expect(inserts("cat #") == ["#api", "#cfg"])
        #expect(inserts("!") == ["!build"])
        #expect(complete("@")?.items.allSatisfy { $0.kind == .shortcut } == true)
        #expect(complete("@")?.items.first?.detail == "Backend  /work/api")
        #expect(complete("!")?.items.first?.detail == "Build  npm run build")
        #expect(complete("cat #")?.items.first?.detail == "~/api notes.txt")
    }

    @Test func completionReplacesOnlyTheShortcutWord() throws {
        let line = "tool --config=#c"
        let result = try #require(complete(line))
        #expect(String(line[result.range]) == "#c")
        #expect(result.items.map(\.insert) == ["#cfg"])
    }

    @Test func directoriesCompleteInsideCommandsAndBelowThemselves() {
        #expect(inserts("cp x @w") == ["@Web"])
        #expect(inserts("@api/s") == ["@api/scripts/", "@api/src/"])
        #expect(inserts("ls @api/src/") == ["@api/src/routes/"])
        #expect(complete("@nope/s") == nil)
    }

    @Test func completionContinuesAfterShortcuts() {
        #expect(inserts("@api ls se") == ["server.js"])
        #expect(inserts("@api g")?.contains("git") == true)
        #expect(inserts("cat #cfg | gr")?.contains("grep") == true)
    }

    @Test func highlighterMarksShortcutsAndKeepsTheRestOfTheLine() {
        let line = "@api git status #cfg"
        let spans = SyntaxHighlighter.spans(for: line, directory: "/work", environment: environment).map {
            (String((line as NSString).substring(with: $0.range)), $0.kind)
        }
        #expect(spans.contains { $0.0 == "@api" && $0.1 == .alias })
        #expect(spans.contains { $0.0 == "#cfg" && $0.1 == .alias })
        #expect(spans.contains { $0.0 == "git" && $0.1 == .command })
        #expect(!spans.contains { $0.1 == .comment })
        let unknown = SyntaxHighlighter.spans(for: "echo #nope", directory: "/work", environment: environment)
        #expect(unknown.contains { $0.kind == .comment })
    }
}

private let checkout = Shortcut(kind: .command, key: "gco", name: "", value: "git checkout {1}")
private let release = Shortcut(kind: .command, key: "rel", name: "", value: "gh release create {1} --notes {@}")
private let edit = Shortcut(kind: .command, key: "edit", name: "", value: "code {1}")
private let withArguments = all + [checkout, release, edit]

struct ShortcutArgumentTests {
    @Test func placeholdersFillFromFollowingWords() {
        #expect(expand("!gco feature", withArguments) == "git checkout feature")
        #expect(expand("!gco feature --force", withArguments) == "git checkout feature --force")
        #expect(expand("!rel v1.2 fixed crash", withArguments) == "gh release create v1.2 --notes v1.2 fixed crash")
        #expect(expand("!gco", withArguments) == "git checkout")
    }

    @Test func argumentsStopAtOperatorsAndKeepQuoting() {
        #expect(expand("!gco main && git pull", withArguments) == "git checkout main && git pull")
        #expect(expand("!gco \"my branch\"", withArguments) == "git checkout \"my branch\"")
        #expect(expand("!rel v1 | cat", withArguments) == "gh release create v1 --notes v1 | cat")
    }

    @Test func argumentsExpandTheirOwnShortcuts() {
        #expect(expand("!edit #cfg", withArguments) == "code '/work/api/config.json'")
        #expect(expand("!edit @api", withArguments) == "code '/work/api'")
        #expect(expand("@web !edit #cfg", withArguments) == "cd '/work/web app' && code '/work/api/config.json'")
    }

    @Test func placeholderSummaryAndFill() {
        #expect(checkout.placeholders == (1, false))
        #expect(release.placeholders == (1, true))
        #expect(build.placeholders == (0, false))
        #expect(Shortcuts.fill("echo {x} {2}", arguments: ["a"]) == "echo {x}")
    }

    @Test func replacementsCoverConsumedArguments() {
        let line = "!gco feature --force"
        let replacements = Shortcuts.replacements(in: line, shortcuts: withArguments, quote: posix)
        #expect(replacements.count == 1)
        #expect(replacements.first.map { String(line[$0.range]) } == "!gco feature")
        #expect(replacements.first?.text == "git checkout feature")
    }
}

struct ShortcutLaunchTests {
    @Test func leadingDirectoryPicksTheNewShellsFolder() {
        #expect(Shortcuts.launch("@api npm test", in: all) == ShortcutLaunch(directory: "/work/api", command: "npm test"))
        #expect(Shortcuts.launch("  @web/src ", in: all) == ShortcutLaunch(directory: "/work/web app/src", command: ""))
        #expect(Shortcuts.launch("@api && ls", in: all) == ShortcutLaunch(directory: "/work/api", command: "ls"))
    }

    @Test func otherLinesRunInTheCurrentFolder() {
        #expect(Shortcuts.launch("cat #cfg", in: all) == ShortcutLaunch(directory: nil, command: "cat #cfg"))
        #expect(Shortcuts.launch("!build", in: all) == ShortcutLaunch(directory: nil, command: "!build"))
        #expect(Shortcuts.launch("", in: all) == ShortcutLaunch(directory: nil, command: ""))
    }
}

struct ProjectShortcutTests {
    @Test func parsesTokensAndResolvesPaths() {
        let parsed = Shortcuts.project(
            ["#env": ".env", "@web": "apps/web", "!dev": " pnpm dev ", "@home": "~/x", "#abs": "/etc/hosts", "bad": "x", "@": "y", "!empty": " "],
            root: "/repo", home: "/home/tester"
        )
        let byToken = Dictionary(uniqueKeysWithValues: parsed.shortcuts.map { ($0.token, $0.value) })
        #expect(byToken == ["#env": "/repo/.env", "@web": "/repo/apps/web", "!dev": "pnpm dev", "@home": "/home/tester/x", "#abs": "/etc/hosts"])
        #expect(parsed.shortcuts.allSatisfy { $0.projectRoot == "/repo" })
        #expect(Set(parsed.invalid) == ["bad", "@", "!empty"])
    }

    @Test func projectShortcutsOverrideGlobalOnes() {
        let local = Shortcut(kind: .file, key: "CFG", name: "", value: "/repo/cfg.json", projectRoot: "/repo")
        let merged = Shortcuts.merged(all, project: [local])
        #expect(Shortcuts.find("cfg", kind: .file, in: merged) == local)
        #expect(merged.count == all.count)
        #expect(Shortcuts.merged(all, project: []) == all)
    }

    @Test func turmJsonShortcutsReachTheSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ##"{"shortcuts": {"#env": ".env", "!dev": "pnpm dev", "nope": "x"}}"##
            .write(to: root.appendingPathComponent("Turm.json"), atomically: true, encoding: .utf8)
        let snapshot = ProjectDetection.snapshot(for: root.path, home: "/nonexistent-home")
        #expect(snapshot.shortcuts.map(\.token).sorted() == ["!dev", "#env"])
        #expect(snapshot.shortcuts.first { $0.kind == .file }?.value.hasSuffix("/.env") == true)
        #expect(snapshot.notice == "Turm.json: invalid shortcut nope")
    }

    @Test func missingOnlyAppliesToPaths() {
        #expect(config.isMissing { _ in false })
        #expect(!config.isMissing { _ in true })
        #expect(!build.isMissing { _ in false })
    }

    @Test func highlighterFlagsMissingPaths() {
        var env = FakeEnvironment.standard
        env.shortcutList = [config]
        let line = "cat #cfg"
        let spans = SyntaxHighlighter.spans(for: line, directory: "/work", environment: env)
        #expect(spans.contains { $0.range == NSRange(location: 4, length: 4) && $0.kind == .error })
        env.files["/work/api"] = [DirectoryEntry(name: "config.json", isDirectory: false)]
        let found = SyntaxHighlighter.spans(for: line, directory: "/work", environment: env)
        #expect(found.contains { $0.range == NSRange(location: 4, length: 4) && $0.kind == .alias })
    }
}
