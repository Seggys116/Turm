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
        #expect(found.kinds == ["Cargo"])
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
        #expect(found.kinds == ["Next.js \u{00B7} pnpm"])
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
        #expect(found.kinds.first == "Turm.json")
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
        let variant = ProjectVariant(id: "p", title: "P", options: [.init(label: "A", value: ""), .init(label: "B", value: "b")])
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
}
