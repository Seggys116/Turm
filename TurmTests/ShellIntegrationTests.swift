import Foundation
import Testing
import TurmCore
@testable import Turm

private let fishPath = (
    [ProcessInfo.processInfo.environment["TURM_TEST_FISH"]].compactMap { $0 }
        + ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
).first {
    FileManager.default.isExecutableFile(atPath: $0)
}

@MainActor
private func wait(timeout: Duration = .seconds(20), until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor
private func makeSession(shell: String) -> TerminalSession {
    let previous = getenv("HISTFILE").map { String(cString: $0) }
    setenv("HISTFILE", "/dev/null", 1)
    ShellIntegration.forcedShell = shell
    defer {
        ShellIntegration.forcedShell = nil
        if let previous { setenv("HISTFILE", previous, 1) } else { unsetenv("HISTFILE") }
    }
    return TerminalSession()
}

@MainActor
private func finished(_ session: TerminalSession, _ count: Int) async throws -> Block {
    let done = await wait { session.phase == .ready && session.blocks.count == count && session.blocks[count - 1].isRunning == false }
    try #require(done)
    return session.blocks[count - 1]
}

@MainActor
private func run(_ command: String, shell: String) async throws -> Block {
    let session = makeSession(shell: shell)
    defer { session.terminate() }
    #expect(await wait { session.phase == .ready })
    session.submit(command)
    #expect(await wait { session.blocks.first?.isRunning == false })
    return try #require(session.blocks.first)
}

@MainActor
private func exportReachesCompletion(shell: String, name: String) async throws {
    let session = makeSession(shell: shell)
    defer { session.terminate() }
    let environment = SystemCompletionEnvironment()
    session.completionEnvironment = environment
    session.setPaneFocused(true)
    #expect(await wait { session.phase == .ready })
    let command = shell.hasSuffix("fish") ? "set -gx \(name) 'a=b c'" : "export \(name)='a=b c'"
    session.submit(command)
    _ = try await finished(session, 1)
    #expect(await wait { session.liveEnvironment?[name] == "a=b c" })
    #expect(await wait { environment.processEnvironment()[name] == "a=b c" })
    session.submit("true")
    _ = try await finished(session, 2)
    #expect(environment.processEnvironment()[name] == "a=b c")
}

@MainActor
private func exercise(shell: String) async throws {
    let session = makeSession(shell: shell)
    defer { session.terminate() }
    #expect(await wait { session.phase == .ready })

    session.submit("echo hello; false")
    let first = try await finished(session, 1)
    #expect(first.plainOutput == "hello")
    #expect(first.exitCode == 1)

    session.submit("true")
    let second = try await finished(session, 2)
    #expect(second.exitCode == 0)
    #expect(second.plainOutput == "")

    session.submit("cd /tmp && pwd")
    let third = try await finished(session, 3)
    #expect(third.plainOutput.hasSuffix("/tmp"))
    #expect(session.directory.hasSuffix("/tmp"))

    let loop = shell.hasSuffix("fish") ? "for i in 1 2\n  echo n$i\nend" : "for i in 1 2\ndo echo n$i\ndone"
    session.submit(loop)
    let fourth = try await finished(session, 4)
    #expect(fourth.plainOutput == "n1\nn2")
    #expect(fourth.exitCode == 0)
}

@MainActor
struct BashIntegrationTests {
    @Test func exitCodesMultiLineAndCwdOnBash32() async throws {
        try await exercise(shell: "/bin/bash")
    }

    @Test func multiLineCommandWithHeredocAndQuotes() async throws {
        let block = try await run("cat <<EOF | tr '\\t' '#'\nit's \"quoted\"\n\ttabbed\nEOF", shell: "/bin/bash")
        #expect(block.plainOutput == "it's \"quoted\"\n#tabbed")
        #expect(block.exitCode == 0)
    }

    @Test func promptsStayQuiet() async throws {
        let block = try await run("printf '[%s][%s]' \"$PS1\" \"$PS2\"", shell: "/bin/bash")
        #expect(block.plainOutput == "[][]")
    }

    @Test func commandStartFiresOncePerCommand() async throws {
        let block = try await run("echo a; echo b; echo c", shell: "/bin/bash")
        #expect(block.plainOutput == "a\nb\nc")
        #expect(block.exitCode == 0)
    }

    @Test func historyFileComesFromTheEnvironment() async throws {
        let block = try await run("printf '%s' \"$HISTFILE\"", shell: "/bin/bash")
        #expect(block.plainOutput == "/dev/null")
    }

    @Test func recordedHistoryHoldsTheCommandNotTheSourceLine() async throws {
        let session = makeSession(shell: "/bin/bash")
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })
        session.submit("echo marker-one")
        _ = try await finished(session, 1)
        session.submit("history | grep -c marker-one")
        let count = try await finished(session, 2)
        #expect(count.plainOutput == "1")
    }

    @Test func exportedVariablesReachCompletion() async throws {
        try await exportReachesCompletion(shell: "/bin/bash", name: "TURM_LIVE_BASH")
    }

    @Test func launchDescribesBashSubmission() throws {
        ShellIntegration.forcedShell = "/bin/bash"
        defer { ShellIntegration.forcedShell = nil }
        let launch = try ShellIntegration.launch()
        #expect(launch.executable == "/bin/bash")
        #expect(launch.arguments.first == "--rcfile")
        #expect(launch.arguments.last == "-i")
        guard case .sourceFile(let url) = launch.submission else {
            Issue.record("bash must submit through a command file")
            return
        }
        #expect(launch.environment.contains("TURM_CMD_FILE=\(url.path)"))
        let payload = try launch.submission.payload(for: "echo hi\necho there")
        #expect(String(decoding: payload, as: UTF8.self) == " . '\(url.path)'\r")
        #expect(try String(contentsOf: url, encoding: .utf8) == "echo hi\necho there\n")
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
struct ZshIntegrationTests {
    @Test func exportedVariablesReachCompletion() async throws {
        try await exportReachesCompletion(shell: "/bin/zsh", name: "TURM_LIVE_ZSH")
    }
}

struct EnvironmentEventTests {
    private func frame(_ entries: [String], terminator: String = "\u{07}") -> [UInt8] {
        var raw = Data()
        for entry in entries {
            raw.append(Data(entry.utf8))
            raw.append(0)
        }
        return Array(("\u{1B}]7777;E;" + raw.base64EncodedString() + terminator).utf8)
    }

    private func events(_ bytes: [UInt8]) -> [StreamPiece] {
        var parser = ShellStreamParser()
        return parser.consume(bytes)
    }

    @Test func decodesMultipleVariablesAndEqualsInValues() {
        let pieces = events(frame(["PATH=/usr/bin:/bin", "KUBECONFIG=/a b/c", "EXPR=a=b=c", "EMPTY="]))
        #expect(pieces == [.event(.environment([
            "PATH": "/usr/bin:/bin", "KUBECONFIG": "/a b/c", "EXPR": "a=b=c", "EMPTY": "",
        ]))])
    }

    @Test func valuesKeepNewlinesAndUnicode() {
        let pieces = events(frame(["MULTI=one\ntwo", "NAME=caf\u{E9} \u{1F600}"]))
        #expect(pieces == [.event(.environment(["MULTI": "one\ntwo", "NAME": "caf\u{E9} \u{1F600}"]))])
    }

    @Test func dropsInvalidKeysAndEntriesWithoutEquals() {
        let pieces = events(frame(["GOOD=1", "1BAD=2", "BASH_FUNC_x%%=() { :; }", "NOEQUALS", "=novalue", "with space=3", "_ok9=4"]))
        #expect(pieces == [.event(.environment(["GOOD": "1", "_ok9": "4"]))])
    }

    @Test func garbageYieldsAnEmptyEnvironmentAndLeaksNothing() {
        let pieces = events(Array("\u{1B}]7777;E;!!!not base64!!!\u{07}tail".utf8))
        #expect(pieces == [.event(.environment([:])), .output(Array("tail".utf8))])
        #expect(events(Array("\u{1B}]7777;E\u{07}x".utf8)) == [.event(.environment([:])), .output(Array("x".utf8))])
    }

    @Test func acceptsTheStringTerminator() {
        let pieces = events(frame(["A=1"], terminator: "\u{1B}\\"))
        #expect(pieces == [.event(.environment(["A": "1"]))])
    }

    @Test func survivesArbitraryChunking() {
        let bytes = frame(["ONE=1", "TWO=2"]) + Array("after".utf8)
        var parser = ShellStreamParser()
        var pieces: [StreamPiece] = []
        for byte in bytes { pieces += parser.consume([byte]) }
        #expect(pieces.contains(.event(.environment(["ONE": "1", "TWO": "2"]))))
        let text = pieces.compactMap { piece -> String? in
            if case .output(let data) = piece { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(text == "after")
    }

    @Test func largeButAllowedPayloadIsDecoded() {
        let value = String(repeating: "x", count: 150_000)
        let pieces = events(frame(["BIG=" + value]))
        #expect(pieces == [.event(.environment(["BIG": value]))])
    }

    @Test func hugePayloadIsSkippedWithoutLeakingBytes() {
        let filler = [UInt8](repeating: 0x41, count: 600_000)
        let bytes = Array("\u{1B}]7777;E;".utf8) + filler + [0x07] + Array("after".utf8)
        let pieces = events(bytes)
        #expect(pieces == [.output(Array("after".utf8))])
    }

    @Test func environmentMarkersNeverReachTheOutput() {
        let bytes = Array("before".utf8) + frame(["A=1"]) + Array("after".utf8)
        let pieces = events(bytes)
        let text = pieces.compactMap { piece -> String? in
            if case .output(let data) = piece { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(text == "beforeafter")
    }
}

@MainActor
struct ShellSelectionTests {
    @Test func recognisesSupportedShells() {
        #expect(ShellIntegration.Kind(path: "/bin/zsh") == .zsh)
        #expect(ShellIntegration.Kind(path: "/opt/homebrew/bin/bash") == .bash)
        #expect(ShellIntegration.Kind(path: "/usr/local/bin/fish") == .fish)
        #expect(ShellIntegration.Kind(path: "/bin/tcsh") == nil)
    }

    @Test func zshKeepsBracketedPaste() throws {
        ShellIntegration.forcedShell = "/bin/zsh"
        defer { ShellIntegration.forcedShell = nil }
        let launch = try ShellIntegration.launch()
        #expect(launch.arguments.isEmpty)
        #expect(launch.execName == "-zsh")
        let payload = try launch.submission.payload(for: "ls")
        #expect(payload == Array("\u{1B}[200~ls\u{1B}[201~\r".utf8))
    }
}

@MainActor
@Suite(.enabled(if: fishPath != nil))
struct FishIntegrationTests {
    @Test func exitCodesMultiLineAndCwd() async throws {
        try await exercise(shell: try #require(fishPath))
    }

    @Test func exportedVariablesReachCompletion() async throws {
        try await exportReachesCompletion(shell: try #require(fishPath), name: "TURM_LIVE_FISH")
    }

    @Test func promptsStayQuiet() async throws {
        let block = try await run("fish_prompt; fish_right_prompt; echo done", shell: try #require(fishPath))
        #expect(block.plainOutput == "done")
    }
}
