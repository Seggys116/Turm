import Foundation
import Testing
@testable import TurmCore

struct RunningProgramTests {
    private func icon(_ command: String) -> String? {
        RunningProgram.resolve(command: command)?.iconKey
    }

    @Test func plainCommand() {
        #expect(icon("claude") == "claude")
        #expect(icon("claude --resume") == "claude")
        #expect(RunningProgram.resolve(command: "codex")?.name == "Codex")
        #expect(icon("codex") == "codex")
        #expect(icon("conda activate base") == "anaconda")
    }

    @Test func environmentAssignmentsAreSkipped() {
        #expect(icon("FOO=1 BAR='a b' claude") == "claude")
        #expect(icon("NODE_ENV=production node server.js") == "nodejs")
    }

    @Test func wrappersAreSeenThrough() {
        #expect(icon("sudo brew upgrade") == "homebrew")
        #expect(RunningProgram.resolve(command: "sudo -u root git pull")?.name == "Git")
        #expect(RunningProgram.resolve(command: "env FOO=1 cargo build")?.name == "Rust")
        #expect(icon("time nohup docker compose up") == "docker")
        #expect(icon("caffeinate -i claude") == "claude")
        #expect(RunningProgram.resolve(command: "nice -n 10 make")?.name == "GNU")
    }

    @Test func packageRunnerPrefersAKnownInnerTool() {
        #expect(icon("npx vite") == "vite")
        #expect(icon("npx -y @anthropic-ai/claude-code@latest") == "claude")
        #expect(icon("pnpm dlx vitest run") == "vitest")
        #expect(icon("bunx @openai/codex") == "codex")
        #expect(icon("bundle exec rails server") == "rubyonrails")
    }

    @Test func packageRunnerFallsBackToTheRunner() {
        #expect(icon("npx create-react-app demo") == "npm")
        #expect(icon("pnpm exec something") == "pnpm")
        #expect(icon("uvx ruff check") == "uv")
        #expect(icon("poetry run script") == "poetry")
    }

    @Test func uvRun() {
        #expect(icon("uv run pytest -q") == "pytest")
        #expect(icon("uv run --with rich python app.py") == "python")
        #expect(icon("uv run main.py") == "uv")
        #expect(icon("uv sync") == "uv")
    }

    @Test func pythonModulesAndScripts() {
        #expect(icon("python3 -m pytest") == "pytest")
        #expect(icon("python manage.py runserver") == "django")
        #expect(icon("python3.12 script.py") == "python")
        #expect(icon("node /opt/tools/claude") == "claude")
        #expect(icon("node server.js") == "nodejs")
    }

    @Test func pathsUseTheBasename() {
        #expect(icon("/opt/homebrew/bin/claude") == "claude")
        #expect(icon("./node_modules/.bin/vite --host") == "vite")
        #expect(RunningProgram.resolve(command: "~/.local/bin/aider")?.name == "Aider")
    }

    @Test func chainsPickTheFirstKnownProgram() {
        #expect(icon("cd app && claude") == "claude")
        #expect(icon("export A=1; source env.sh; npm run dev") == "npm")
        #expect(RunningProgram.resolve(command: "git log | less")?.name == "Git")
        #expect(icon("echo hi || docker ps") == "docker")
        #expect(RunningProgram.resolve(command: "make 2>&1 | tee log")?.name == "GNU")
    }

    @Test func quotedSeparatorsDoNotSplit() {
        #expect(icon("echo 'a && claude'") == nil)
    }

    @Test func githubCopilotIsDistinctFromGitHubCLI() {
        #expect(RunningProgram.resolve(command: "gh copilot suggest")?.name == "GitHub Copilot")
        #expect(icon("gh copilot") == "githubcopilot")
        #expect(icon("gh pr list") == "github")
    }

    @Test func symbolOnlyEntriesHaveNoAsset() {
        let program = RunningProgram.resolve(command: "ssh host")
        #expect(program?.iconKey == nil)
        #expect(program?.symbol == "network")
        #expect(RunningProgram.resolve(command: "htop")?.symbol == "gauge.with.dots.needle.33percent")
    }

    @Test func everyIconKeyIsSourcedByTheIconManifest() throws {
        let root = try #require(SVGPathTests.repositoryRoot())
        let manifest = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: root.appendingPathComponent("Icons/manifest.json")))
        let sourced = Set(manifest.values.flatMap(\.keys))
        #expect(RunningProgram.iconKeys.subtracting(sourced).isEmpty)
        #expect(sourced.subtracting(RunningProgram.iconKeys).isEmpty)
    }

    @Test func unknownAndEmptyResolveToNothing() {
        #expect(RunningProgram.resolve(command: "./build-it --fast") == nil)
        #expect(RunningProgram.resolve(command: "cd /tmp") == nil)
        #expect(RunningProgram.resolve(command: "") == nil)
        #expect(RunningProgram.resolve(command: "   ") == nil)
        #expect(RunningProgram.resolve(command: "FOO=1") == nil)
    }

    @Test func creativeCommonsLogosFallBackToSymbols() {
        for command in ["git status", "yarn", "godot", "cargo build", "zig build", "ruby x.rb", "php artisan serve", "nvim x", "make", "nix-shell", "nixos-rebuild switch"] {
            let program = RunningProgram.resolve(command: command)
            #expect(program != nil, "\(command)")
            #expect(program?.iconKey == nil, "\(command)")
        }
    }

    @Test func ecosystemIconKeys() {
        #expect(icon("just build") == "just")
        #expect(icon("task lint") == "task")
        #expect(icon("aider") == nil)
    }

    @Test func displayedProgramFollowsTheRunningCommandThenTheLastFinishedOne() {
        let claude = RunningProgram.resolve(command: "claude")
        #expect(RunningProgram.displayed(isRunning: true, running: claude, lastCommand: "git status") == claude)
        #expect(RunningProgram.displayed(isRunning: true, running: nil, lastCommand: "git status") == nil)
        #expect(RunningProgram.displayed(isRunning: false, running: claude, lastCommand: "git status")?.name == "Git")
        #expect(RunningProgram.displayed(isRunning: false, running: nil, lastCommand: "claude --resume") == claude)
        #expect(RunningProgram.displayed(isRunning: false, running: claude, lastCommand: "./build-it") == nil)
        #expect(RunningProgram.displayed(isRunning: false, running: claude, lastCommand: nil) == nil)
    }

    @Test func foregroundProcessResolvesFromArguments() {
        #expect(RunningProgram.resolve(arguments: ["node", "/usr/lib/claude", "--flag"])?.iconKey == "claude")
        #expect(RunningProgram.resolve(arguments: ["vim", "notes.txt"])?.iconKey == "vim")
    }

    @Test func programsRoundTripThroughCodable() throws {
        let program = try #require(RunningProgram.resolve(command: "cargo build"))
        let decoded = try JSONDecoder().decode(RunningProgram.self, from: JSONEncoder().encode(program))
        #expect(decoded == program)
    }
}
