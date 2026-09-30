import Darwin
import Foundation
import Testing
@testable import Turm

@MainActor
@Suite(.serialized)
struct SpawnGuardTests {
    private func wait(timeout: Duration = .seconds(20), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func inode(_ descriptor: Int32) -> UInt64 {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? UInt64(info.st_ino) : 0
    }

    private func inheritedByShell(_ descriptors: [Int32]) async throws -> [Bool] {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })
        let checks = descriptors.map { "printf 'fd:%s\\n' \"$(lsof -a -p $$ -d \($0) 2>/dev/null | tail -n +2)\"" }
        session.submit(checks.joined(separator: "; "))
        #expect(await wait { session.blocks.first?.isRunning == false })
        let lines = try #require(session.blocks.first).plainOutput.split(separator: "\n").filter { $0.hasPrefix("fd:") }
        try #require(lines.count == descriptors.count)
        return zip(descriptors, lines).map { descriptor, line in line.contains("0x" + String(inode(descriptor), radix: 16)) }
    }

    @Test func shellsDoNotInheritGuardedPipes() async throws {
        var plain: [Int32] = [0, 0]
        try #require(pipe(&plain) == 0)
        let guarded = SpawnGuard.pipe()
        defer {
            close(plain[0])
            close(plain[1])
            try? guarded.fileHandleForWriting.close()
            try? guarded.fileHandleForReading.close()
        }
        let seen = try await inheritedByShell([plain[1], guarded.fileHandleForWriting.fileDescriptor])
        #expect(seen == [true, false])
    }

    @Test func guardedPipesAreCloseOnExec() {
        let pipe = SpawnGuard.pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
    }

    @Test func shellsDoNotInheritOtherTerminals() async throws {
        let first = TerminalSession()
        defer { first.terminate() }
        #expect(await wait { first.phase == .ready })
        let second = TerminalSession()
        defer { second.terminate() }
        #expect(await wait { second.phase == .ready })
        second.submit("printf 'masters:%s\\n' \"$(lsof -a -p $$ 2>/dev/null | grep -c ptmx)\"")
        #expect(await wait { second.blocks.first?.isRunning == false })
        let output = try #require(second.blocks.first).plainOutput
        #expect(output.contains("masters:0"))
    }

    @Test func terminatingEndsTheShell() async throws {
        let session = TerminalSession()
        #expect(await wait { session.phase == .ready })
        session.submit("echo pid:$$")
        #expect(await wait { session.blocks.first?.isRunning == false })
        let line = try #require(session.blocks.first?.plainOutput.split(separator: "\n").first { $0.hasPrefix("pid:") })
        let pid = try #require(pid_t(line.dropFirst(4)))
        session.terminate()
        var status: Int32 = 0
        #expect(await wait { waitpid(pid, &status, WNOHANG) == pid || kill(pid, 0) != 0 })
    }

    @Test func readerSeesEndOfFileWhileShellsStart() async throws {
        let pipe = SpawnGuard.pipe()
        let session = TerminalSession()
        defer { session.terminate() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("done".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        let text = await Task.detached { String(decoding: reader.readDataToEndOfFile(), as: UTF8.self) }.value
        #expect(text == "done")
    }
}
