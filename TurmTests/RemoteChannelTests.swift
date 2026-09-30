import Foundation
import Testing
@testable import Turm

private let remoteShellEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty", "LC_ALL": "C"]

private func remoteScratch() throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    let url = base.appendingPathComponent("turm-remote-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func remoteWrite(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@discardableResult
private func remoteExecute(_ path: String, _ arguments: [String], in directory: String? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = remoteShellEnvironment
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@discardableResult
private func remoteGit(_ arguments: [String], in directory: URL) throws -> String {
    let identity = ["-c", "user.name=Tester", "-c", "user.email=tester@example.com", "-c", "commit.gpgsign=false"]
    return try remoteExecute("/usr/bin/git", identity + arguments, in: directory.path).output
}

private func remoteBase64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

private final class RemoteRig {
    let root: URL
    let channel: RemoteChannel
    private let scratch: URL

    init() throws {
        scratch = try remoteScratch()
        root = scratch.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = scratch.appendingPathComponent("fake-ssh")
        let body = """
            #!/bin/sh
            while [ $# -gt 0 ]; do [ "$1" = turm ] && { shift; break; }; shift; done
            exec /bin/sh -c "$1"
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        SSHProcess.executable = script.path
        channel = RemoteChannel(socket: "/nonexistent")
        channel.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
    }

    func teardown() {
        SSHProcess.executable = "/usr/bin/ssh"
        try? FileManager.default.removeItem(at: scratch)
    }
}

struct RemoteChannelPureTests {
    @Test func multiplexedCallsNeverFallBackToADirectConnection() {
        let arguments = RemoteChannel.multiplexed("/tmp/s")
        #expect(arguments.contains("ControlMaster=no"))
        #expect(arguments.contains("ControlPath=/tmp/s"))
        #expect(arguments.contains("ProxyCommand=/usr/bin/false"))
    }

    @Test func refusedSessionsAreRecognised() {
        #expect(RemoteChannel.isRefused("mux_client_request_session: session request failed: Session open refused by peer"))
        #expect(!RemoteChannel.isRefused("Permission denied (publickey)."))
    }

    static let awkward = ["plain", "with space", "it's", "a'b'c", "$HOME", "`echo hi`", "line1\nline2", "back\\slash", "\"dq\"", "*?[x]", "", "'"]

    @Test(arguments: awkward)
    func quoteRoundTripsThroughShell(_ text: String) throws {
        let result = try remoteExecute("/bin/sh", ["-c", "printf %s " + RemoteChannel.quote(text)])
        #expect(result.status == 0)
        #expect(result.output == text)
    }

    @Test func parseGitStatusReadsBranchAndNumstat() {
        let status = RemoteChannel.parseGitStatus("main\n3\t1\tsrc/a.swift\n-\t-\timage.png\n10\t0\tb.txt\n")
        #expect(status == GitStatus(branch: "main", files: 3, added: 13, removed: 1))
    }

    @Test func parseGitStatusBranchOnly() {
        #expect(RemoteChannel.parseGitStatus("feature/x\n") == GitStatus(branch: "feature/x", files: 0, added: 0, removed: 0))
        #expect(RemoteChannel.parseGitStatus("abc1234") == GitStatus(branch: "abc1234", files: 0, added: 0, removed: 0))
    }

    @Test func parseGitStatusEmptyIsNil() {
        #expect(RemoteChannel.parseGitStatus("") == nil)
        #expect(RemoteChannel.parseGitStatus("\n") == nil)
        #expect(RemoteChannel.parseGitStatus("\n1\t1\ta\n") == nil)
    }

    @Test func safeNameReplacesUnsafeCharacters() {
        #expect(RemoteChannel.safeName("my file (1)/x$y.png") == "my_file__1__x_y.png")
        #expect(RemoteChannel.safeName("keep-this_name.v2.txt") == "keep-this_name.v2.txt")
    }

    @Test func safeNameKeepsAtMostEightyCharacters() {
        let name = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
        let cleaned = RemoteChannel.safeName(name)
        #expect(cleaned.count == 80)
        #expect(cleaned == String(repeating: "a", count: 30) + String(repeating: "b", count: 50))
    }

    @Test func safeNameEmptyBecomesFile() {
        #expect(RemoteChannel.safeName("") == "file")
    }

    @Test func directoryParseReadsTheLineProtocol() {
        let package = #"{"scripts":{"dev":"vite"}}"#
        let manifest = #"{"actions":[]}"#
        let sample = [
            "E f orphan-before-any-directory",
            "D /srv/app",
            "E d src",
            "E f README.md",
            "E f name with space",
            "X src/main.rs",
            "X bin/rails",
            "F package.json " + remoteBase64(package),
            "F empty.txt ",
            "M Turm.json " + remoteBase64(manifest),
            "Q unknown line",
            "F broken !!!notbase64",
            "Z",
            "D /srv",
            "E f a",
            "",
        ].joined(separator: "\n")
        let parsed = RemoteDirectory.parse(sample)
        #expect(parsed.count == 2)
        #expect(parsed[0].path == "/srv/app")
        #expect(parsed[0].entries == [
            .init(name: "src", isDirectory: true),
            .init(name: "README.md", isDirectory: false),
            .init(name: "name with space", isDirectory: false),
        ])
        #expect(parsed[0].existing == ["src/main.rs", "bin/rails"])
        #expect(parsed[0].files == ["package.json": package, "empty.txt": ""])
        #expect(parsed[0].manifest?.name == "Turm.json")
        #expect(parsed[0].manifest?.content == manifest)
        #expect(parsed[1].path == "/srv")
        #expect(parsed[1].entries == [.init(name: "a", isDirectory: false)])
        #expect(parsed[1].manifest == nil)
    }

    @Test func parseListingReadsKindsAndSkipsMalformedLines() {
        let entries = RemoteCompletionSources.parseListing("D\tsrc\nX\trun.sh\nF\ta.txt\nF\tb\tc\nZ\tbad\nDsrc\nD\t\n")
        #expect(entries == [
            RemoteEntry(name: "src", isDirectory: true, isExecutable: false),
            RemoteEntry(name: "run.sh", isDirectory: false, isExecutable: true),
            RemoteEntry(name: "a.txt", isDirectory: false, isExecutable: false),
            RemoteEntry(name: "b\tc", isDirectory: false, isExecutable: false),
        ])
    }

    @Test func parseCommandsKeepsFirstOccurrenceAndAbbreviatesHome() {
        let output = "ls\t/bin\nls\t/usr/bin\ngit\t/home/u/bin\nnodetail\n\t/x\n"
        let symbols = RemoteCompletionSources.parseCommands(output, home: "/home/u")
        #expect(symbols.map(\.name) == ["ls", "git"])
        #expect(symbols[0].detail == "/bin")
        #expect(symbols[1].detail == "~/bin")
    }

    @Test func parseCommandsDoesNotAbbreviateSiblingOfHome() {
        let symbols = RemoteCompletionSources.parseCommands("tool\t/home/user2/bin\n", home: "/home/u")
        #expect(symbols.first?.detail == "/home/user2/bin")
    }

    @Test func parseRefsSplitsBranchesRemoteBranchesTagsAndRemotes() {
        let output = [
            "refs/heads/main", "refs/heads/feature/x", "refs/remotes/origin/HEAD", "refs/remotes/origin/main",
            "refs/tags/v1", "--remotes--", "origin", "upstream", "",
        ].joined(separator: "\n")
        let refs = RemoteCompletionSources.parseRefs(output)
        #expect(refs == GitRefs(branches: ["main", "feature/x"], remoteBranches: ["origin/main"], tags: ["v1"], remotes: ["origin", "upstream"]))
    }

    @Test func parseProcessesReadsPidAndBaseName() {
        let output = "  1 /sbin/launchd\n 123 /Applications/Foo Bar.app/Contents/MacOS/Foo\nabc x\n 77\n\t9\tbash\n"
        #expect(RemoteCompletionSources.parseProcesses(output) == [
            ProcessEntry(pid: 1, name: "launchd"),
            ProcessEntry(pid: 123, name: "Foo"),
            ProcessEntry(pid: 9, name: "bash"),
        ])
    }

    @MainActor
    @Test func attachInsertsRemotePathAndRemoveDeletesIt() {
        let model = InputModel()
        let local = URL(fileURLWithPath: "/tmp/local shot.png")
        model.draft = "cat"
        model.attach([local], paths: [local: "/remote/x y.png"])
        #expect(model.draft == "cat /remote/x\\ y.png ")
        model.remove(local)
        #expect(model.draft == "cat ")
        #expect(model.attachments.isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct RemoteChannelFakeSSHTests {
    private func makeProject(_ root: URL) throws {
        try remoteWrite(#"{"name":"demo","scripts":{"dev":"vite","build":"vite build","test":"vitest"}}"#, to: root.appendingPathComponent("package.json"))
        try remoteWrite("lockfileVersion: '9.0'\n", to: root.appendingPathComponent("pnpm-lock.yaml"))
        try remoteWrite("services:\n  web:\n    image: nginx\n", to: root.appendingPathComponent("docker-compose.yml"))
        try remoteWrite("build:\n\techo build\n\ntest:\n\techo test\n", to: root.appendingPathComponent("Makefile"))
        try remoteWrite("[package]\nname = \"api\"\nversion = \"0.1.0\"\nedition = \"2021\"\n", to: root.appendingPathComponent("services/api/Cargo.toml"))
        try remoteWrite("fn main() {}\n", to: root.appendingPathComponent("services/api/src/main.rs"))
        try remoteWrite("notes\n", to: root.appendingPathComponent("docs/notes.txt"))
        try remoteWrite(#"{"actions":[{"title":"Deploy","command":"./deploy.sh"}]}"#, to: root.appendingPathComponent("Turm.json"))
        try remoteWrite(#"{"name":"bad"}"#, to: root.appendingPathComponent("bad/package.json"))
        try remoteWrite("{ not json", to: root.appendingPathComponent("bad/Turm.json"))
    }

    private func resolved(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private func expectParity(_ rig: RemoteRig, _ directory: URL) async {
        let remote = await rig.channel.project(in: directory.path)
        let local = ProjectDetection.snapshot(for: directory.path, home: rig.root.path)
        #expect(resolved(remote.manifestPath) == resolved(local.manifestPath))
        var remoteRest = remote
        var localRest = local
        remoteRest.manifestPath = nil
        localRest.manifestPath = nil
        #expect(remoteRest == localRest, "directory \(directory.path)")
    }

    @Test func projectMatchesLocalDetectionAtRoot() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        try makeProject(rig.root)
        await expectParity(rig, rig.root)
        let remote = await rig.channel.project(in: rig.root.path)
        #expect(remote.actions.contains { $0.title == "Deploy" })
        #expect(remote.manifestPath != nil)
        #expect(remote.notice == nil)
        #expect(!remote.ecosystems.isEmpty)
    }

    @Test func projectMatchesLocalDetectionInNestedFolders() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        try makeProject(rig.root)
        await expectParity(rig, rig.root.appendingPathComponent("services/api"))
        await expectParity(rig, rig.root.appendingPathComponent("services/api/src"))
        await expectParity(rig, rig.root.appendingPathComponent("docs"))
    }

    @Test func projectNoticeForInvalidManifestMatchesLocal() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        try makeProject(rig.root)
        let bad = rig.root.appendingPathComponent("bad")
        await expectParity(rig, bad)
        let remote = await rig.channel.project(in: bad.path)
        #expect(remote.notice?.hasPrefix("Turm.json:") == true)
    }

    private func makeRepository(_ rig: RemoteRig) throws -> URL {
        let repo = rig.root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try remoteGit(["init", "-q", "-b", "main"], in: repo)
        try remoteWrite("one\ntwo\nthree\n", to: repo.appendingPathComponent("a.txt"))
        try remoteGit(["add", "."], in: repo)
        try remoteGit(["commit", "-q", "-m", "first"], in: repo)
        try remoteGit(["branch", "feature-x"], in: repo)
        try remoteGit(["tag", "v1"], in: repo)
        return repo
    }

    @Test func gitStatusReportsBranchAndChangeCounts() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let repo = try makeRepository(rig)
        try remoteWrite("one\nTWO\nthree\nfour\n", to: repo.appendingPathComponent("a.txt"))
        let status = await rig.channel.gitStatus(in: repo.path)
        #expect(status == GitStatus(branch: "main", files: 1, added: 2, removed: 1))
    }

    @Test func gitStatusIsNilOutsideARepository() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        #expect(await rig.channel.gitStatus(in: rig.root.path) == nil)
        #expect(await rig.channel.gitStatus(in: rig.root.appendingPathComponent("missing").path) == nil)
    }

    @Test func branchesListsCreatedBranches() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let repo = try makeRepository(rig)
        let branches = await rig.channel.branches(in: repo.path)
        #expect(Set(branches) == ["main", "feature-x"])
        #expect(await rig.channel.branches(in: rig.root.path).isEmpty)
    }

    @Test func switchBranchSwitchesAndReportsFailure() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let repo = try makeRepository(rig)
        #expect(await rig.channel.switchBranch(to: "feature-x", in: repo.path) == nil)
        #expect(await rig.channel.gitStatus(in: repo.path)?.branch == "feature-x")
        let message = await rig.channel.switchBranch(to: "no-such-branch", in: repo.path)
        #expect(message?.isEmpty == false)
        #expect(await rig.channel.gitStatus(in: repo.path)?.branch == "feature-x")
    }

    @Test func uploadCopiesFilesIntoPerUserTemporaryDirectory() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let plain = rig.root.appendingPathComponent("plain.bin")
        let spaced = rig.root.appendingPathComponent("my file (1).png")
        let plainBytes = Data([0, 1, 2, 255, 10, 13, 39, 34])
        let spacedBytes = Data((0..<5000).map { UInt8($0 % 251) })
        try plainBytes.write(to: plain)
        try spacedBytes.write(to: spaced)
        let missing = rig.root.appendingPathComponent("gone.txt")

        let result = await rig.channel.upload([missing, plain, spaced])
        defer { for path in result.values { try? FileManager.default.removeItem(atPath: path) } }

        #expect(result[missing] == nil)
        #expect(result.count == 2)
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        for (url, expected) in [(plain, plainBytes), (spaced, spacedBytes)] {
            let path = try #require(result[url])
            #expect(path.contains("/turm-\(getuid())/"))
            #expect(path.hasPrefix(tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp))
            #expect(FileManager.default.contents(atPath: path) == expected)
        }
        #expect(result[spaced]?.hasSuffix("-my_file__1_.png") == true)
    }

    // A slow runner can time a fetch out; the editor simply asks again, so the tests do too
    private func eventually<T: Sendable>(_ fetch: @escaping @Sendable () -> T, until done: (T) -> Bool) async -> T {
        let deadline = ContinuousClock.now + .seconds(15)
        var result = await Task.detached(operation: fetch).value
        while !done(result), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            result = await Task.detached(operation: fetch).value
        }
        return result
    }

    private func settledLookup(_ env: RemoteCompletionEnvironment, _ name: String, _ directory: String) async -> CommandLookup {
        await eventually({ env.lookupCommand(name, directory: directory) }, until: { $0 != .unknown })
    }

    @Test func environmentListsDirectoryOffTheMainThread() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let folder = rig.root.appendingPathComponent("listing")
        try remoteWrite("x", to: folder.appendingPathComponent("a.txt"))
        try remoteWrite("x", to: folder.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let env = RemoteCompletionEnvironment(base: FakeEnvironment(), channel: rig.channel)
        let path = folder.path
        let entries = await eventually({ env.directoryEntries(atPath: path) }, until: { $0 != nil })
        let byName = Dictionary(uniqueKeysWithValues: (entries ?? []).map { ($0.name, $0.isDirectory) })
        #expect(byName == ["a.txt": false, ".hidden": false, "sub": true])
        let missing = await Task.detached { env.directoryEntries(atPath: path + "/nope") }.value
        #expect(missing == nil)
    }

    @Test func environmentCommandsAndLookup() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let env = RemoteCompletionEnvironment(base: FakeEnvironment(), channel: rig.channel)
        let directory = rig.root.path
        let symbols = await eventually({ env.commandSymbols() }, until: { $0.contains { $0.name == "ls" } })
        let names = Set(symbols.map(\.name))
        #expect(names.contains("ls"))
        #expect(names.contains("cd"))
        let ls = await Task.detached { env.lookupCommand("ls", directory: directory) }.value
        let cd = await Task.detached { env.lookupCommand("cd", directory: directory) }.value
        let made = await Task.detached { env.lookupCommand("definitely-not-a-command-xyz", directory: directory) }.value
        #expect(ls == .executable)
        #expect(cd == .builtin)
        #expect(made == .missing)
        let loaded = await Task.detached { env.commandsLoaded() }.value
        #expect(loaded)
    }

    @Test func environmentLooksUpPathsThroughTheListing() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let script = rig.root.appendingPathComponent("tool.sh")
        try remoteWrite("#!/bin/sh\n", to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let env = RemoteCompletionEnvironment(base: FakeEnvironment(), channel: rig.channel)
        let scriptPath = script.path
        let directory = rig.root.path
        let executable = await settledLookup(env, scriptPath, directory)
        let absent = await settledLookup(env, directory + "/absent", directory)
        let isDirectory = await settledLookup(env, directory, directory)
        #expect(executable == .executable)
        #expect(absent == .missing)
        #expect(isDirectory == .missing)
    }

    @Test func environmentGitRefsTextProcessesAndIdentity() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let repo = try makeRepository(rig)
        let note = rig.root.appendingPathComponent("note.txt")
        try remoteWrite("hello\nworld\n", to: note)
        let env = RemoteCompletionEnvironment(base: FakeEnvironment(), channel: rig.channel)
        let repoPath = repo.path
        let notePath = note.path
        let refs = await eventually({ env.gitRefs(in: repoPath) }, until: { $0 != nil })
        #expect(Set(refs?.branches ?? []) == ["main", "feature-x"])
        #expect(refs?.tags == ["v1"])
        let plain = await Task.detached { env.gitRefs(in: NSTemporaryDirectory()) }.value
        #expect(plain == nil)
        let text = await eventually({ env.readText(atPath: notePath) }, until: { $0 != nil })
        #expect(text == "hello\nworld\n")
        let none = await Task.detached { env.readText(atPath: notePath + ".missing") }.value
        #expect(none == nil)
        let processes = await eventually({ env.processes() }, until: { !$0.isEmpty })
        #expect(processes.contains { $0.pid == Int(getpid()) })
        #expect(env.variables == ["HOME": rig.root.path, "PATH": "/usr/bin:/bin"])
        #expect(env.homeDirectory == rig.root.path)
    }

    @Test func mainThreadListingDoesNotBlockAndLandsInTheBackground() async throws {
        let rig = try RemoteRig()
        defer { rig.teardown() }
        let folder = rig.root.appendingPathComponent("async-listing")
        try remoteWrite("x", to: folder.appendingPathComponent("late.txt"))
        let env = RemoteCompletionEnvironment(base: FakeEnvironment(), channel: rig.channel)
        #expect(Thread.isMainThread)

        let start = Date()
        let first = env.directoryEntries(atPath: folder.path)
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(first == nil)

        var landed: [DirectoryEntry]?
        let deadline = Date().addingTimeInterval(5)
        while landed == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            landed = env.directoryEntries(atPath: folder.path)
        }
        #expect(landed == [DirectoryEntry(name: "late.txt", isDirectory: false)])
    }
}
