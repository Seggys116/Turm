import Foundation
import Testing
@testable import Turm

@Suite(.serialized)
struct ProjectActionTests {
    private func project(_ files: [String: String], directories: [String] = []) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in directories {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for (name, contents) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root.path
    }

    private func snapshot(_ path: String) -> ProjectSnapshot {
        ProjectDetection.snapshot(for: path, home: FileManager.default.temporaryDirectory.path)
    }

    private func command(_ id: String, in snapshot: ProjectSnapshot, selection: [String: Int] = [:]) throws -> String {
        let action = try #require(snapshot.actions.first { $0.id == id })
        return snapshot.commandLine(for: action, selection: selection, from: action.root)
    }

    @Test func emptyDirectoryHasNoActions() throws {
        let path = try project([:])
        #expect(snapshot(path).isEmpty)
    }

    @Test func cargoBinaryOffersProfileToggle() throws {
        let path = try project(["Cargo.toml": "[package]\nname = \"x\"\n", "src/main.rs": "fn main() {}"])
        let found = snapshot(path)
        #expect(found.ecosystems.map(\.title) == ["Cargo"])
        #expect(try command("cargo.build", in: found) == "cargo build")
        #expect(try command("cargo.run", in: found, selection: ["cargo-profile": 1]) == "cargo run --release")
        #expect(found.featured.map(\.title) == ["Build", "Run", "Test", "Clean"])
    }

    @Test func cargoLibraryHasNoRunAction() throws {
        let path = try project(["Cargo.toml": "[package]\nname = \"x\"\n", "src/lib.rs": ""])
        #expect(!snapshot(path).actions.contains { $0.id == "cargo.run" })
    }

    @Test func cargoWorkspaceTargetsEveryMember() throws {
        let path = try project(["Cargo.toml": "[workspace]\nmembers = [\"a\"]\n"])
        let found = snapshot(path)
        #expect(try command("cargo.test", in: found) == "cargo test --workspace")
        #expect(!found.actions.contains { $0.id == "cargo.run" })
    }

    @Test func swiftPackageRunsOnlyWithExecutable() throws {
        let library = try project(["Package.swift": "let package = Package(targets: [.target(name: \"A\")])"])
        #expect(!snapshot(library).actions.contains { $0.id == "swiftpm.run" })
        let tool = try project(["Package.swift": "let package = Package(targets: [.executableTarget(name: \"A\")])"])
        let found = snapshot(tool)
        #expect(try command("swiftpm.run", in: found, selection: ["swift-configuration": 1]) == "swift run -c release")
    }

    @Test func xcodeProjectUsesItsNameAsScheme() throws {
        let path = try project([:], directories: ["My App.xcodeproj"])
        let found = snapshot(path)
        #expect(try command("xcode.build", in: found) == "xcodebuild -project 'My App.xcodeproj' -scheme 'My App' -configuration Debug build")
    }

    @Test func makeTargetsAreParsedAndClassified() throws {
        let makefile = """
        CC := gcc
        .PHONY: all clean
        all: main.o
        \t$(CC) -o app main.o
        test: all
        \t./app --test
        clean:
        \trm -f app
        deploy-prod:
        \t./deploy
        %.o: %.c
        \t$(CC) -c $<
        """
        #expect(BuildSystemDetectors.makeTargets(in: makefile) == ["all", "test", "clean", "deploy-prod"])
        let found = snapshot(try project(["Makefile": makefile]))
        #expect(try command("make.t.all", in: found) == "make all")
        #expect(found.featured.map(\.title) == ["Build", "Test", "Clean"])
        #expect(found.actions.first { $0.id == "make.t.deploy-prod" }?.category == .other)
    }

    @Test func cmakeConfiguresBeforeBuilding() throws {
        let found = snapshot(try project(["CMakeLists.txt": "project(x)"]))
        let build = try command("cmake.build", in: found, selection: ["cmake-config": 1])
        #expect(build == "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release")
    }

    @Test func nodeUsesLockfileManagerAndSkipsPlaceholderTest() throws {
        let manifest = """
        {"scripts":{"dev":"next dev","build":"next build","test":"echo \\"Error: no test specified\\" && exit 1","lint":"eslint ."},
         "dependencies":{"next":"14.0.0"}}
        """
        let found = snapshot(try project(["package.json": manifest, "pnpm-lock.yaml": ""]))
        #expect(found.ecosystems.map(\.title) == ["Next.js \u{00B7} pnpm"])
        #expect(try command("node.s.dev", in: found) == "pnpm run dev")
        #expect(!found.actions.contains { $0.id == "node.s.test" })
        #expect(found.actions.first { $0.id == "node.s.lint" }?.category == .check)
        #expect(found.featured.first?.id == "node.install")
    }

    @Test func nodeFallsBackToFrameworkBinary() throws {
        let manifest = #"{"dependencies":{"vite":"5.0.0"}}"#
        let found = snapshot(try project(["package.json": manifest, "bun.lock": ""], directories: ["node_modules"]))
        #expect(try command("node.fw.dev", in: found) == "bunx vite")
        #expect(try command("node.fw.build", in: found) == "bunx vite build")
    }

    @Test func tauriBorrowsTheJavaScriptToolchain() throws {
        let manifest = #"{"devDependencies":{"@tauri-apps/cli":"2.0.0"}}"#
        let found = snapshot(try project(["package.json": manifest, "yarn.lock": "", "src-tauri/tauri.conf.json": "{}"]))
        #expect(try command("tauri.dev", in: found) == "yarn tauri dev")
        #expect(try command("tauri.build", in: found, selection: ["tauri-bundle": 1]) == "yarn tauri build --debug")
    }

    @Test func pythonPrefersUvAndPytest() throws {
        let found = snapshot(try project(["pyproject.toml": "[tool.uv]\n[tool.pytest.ini_options]\n", "uv.lock": ""]))
        #expect(try command("python.install", in: found) == "uv sync")
        #expect(try command("python.test", in: found) == "uv run pytest")
    }

    @Test func goRaceToggleAppliesToTests() throws {
        let found = snapshot(try project(["go.mod": "module x", "main.go": "package main"]))
        #expect(try command("go.test", in: found) == "go test ./...")
        #expect(try command("go.test", in: found, selection: ["go-race": 1]) == "go test -race ./...")
        #expect(try command("go.run", in: found) == "go run .")
    }

    @Test func justAndTaskRecipesAreListed() throws {
        let just = snapshot(try project(["justfile": "version := \"1\"\nbuild:\n  cargo build\ndeploy target:\n  ./d {{target}}\ntest:\n  cargo test\n"]))
        #expect(just.actions.map(\.id) == ["just.r.build", "just.r.test"])
        let task = snapshot(try project(["Taskfile.yml": "version: '3'\ntasks:\n  build:\n    cmds: [go build]\n  lint:\n    cmds: [x]\nvars:\n  other: 1\n"]))
        #expect(task.actions.map(\.id) == ["task.r.build", "task.r.lint"])
    }

    @Test func dockerComposeOffersUp() throws {
        let found = snapshot(try project(["compose.yaml": "services: {}"]))
        #expect(try command("docker.up", in: found) == "docker compose up")
    }

    @Test func detectionWalksUpToTheProjectRoot() throws {
        let path = try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "src/deep/keep": ""])
        let found = snapshot((path as NSString).appendingPathComponent("src/deep"))
        let build = try #require(found.actions.first { $0.id == "cargo.build" })
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        #expect(build.root == standard)
        #expect(found.commandLine(for: build, selection: [:], from: standard + "/src/deep") == "cd '\(standard)' && cargo build")
    }

    @Test func homeFolderIsNotSearchedFromBelow() throws {
        let home = try project(["Makefile": "all:\n\techo\n"], directories: ["work"])
        let found = ProjectDetection.snapshot(for: (home as NSString).appendingPathComponent("work"), home: home)
        #expect(found.isEmpty)
    }

    @Test func manifestAddsActionsOverridesAndHides() throws {
        let manifest = """
        {
          "hide": ["cargo.fmt"],
          "variants": [{"id": "env", "title": "Env", "options": ["dev", {"label": "Prod", "value": "production"}]}],
          "actions": [
            {"id": "cargo.clean", "title": "Deep clean", "command": "cargo clean && rm -rf dist", "category": "clean"},
            {"title": "Deploy", "command": "./deploy.sh {env}", "icon": "paperplane", "env": {"TOKEN": "a b"}},
            {"title": "", "command": "ignored"}
          ]
        }
        """
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "Turm.json": manifest]))
        #expect(!found.actions.contains { $0.id == "cargo.fmt" })
        #expect(found.actions.first?.title == "Deploy")
        #expect(found.ecosystems.first?.id == "project")
        #expect(try command("cargo.clean", in: found) == "cargo clean && rm -rf dist")
        #expect(try command("turm.1", in: found, selection: ["env": 1]) == "env TOKEN='a b' ./deploy.sh production")
        #expect(try command("turm.1", in: found) == "env TOKEN='a b' ./deploy.sh dev")
        #expect(found.manifestPath?.hasSuffix("Turm.json") == true)
    }

    @Test func manifestCanReplaceDetection() throws {
        let manifest = #"{"inherit": false, "actions": [{"title": "Only", "command": "true"}]}"#
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "Turm.json": manifest]))
        #expect(found.actions.map(\.title) == ["Only"])
    }

    @Test func manifestAloneShowsTheBar() throws {
        let found = snapshot(try project(["Turm.json": #"{"actions": [{"title": "Go", "command": "make go"}]}"#]))
        #expect(!found.isEmpty)
        #expect(found.actions.first?.featured == true)
    }

    @Test func brokenManifestReportsNoticeButKeepsDetection() throws {
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "Turm.json": "{ nope"]))
        #expect(found.notice?.hasPrefix("Turm.json:") == true)
        #expect(found.actions.contains { $0.id == "cargo.build" })
    }

    @Test func variantChoicesPersistPerProject() throws {
        let suite = UserDefaults(suiteName: "turm.tests.\(UUID().uuidString)")!
        let variant = ProjectVariant(id: "p", title: "P", ecosystem: "x", options: [.init(label: "A", value: ""), .init(label: "B", value: "b")])
        VariantStore.save(index: 1, variant: "p", roots: ["/x"], defaults: suite)
        #expect(VariantStore.load(roots: ["/x"], variants: [variant], defaults: suite) == ["p": 1])
        #expect(VariantStore.load(roots: ["/y"], variants: [variant], defaults: suite).isEmpty)
    }

    @Test func classifierUsesLeadingWord() {
        #expect(ActionClassifier.category(forName: "test:unit") == .test)
        #expect(ActionClassifier.category(forName: "build-release") == .build)
        #expect(ActionClassifier.category(forName: "lint") == .check)
        #expect(ActionClassifier.category(forName: "seed-db") == .other)
    }

    private func resolved(_ found: ProjectSnapshot, _ preferences: StatusBarPreferences = StatusBarPreferences()) -> ResolvedBar {
        ResolvedBar.resolve(found, preferences: preferences)
    }

    @Test func eachDetectedEcosystemGetsItsOwnGroup() throws {
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "Makefile": "all:\n\techo\n"]))
        let bar = resolved(found)
        #expect(bar.groups.map(\.id) == ["cargo", "make"])
        #expect(bar.groups[0].variants.map(\.id) == ["cargo-profile"])
        #expect(bar.groups[0].shownVariants.map(\.id) == ["cargo-profile"])
    }

    @Test func selectorNeedsSeveralToolsAndNoManifest() throws {
        let both = resolved(snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "Makefile": "all:\n\techo\n"])))
        let shown = both.display(choice: "make")
        #expect(shown.selector.map(\.id) == ["cargo", "make"])
        #expect(shown.active?.id == "make")
        #expect(shown.pinned.allSatisfy { $0.ecosystem == "make" })
        #expect(both.display(choice: "gone").active?.id == "cargo")

        let single = resolved(snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": ""])))
        #expect(single.display(choice: nil).selector.isEmpty)
        #expect(single.display(choice: nil).pinned.map(\.id) == ["cargo.build", "cargo.run", "cargo.test", "cargo.clean"])

        let withManifest = resolved(snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "Makefile": "all:\n\techo\n", "Turm.json": "{}"])))
        let all = withManifest.display(choice: nil)
        #expect(all.selector.isEmpty && all.active == nil)
        #expect(Set(all.pinned.map(\.ecosystem)) == ["cargo", "make"])
    }

    @Test func customActionsStayVisibleNextToTheSelectedTool() throws {
        let manifest = #"{"actions": [{"title": "Go", "command": "true"}]}"#
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "Turm.json": manifest]))
        let shown = resolved(found).display(choice: nil)
        #expect(shown.selector.isEmpty)
        #expect(shown.pinned.first?.title == "Go")
    }

    @Test func barItemsFollowThePreferenceOrder() throws {
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": ""]))
        var preferences = StatusBarPreferences()
        preferences.setItems(["cargo.test", "cargo.clippy", "cargo.build"], for: "cargo")
        var group = try #require(resolved(found, preferences).groups.first)
        #expect(group.pinned.map(\.id) == ["cargo.test", "cargo.clippy", "cargo.build"])
        #expect(group.shownVariants.isEmpty)

        preferences.setItems(["cargo-profile", "cargo.run", "missing"], for: "cargo")
        group = try #require(resolved(found, preferences).groups.first)
        #expect(group.pinned.map(\.id) == ["cargo.run"])
        #expect(group.shownVariants.map(\.id) == ["cargo-profile"])
    }

    @Test func disabledEcosystemLeavesTheBar() throws {
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "go.mod": "module x"]))
        var preferences = StatusBarPreferences()
        preferences.ecosystems["cargo"] = EcosystemPreference()
        preferences.ecosystems["cargo"]?.enabled = false
        #expect(resolved(found, preferences).groups.map(\.id) == ["go"])
    }

    @Test func projectOverridesWin() throws {
        let manifest = """
        {"bar": {"pinned": ["cargo.test", "cargo.build"], "icons": {"cargo.build": "star"}, "titles": "never",
                 "subShell": false, "order": ["options", "actions"],
                 "ecosystems": {"cargo": {"title": "Rust", "icon": "gear"}}}}
        """
        let found = snapshot(try project(["Cargo.toml": "[package]\n", "src/main.rs": "", "Turm.json": manifest]))
        var preferences = StatusBarPreferences()
        preferences.runInSubShell = true
        let bar = resolved(found, preferences)
        #expect(bar.display(choice: nil).pinned.map(\.id) == ["cargo.test", "cargo.build"])
        #expect(!bar.subShell && bar.titles == .never)
        #expect(bar.order == [.options, .actions])
        #expect(bar.groups.first?.title == "Rust" && bar.groups.first?.symbol == "gear")
        let action = try #require(found.actions.first { $0.id == "cargo.build" })
        #expect(bar.symbol(for: action) == "star")
    }

    @Test func preferencesRoundTripAndTolerateJunk() {
        var preferences = StatusBarPreferences()
        #expect(preferences.runInSubShell)
        preferences.order = [.options]
        preferences.setItems(["a"], for: "node")
        let decoded = StatusBarPreferences(rawValue: preferences.rawValue)
        #expect(decoded?.order == [.options, .actions])
        #expect(decoded?.items(for: "node", defaults: []) == ["a"])
        #expect(StatusBarPreferences(rawValue: "{\"order\": [\"ecosystems\", \"options\"]}")?.order == [.options, .actions])
        #expect(StatusBarPreferences(rawValue: "{}")?.runInSubShell == true)
        #expect(StatusBarPreferences(rawValue: "not json") == nil)
    }

    @Test func catalogListsEveryDetector() {
        let ids = EcosystemCatalog.entries.map(\.id)
        #expect(ids.count == 24)
        #expect(EcosystemCatalog.entry("cargo")?.actions.contains { $0.id == "cargo.clippy" } == true)
        #expect(EcosystemCatalog.entry("go")?.variants.map(\.id) == ["go-race"])
        #expect(EcosystemCatalog.entry("go")?.defaultItems.last == "go-race")
        #expect(EcosystemCatalog.entries.allSatisfy { !$0.defaultItems.isEmpty })
    }

    @Test func toolChoicePersistsPerProject() {
        let suite = UserDefaults(suiteName: "turm.tests.\(UUID().uuidString)")!
        ToolChoiceStore.save("make", roots: ["/x"], defaults: suite)
        #expect(ToolChoiceStore.load(roots: ["/x"], defaults: suite) == "make")
        #expect(ToolChoiceStore.load(roots: ["/y"], defaults: suite) == nil)
    }

    @Test func resultFlashFadesOnSuccessAndPulsesOnFailure() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var progress = ActionProgress(startedAt: start)
        #expect(progress.successOpacity(at: start.addingTimeInterval(5)) == 0)
        #expect(progress.pulse(at: start.addingTimeInterval(5)) == 0)

        progress.finishedAt = start.addingTimeInterval(30)
        progress.outcome = .succeeded
        #expect(progress.successOpacity(at: start.addingTimeInterval(30.5)) == 1)
        #expect(progress.successOpacity(at: start.addingTimeInterval(31)) < 1)
        #expect(progress.isSettled(at: start.addingTimeInterval(33)))
        #expect(progress.successOpacity(at: start.addingTimeInterval(33)) == 0)

        progress.outcome = .failed
        #expect(progress.pulse(at: start.addingTimeInterval(31)) > 0)
        #expect(progress.pulse(at: start.addingTimeInterval(60)) == 0.35)
        #expect(!progress.isSettled(at: start.addingTimeInterval(60)))
    }

    @MainActor
    @Test func poppedOutActionShellBecomesItsOwnTab() {
        let workspace = Workspace(closeCoordinator: CloseCoordinator { _ in true })
        defer { workspace.terminateAll() }
        let hidden = TerminalSession(directory: NSTemporaryDirectory(), auxiliary: true)
        #expect(hidden.isAuxiliary)

        workspace.adopt(hidden)

        #expect(workspace.tabs.count == 2)
        #expect(workspace.focusedSession === hidden)
        #expect(!hidden.isAuxiliary)
        #expect(workspace.activeTabID == workspace.tabs[1].id)
    }
}
