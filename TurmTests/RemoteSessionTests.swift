import Foundation
import Testing
@testable import Turm

private let remoteFishPath = (
    [ProcessInfo.processInfo.environment["TURM_TEST_FISH"]].compactMap { $0 }
        + ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
).first {
    FileManager.default.isExecutableFile(atPath: $0)
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor
private func startSession(shell: String) -> TerminalSession {
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
private func finishedBlock(_ session: TerminalSession, _ count: Int) async throws -> Block {
    let done = await waitUntil { session.phase == .ready && session.blocks.count == count && session.blocks[count - 1].isRunning == false }
    try #require(done)
    return session.blocks[count - 1]
}

private func installRemoteFiles(into home: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-s"]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    let stdin = SpawnGuard.pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data(RemoteIntegration.installScript().utf8))
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
}

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("turm-remote-home-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@MainActor
private func connectRemote(_ session: TerminalSession, shell: String, home: URL) async throws {
    let command = "env HOME=\(ShellIntegration.quoted(home.path)) SHELL=\(ShellIntegration.quoted(shell)) sh \(ShellIntegration.quoted(home.path + "/.turm/shell/bootstrap.sh"))"
    session.submit(command)
    let connected = await waitUntil { session.isRemote && session.phase == .ready }
    try #require(connected)
}

@MainActor
private func exerciseRemote(shell: String, kind: RemoteShellKind) async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try installRemoteFiles(into: home)

    let session = startSession(shell: shell)
    defer { session.terminate() }
    #expect(await waitUntil { session.phase == .ready })
    let localDirectory = session.directory

    try await connectRemote(session, shell: shell, home: home)
    let first = try #require(session.blocks.first)
    #expect(first.isRunning == false)
    let remote = try #require(session.remote)
    #expect(remote.kind == kind)
    #expect(remote.host.contains("@"))
    #expect(first.connectedTo == remote.label)

    session.submit("echo hi")
    let echoed = try await finishedBlock(session, 2)
    #expect(echoed.plainOutput.contains("hi"))
    #expect(echoed.host == session.remote?.label)
    #expect(echoed.exitCode == 0)

    session.submit("false")
    let failed = try await finishedBlock(session, 3)
    #expect(failed.exitCode == 1)
    #expect(session.isRemote)
    #expect(failed.host == session.remote?.label)

    session.submit("exit")
    let left = await waitUntil { !session.isRemote && session.phase == .ready && session.blocks.count == 4 && session.blocks[3].isRunning == false }
    #expect(left)
    #expect(session.remote == nil)
    #expect(session.directory == localDirectory)
    #expect(session.blocks.allSatisfy { $0.notice == nil })
}

@MainActor
private func killRemote(shell: String, kind: RemoteShellKind) async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try installRemoteFiles(into: home)

    let session = startSession(shell: shell)
    defer { session.terminate() }
    #expect(await waitUntil { session.phase == .ready })
    try await connectRemote(session, shell: shell, home: home)
    #expect(session.remote?.kind == kind)

    session.submit(kind == .fish ? "kill -9 $fish_pid" : "kill -9 $$")
    let ended = await waitUntil { !session.isRemote && session.phase == .ready && session.blocks.allSatisfy { !$0.isRunning } }
    #expect(ended)
    #expect(session.remote == nil)
    #expect(session.connection == nil)
    let killed = session.blocks.first { $0.command.contains("kill -9") }
    if let killed {
        #expect(killed.exitCode.map { $0 != 0 } ?? false)
    } else {
        #expect(session.blocks.contains { $0.notice?.hasPrefix("Disconnected from ") == true })
    }
}

@MainActor
struct RemoteSessionTests {
    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func reloadReplacesTheRemoteShellInPlace(shell: String) async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try installRemoteFiles(into: home)
        let session = startSession(shell: shell)
        defer { session.terminate() }
        #expect(await waitUntil { session.phase == .ready })
        try await connectRemote(session, shell: shell, home: home)
        let before = try #require(session.remote)
        let count = session.blocks.count
        let reloadCommand = RemoteIntegration.enableCommand.trimmingCharacters(in: .whitespaces)
        let recorded = { CommandHistory.shared.entries.filter { $0.contains(reloadCommand) }.count }
        let historyCount = recorded()

        session.reloadRemoteShell()
        let reloaded = await waitUntil {
            session.phase == .ready && session.remote.map { $0.token != before.token } == true && session.blocks.count == count + 1
        }
        try #require(reloaded)
        #expect(session.remotes.count == 1)
        #expect(session.blocks.last?.connectedTo != nil)
        #expect(recorded() == historyCount)

        session.submit("echo again")
        let echoed = try await finishedBlock(session, count + 2)
        #expect(echoed.plainOutput.contains("again"))

        session.disconnectRemote()
        #expect(await waitUntil { !session.isRemote && session.phase == .ready })
        #expect(session.localDirectory == nil)
    }

    @Test func remoteTargetFallsBackToTheHelloHost() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try installRemoteFiles(into: home)
        let session = startSession(shell: "/bin/zsh")
        defer { session.terminate() }
        #expect(await waitUntil { session.phase == .ready })
        try await connectRemote(session, shell: "/bin/zsh", home: home)
        let target = try #require(session.remoteTarget)
        #expect(session.remote?.host == target.user + "@" + target.hostname)
        #expect(target.port == 22)
        #expect(session.remoteAddress == session.remote?.host)
        #expect(session.remoteSSHCommand?.hasPrefix("ssh ") == true)
        #expect(session.location.hasSuffix(":" + session.directory))
    }

    @Test func zshRemoteLifecycle() async throws {
        try await exerciseRemote(shell: "/bin/zsh", kind: .zsh)
    }

    @Test func bash32RemoteIsLegacyAndLifecycleWorks() async throws {
        try await exerciseRemote(shell: "/bin/bash", kind: .legacyBash)
    }

    @Test func zshRemoteKilledFromTheRemoteSideEndsTheRemote() async throws {
        try await killRemote(shell: "/bin/zsh", kind: .zsh)
    }

    @Test func bashRemoteKilledFromTheRemoteSideEndsTheRemote() async throws {
        try await killRemote(shell: "/bin/bash", kind: .legacyBash)
    }
}

@MainActor
@Suite(.enabled(if: remoteFishPath != nil))
struct FishRemoteSessionTests {
    @Test func fishRemoteLifecycle() async throws {
        try await exerciseRemote(shell: try #require(remoteFishPath), kind: .fish)
    }

    @Test func fishRemoteKilledFromTheRemoteSideEndsTheRemote() async throws {
        try await killRemote(shell: try #require(remoteFishPath), kind: .fish)
    }

    @Test func fishDefinesTheSshFunction() async throws {
        let session = startSession(shell: try #require(remoteFishPath))
        defer { session.terminate() }
        #expect(await waitUntil { session.phase == .ready })

        session.submit("functions -q ssh; and echo yes; or echo no")
        let result = try await finishedBlock(session, 1)
        #expect(result.plainOutput == "yes")
    }
}

@MainActor
struct LocalSshFunctionTests {
    @Test func zshDefinesTheSshFunctionAndExportsTheWrapper() async throws {
        let session = startSession(shell: "/bin/zsh")
        defer { session.terminate() }
        #expect(await waitUntil { session.phase == .ready })

        session.submit("whence -w ssh")
        let kind = try await finishedBlock(session, 1)
        #expect(kind.plainOutput == "ssh: function")

        session.submit("print -r -- $TURM_SSH_WRAPPER")
        let path = try await finishedBlock(session, 2)
        #expect(path.plainOutput == RemoteIntegration.wrapperURL.path)
        #expect(FileManager.default.isExecutableFile(atPath: RemoteIntegration.wrapperURL.path))
    }

    @Test func bashDefinesTheSshFunctionAndExportsTheWrapper() async throws {
        let session = startSession(shell: "/bin/bash")
        defer { session.terminate() }
        #expect(await waitUntil { session.phase == .ready })

        session.submit("type -t ssh")
        let kind = try await finishedBlock(session, 1)
        #expect(kind.plainOutput == "function")

        session.submit("printf '%s' \"$TURM_SSH_WRAPPER\"")
        let path = try await finishedBlock(session, 2)
        #expect(path.plainOutput == RemoteIntegration.wrapperURL.path)
    }
}
