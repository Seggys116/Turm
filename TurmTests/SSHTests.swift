import Foundation
import Testing
import TurmCore
@testable import Turm

private func sshEvents(_ text: String) -> [StreamPiece] {
    var parser = ShellStreamParser()
    return parser.consume(Array(text.utf8))
}

private func osc(_ body: String) -> String {
    "\u{1B}]7777;" + body + "\u{07}"
}

private func hasEvent(_ pieces: [StreamPiece]) -> Bool {
    pieces.contains { if case .event = $0 { true } else { false } }
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("turm-ssh-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func execute(_ path: String, _ arguments: [String], environment: [String: String], input: Data? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = environment
    let output = SpawnGuard.pipe()
    let stdin = SpawnGuard.pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    try process.run()
    if let input {
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func write(_ text: String, to url: URL, mode: Int = 0o644) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

@MainActor
struct ShellStreamRemoteEventTests {
    @Test func decodesSshStarted() {
        let pieces = sshEvents(osc("S;/tmp/turm-ssh/4242;bob@example.com:2222"))
        #expect(pieces == [.event(.sshStarted(socket: "/tmp/turm-ssh/4242", target: "bob@example.com:2222"))])
    }

    @Test func rejectsSshStartedWithEmptySocket() {
        #expect(!hasEvent(sshEvents(osc("S;;bob@example.com:2222"))))
    }

    @Test func decodesRemoteHello() {
        let pieces = sshEvents(osc("H;123.456;zsh;bob@web01"))
        #expect(pieces == [.event(.remoteHello(token: "123.456", kind: "zsh", host: "bob@web01"))])
    }

    @Test func rejectsRemoteHelloWithEmptyToken() {
        #expect(!hasEvent(sshEvents(osc("H;;zsh;bob@web01"))))
    }

    @Test func decodesRemotePrompt() {
        #expect(sshEvents(osc("R;tok;0;/home/bob")) == [.event(.remotePrompt(token: "tok", exitCode: 0, directory: "/home/bob"))])
        #expect(sshEvents(osc("R;tok;127;/srv")) == [.event(.remotePrompt(token: "tok", exitCode: 127, directory: "/srv"))])
    }

    @Test func emptyExitCodeInRemotePromptIsNil() {
        #expect(sshEvents(osc("R;tok;;/home/bob")) == [.event(.remotePrompt(token: "tok", exitCode: nil, directory: "/home/bob"))])
    }

    @Test func remotePromptDirectoryMayContainSemicolons() {
        #expect(sshEvents(osc("R;tok;1;/tmp/a;b;c")) == [.event(.remotePrompt(token: "tok", exitCode: 1, directory: "/tmp/a;b;c"))])
    }

    @Test func rejectsRemotePromptWithEmptyToken() {
        #expect(!hasEvent(sshEvents(osc("R;;0;/home/bob"))))
    }

    @Test func localCommandAndPromptEventsStillDecode() {
        #expect(sshEvents(osc("C")) == [.event(.commandStarted)])
        #expect(sshEvents(osc("P;0;/tmp")) == [.event(.promptReady(exitCode: 0, directory: "/tmp"))])
        #expect(sshEvents(osc("P;;/tmp")) == [.event(.promptReady(exitCode: nil, directory: "/tmp"))])
        #expect(sshEvents(osc("P;2;/a b")) == [.event(.promptReady(exitCode: 2, directory: "/a b"))])
    }

    @Test func remoteEventsSurviveChunkingAndNeverLeakIntoOutput() {
        let bytes = Array(("before" + osc("R;tok;0;/x") + "after").utf8)
        var parser = ShellStreamParser()
        var pieces: [StreamPiece] = []
        for byte in bytes { pieces += parser.consume([byte]) }
        #expect(pieces.contains(.event(.remotePrompt(token: "tok", exitCode: 0, directory: "/x"))))
        let text = pieces.compactMap { piece -> String? in
            if case .output(let data) = piece { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(text == "beforeafter")
    }
}

@MainActor
struct SSHRouteTests {
    private let prod = SSHHost(key: "Prod", hostname: "example.com", user: "bob", port: 2222, identityFile: "/keys/id one")
    private func quote(_ text: String) -> String { "'" + text + "'" }

    @Test func resolvesSavedHostCaseInsensitively() throws {
        let route = try #require(SSHRoute.parse(">prod", hosts: [prod]))
        #expect(route.host == prod)
        #expect(route.token == "prod")
        #expect(route.remainder == "")
    }

    @Test func keepsRemainderAfterTheHost() throws {
        let route = try #require(SSHRoute.parse(">prod uptime -p", hosts: [prod]))
        #expect(route.host == prod)
        #expect(route.remainder == "uptime -p")
    }

    @Test func sigilFollowedBySpaceOrNothingIsNotARoute() {
        #expect(SSHRoute.parse("> file", hosts: [prod]) == nil)
        #expect(SSHRoute.parse(">", hosts: [prod]) == nil)
        #expect(SSHRoute.parse("ls >out", hosts: [prod]) == nil)
    }

    @Test func adHocTokenHasNoHost() throws {
        let route = try #require(SSHRoute.parse(">bob@example.com:2222", hosts: [prod]))
        #expect(route.host == nil)
        #expect(route.token == "bob@example.com:2222")
    }

    @Test func splitsDestinationsAndPorts() {
        #expect(SSHRoute.split("bob@example.com:2222") == (destination: "bob@example.com", port: 2222))
        #expect(SSHRoute.split("[::1]:2200") == (destination: "::1", port: 2200))
        #expect(SSHRoute.split("[::1]") == (destination: "::1", port: nil))
        #expect(SSHRoute.split("example.com") == (destination: "example.com", port: nil))
        #expect(SSHRoute.split("bob@example.com") == (destination: "bob@example.com", port: nil))
        #expect(SSHRoute.split("::1") == (destination: "::1", port: nil))
    }

    @Test func savedHostCommandLocalIncludesIdentity() throws {
        let route = try #require(SSHRoute.parse(">prod uptime", hosts: [prod]))
        #expect(route.command(remote: false, quote: quote) == "ssh -p 2222 -i '/keys/id one' -o IdentitiesOnly=yes -- 'bob@example.com' uptime")
    }

    @Test func savedHostCommandFromARemoteOmitsIdentity() throws {
        let route = try #require(SSHRoute.parse(">prod", hosts: [prod]))
        #expect(route.command(remote: true, quote: quote) == "ssh -p 2222 -- 'bob@example.com'")
    }

    @Test func savedHostWithoutPortOrUserUsesBareHostname() throws {
        let plain = SSHHost(key: "box", hostname: "10.0.0.5")
        let route = try #require(SSHRoute.parse(">box", hosts: [plain]))
        #expect(route.command(remote: false, quote: quote) == "ssh -- '10.0.0.5'")
    }

    @Test func adHocCommandPassesThePort() throws {
        let route = try #require(SSHRoute.parse(">bob@example.com:2222 ls -l", hosts: []))
        #expect(route.command(remote: false, quote: quote) == "ssh -p 2222 -- 'bob@example.com' ls -l")
    }

    @Test func partialCompletionRecognisesTheSigil() {
        #expect(SSHRoute.partial(">pr") == "pr")
        #expect(SSHRoute.partial(">") == "")
        #expect(SSHRoute.partial("pr") == nil)
        #expect(SSHRoute.partial(">a b") == nil)
    }
}

@MainActor
struct SSHTargetTests {
    @Test func identifierRoundTrips() throws {
        let target = SSHTarget(user: "bob", hostname: "example.com", port: 2222)
        #expect(target.identifier == "bob@example.com:2222")
        #expect(SSHTarget(identifier: target.identifier) == target)
    }

    @Test func parsesIdentifierParts() throws {
        let target = try #require(SSHTarget(identifier: "alice@host.example:22"))
        #expect(target.user == "alice")
        #expect(target.hostname == "host.example")
        #expect(target.port == 22)
    }

    @Test func rejectsMalformedIdentifiers() {
        for bad in ["", "example.com:22", "bob@example.com", "bob@example.com:abc", "bob@:22", "bob:22@host"] {
            #expect(SSHTarget(identifier: bad) == nil, "\(bad)")
        }
    }

    @Test func resolvesFromSshDashG() throws {
        let config = "user bob\nhostname example.com\nport 2222\nsessiontype default\n"
        #expect(SSHTarget.resolved(from: config) == SSHTarget(user: "bob", hostname: "example.com", port: 2222))
    }

    @Test func firstValueWins() throws {
        let config = "user bob\nuser mallory\nhostname a.example\nhostname b.example\nport 22\nport 99\n"
        #expect(SSHTarget.resolved(from: config) == SSHTarget(user: "bob", hostname: "a.example", port: 22))
    }

    @Test func incompleteConfigDoesNotResolve() {
        #expect(SSHTarget.resolved(from: "user bob\nhostname example.com\n") == nil)
        #expect(SSHTarget.resolved(from: "user bob\nhostname example.com\nport nope\n") == nil)
        #expect(SSHTarget.resolved(from: "") == nil)
    }
}

@MainActor
struct SSHHostMatchingTests {
    private let target = SSHTarget(user: "bob", hostname: "example.com", port: 22)

    @Test func matchesHostname() {
        #expect(SSHHost(key: "prod", hostname: "example.com", user: "bob").matches(target))
        #expect(SSHHost(key: "prod", hostname: "EXAMPLE.com", user: "bob").matches(target))
    }

    @Test func matchesKeyAlias() {
        let aliased = SSHTarget(user: "bob", hostname: "prod", port: 22)
        #expect(SSHHost(key: "Prod", hostname: "example.com", user: "bob").matches(aliased))
    }

    @Test func userMismatchDoesNotMatch() {
        #expect(!SSHHost(key: "prod", hostname: "example.com", user: "alice").matches(target))
    }

    @Test func emptyUserMatchesAnyUser() {
        #expect(SSHHost(key: "prod", hostname: "example.com").matches(target))
    }

    @Test func missingPortDefaultsTo22() {
        let host = SSHHost(key: "prod", hostname: "example.com", user: "bob")
        #expect(host.matches(target))
        #expect(!host.matches(SSHTarget(user: "bob", hostname: "example.com", port: 2222)))
        #expect(!SSHHost(key: "prod", hostname: "example.com", user: "bob", port: 2222).matches(target))
    }

    @Test func differentHostnameDoesNotMatch() {
        #expect(!SSHHost(key: "prod", hostname: "other.com", user: "bob").matches(target))
    }
}

@MainActor
struct SSHHostStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    @Test func draftNamesTheHostAfterItsFirstLabelAndAvoidsTakenKeys() {
        let store = SSHHostStore(defaults: makeDefaults())
        let target = SSHTarget(user: "bob", hostname: "web.example.com", port: 2222)
        let first = store.draft(for: target)
        #expect(first.key == "web")
        #expect(first.hostname == "web.example.com")
        #expect(first.user == "bob")
        #expect(first.port == 2222)
        #expect(store.save(first))
        #expect(store.draft(for: target).key == "web2")
        #expect(store.draft(for: SSHTarget(user: "bob", hostname: "10.0.0.5", port: 22)).port == nil)
    }

    @Test func saveSanitisesTheKeyAndTrimsFields() throws {
        let store = SSHHostStore(defaults: makeDefaults())
        #expect(store.save(SSHHost(key: " @Prod Box! ", hostname: "  example.com ", user: " bob ", identityFile: "   ")))
        let saved = try #require(store.hosts.first)
        #expect(saved.key == "ProdBox")
        #expect(saved.hostname == "example.com")
        #expect(saved.user == "bob")
        #expect(saved.identityFile == nil)
    }

    @Test func saveRejectsEmptyHostnameAndEmptyKey() {
        let store = SSHHostStore(defaults: makeDefaults())
        #expect(!store.save(SSHHost(key: "a", hostname: "   ")))
        #expect(!store.save(SSHHost(key: "!!!", hostname: "example.com")))
        #expect(store.hosts.isEmpty)
    }

    @Test func saveRejectsDuplicateKeysIgnoringCase() {
        let store = SSHHostStore(defaults: makeDefaults())
        #expect(store.save(SSHHost(key: "prod", hostname: "a.example")))
        #expect(!store.save(SSHHost(key: "PROD", hostname: "b.example")))
        #expect(store.hosts.count == 1)
        #expect(store.hosts[0].hostname == "a.example")
    }

    @Test func savingTheSameHostAgainUpdatesInPlace() {
        let store = SSHHostStore(defaults: makeDefaults())
        var host = SSHHost(key: "prod", hostname: "a.example")
        #expect(store.save(host))
        host.hostname = "b.example"
        #expect(store.save(host))
        #expect(store.hosts.count == 1)
        #expect(store.hosts[0].hostname == "b.example")
    }

    @Test func invalidPortIsDropped() {
        let store = SSHHostStore(defaults: makeDefaults())
        #expect(store.save(SSHHost(key: "a", hostname: "a.example", port: 70000)))
        #expect(store.hosts[0].port == nil)
    }

    @Test func removeDeletesTheHost() {
        let store = SSHHostStore(defaults: makeDefaults())
        let host = SSHHost(key: "prod", hostname: "a.example")
        store.save(host)
        store.save(SSHHost(key: "stage", hostname: "b.example"))
        store.remove(host.id)
        #expect(store.hosts.map(\.key) == ["stage"])
    }

    @Test func declineAllowAndIsDeclined() {
        let store = SSHHostStore(defaults: makeDefaults())
        let target = SSHTarget(user: "bob", hostname: "example.com", port: 22)
        #expect(!store.isDeclined(target))
        store.decline(target)
        store.decline(target)
        #expect(store.isDeclined(target))
        #expect(store.declined == ["bob@example.com:22"])
        store.allow(target.identifier)
        #expect(!store.isDeclined(target))
    }

    @Test func declinedTargetsPersistAcrossStores() {
        let defaults = makeDefaults()
        let target = SSHTarget(user: "bob", hostname: "example.com", port: 22)
        SSHHostStore(defaults: defaults).decline(target)
        #expect(SSHHostStore(defaults: defaults).isDeclined(target))
    }

    @Test func importableSkipsSavedKeysIgnoringCase() {
        let store = SSHHostStore(defaults: makeDefaults())
        store.save(SSHHost(key: "prod", hostname: "a.example"))
        #expect(store.importable(from: ["Prod", "stage", "dev"]) == ["stage", "dev"])
    }

    @Test func savedHostsAreVisibleToLoadAndToANewStore() {
        let defaults = makeDefaults()
        let store = SSHHostStore(defaults: defaults)
        store.save(SSHHost(key: "prod", hostname: "a.example", user: "bob", port: 2200))
        let loaded = SSHHostStore.load(from: defaults)
        #expect(loaded == store.hosts)
        #expect(loaded.first?.port == 2200)
        #expect(SSHHostStore(defaults: defaults).hosts == loaded)
    }

    @Test func hostMatchingFindsTheSavedHost() {
        let store = SSHHostStore(defaults: makeDefaults())
        store.save(SSHHost(key: "prod", hostname: "example.com", user: "bob"))
        let found = store.host(matching: SSHTarget(user: "bob", hostname: "example.com", port: 22))
        #expect(found?.key == "prod")
        #expect(store.host(matching: SSHTarget(user: "eve", hostname: "example.com", port: 22)) == nil)
    }
}

@MainActor
struct SSHPasswordPromptTests {
    private let target = SSHTarget(user: "bob", hostname: "example.com", port: 22)

    @Test func acceptsOpenSshPasswordPrompt() {
        #expect(SSHPasswordPrompt.matches("bob@example.com's password: ", target: target))
    }

    @Test func acceptsParenthesisedPrompt() {
        #expect(SSHPasswordPrompt.matches("(bob@example.com) Password: ", target: target))
    }

    @Test func acceptsThePromptAsTheLastLineOfALongerTail() {
        #expect(SSHPasswordPrompt.matches("Warning: Permanently added\r\nbob@example.com's password: ", target: target))
    }

    @Test func rejectsAnotherUserOrHost() {
        #expect(!SSHPasswordPrompt.matches("alice@example.com's password: ", target: target))
        #expect(!SSHPasswordPrompt.matches("bob@other.com's password: ", target: target))
    }

    @Test func rejectsABarePasswordPrompt() {
        #expect(!SSHPasswordPrompt.matches("Password:", target: target))
        #expect(!SSHPasswordPrompt.matches("password: ", target: target))
    }

    @Test func rejectsAPromptThatIsNotOnTheLastLine() {
        #expect(!SSHPasswordPrompt.matches("bob@example.com's password: \nPermission denied, please try again.\n", target: target))
    }
}

@MainActor
struct SudoPromptTests {
    @Test func recognisesOnlyCommandsThatStartWithSudo() {
        #expect(SudoPrompt.isSudo("sudo apt update"))
        #expect(SudoPrompt.isSudo("  sudo -v"))
        #expect(!SudoPrompt.isSudo("echo sudo"))
        #expect(!SudoPrompt.isSudo("sudoedit /etc/hosts"))
        #expect(!SudoPrompt.isSudo("su -"))
        #expect(!SudoPrompt.isSudo(""))
    }

    @Test func acceptsSudosOwnPromptForTheUser() {
        #expect(SudoPrompt.matches("[sudo] password for bob: ", user: "bob"))
        #expect(SudoPrompt.matches("Reading lists\n[sudo] password for bob:", user: "bob"))
    }

    @Test func rejectsAnyOtherPasswordPrompt() {
        #expect(!SudoPrompt.matches("Password:", user: "bob"))
        #expect(!SudoPrompt.matches("password for bob: ", user: "bob"))
        #expect(!SudoPrompt.matches("Enter passphrase for key '/home/bob/.ssh/id_ed25519': ", user: "bob"))
        #expect(!SudoPrompt.matches("bob@example.com's password: ", user: "bob"))
        #expect(!SudoPrompt.matches("fake [sudo] password for bob: ", user: "bob"))
    }

    @Test func rejectsAnotherUsersPrompt() {
        #expect(!SudoPrompt.matches("[sudo] password for root: ", user: "bob"))
        #expect(!SudoPrompt.matches("[sudo] password for bob: ", user: ""))
    }

    @Test func rejectsAPromptThatIsNoLongerTheLastLine() {
        #expect(!SudoPrompt.matches("[sudo] password for bob: \nSorry, try again.\n", user: "bob"))
        #expect(!SudoPrompt.matches("[sudo] password for bob: \n", user: "bob"))
    }

    @Test func hostsSavedBeforeTheSettingDecodeWithFillOff() throws {
        let json = #"[{"hostname":"example.com","id":"8E0F5C5A-1111-4E4B-9C43-3C1C0B8A3F11","key":"prod","remembersPassword":true,"user":"bob"}]"#
        let hosts = try JSONDecoder().decode([SSHHost].self, from: Data(json.utf8))
        #expect(hosts.first?.sudoFill == .off)
        #expect(hosts.first?.remembersPassword == true)
    }

    @Test func sudoFillSurvivesARoundTrip() throws {
        let host = SSHHost(key: "prod", hostname: "example.com", sudoFill: .ask)
        let decoded = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(host))
        #expect(decoded == host)
    }
}

@MainActor
struct SSHKeysTests {
    private func publicKeyLine(comment: String) -> String {
        var blob = Data([0, 0, 0, 11])
        blob.append(Data("ssh-ed25519".utf8))
        blob.append(Data([0, 0, 0, 32]))
        blob.append(Data((0..<32).map { UInt8($0) }))
        return "ssh-ed25519 " + blob.base64EncodedString() + (comment.isEmpty ? "" : " " + comment)
    }

    private let environment = ["PATH": "/usr/bin:/bin"]

    @Test func fingerprintMatchesSshKeygen() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = publicKeyLine(comment: "bob@laptop")
        let file = directory.appendingPathComponent("k.pub")
        try write(line + "\n", to: file)
        let result = try execute("/usr/bin/ssh-keygen", ["-lf", file.path], environment: environment)
        try #require(result.status == 0)
        let expected = try #require(result.output.split(separator: " ").dropFirst().first).description
        #expect(expected.hasPrefix("SHA256:"))
        let parsed = try #require(SSHKeys.parsePublicKey(line))
        #expect(parsed.fingerprint == expected)
        #expect(parsed.type == "ssh-ed25519")
        #expect(parsed.comment == "bob@laptop")
    }

    @Test func parsePublicKeyKeepsCommentWithSpacesAndAllowsNone() throws {
        let spaced = try #require(SSHKeys.parsePublicKey(publicKeyLine(comment: "bob on laptop")))
        #expect(spaced.comment == "bob on laptop")
        let bare = try #require(SSHKeys.parsePublicKey(publicKeyLine(comment: "")))
        #expect(bare.comment == "")
    }

    @Test func parsePublicKeyRejectsGarbage() {
        #expect(SSHKeys.parsePublicKey("") == nil)
        #expect(SSHKeys.parsePublicKey("ssh-ed25519") == nil)
        #expect(SSHKeys.parsePublicKey("ssh-ed25519 !!!notbase64!!! c")?.fingerprint == nil)
    }

    @Test func acceptedKeyFromVerboseOutput() {
        let text = """
        debug1: Offering public key: /Users/x/.ssh/id_rsa RSA SHA256:zzz explicit
        debug1: Server accepts key: /Users/x/.ssh/id_ed25519 ED25519 SHA256:abc explicit
        """
        let found = SSHKeys.acceptedKey(inVerboseOutput: text)
        #expect(found?.path == "/Users/x/.ssh/id_ed25519")
        #expect(found?.authenticated == false)
    }

    @Test func acceptedKeyReportsAuthentication() {
        let text = """
        debug1: Server accepts key: /Users/x/.ssh/id_ed25519 ED25519 SHA256:abc explicit
        Authenticated to example.com ([1.2.3.4]:22) using "publickey".
        """
        let found = SSHKeys.acceptedKey(inVerboseOutput: text)
        #expect(found?.path == "/Users/x/.ssh/id_ed25519")
        #expect(found?.authenticated == true)
    }

    @Test func noAcceptedKeyIsNil() {
        #expect(SSHKeys.acceptedKey(inVerboseOutput: "debug1: Authentications that can continue: publickey,password\nPermission denied") == nil)
        #expect(SSHKeys.acceptedKey(inVerboseOutput: "") == nil)
    }

    @Test func discoverFindsOnlyPrivateKeys() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n", to: directory.appendingPathComponent("id_ed25519"), mode: 0o600)
        try write(publicKeyLine(comment: "bob@laptop") + "\n", to: directory.appendingPathComponent("id_ed25519.pub"))
        try write("example.com ssh-ed25519 AAAA\n", to: directory.appendingPathComponent("known_hosts"))
        try write("Host prod\n  HostName example.com\n", to: directory.appendingPathComponent("config"))
        try write("just some notes\n", to: directory.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sockets"), withIntermediateDirectories: true)

        let keys = SSHKeys.discover(in: directory.path)
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(key.path == directory.path + "/id_ed25519")
        #expect(key.type == "ssh-ed25519")
        #expect(key.comment == "bob@laptop")
        #expect(key.fingerprint?.hasPrefix("SHA256:") == true)
        #expect(key.typeLabel == "ED25519")
        #expect(key.name == "id_ed25519")
    }

    @Test func discoverKeepsAKeyWithoutAPublicHalf() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n", to: directory.appendingPathComponent("legacy"), mode: 0o600)
        let key = try #require(SSHKeys.discover(in: directory.path).first)
        #expect(key.type == "")
        #expect(key.comment == "")
        #expect(key.fingerprint == nil)
        #expect(key.typeLabel == "Key")
    }

    @Test func discoverInAMissingDirectoryIsEmpty() {
        #expect(SSHKeys.discover(in: FileManager.default.temporaryDirectory.path + "/turm-missing-" + UUID().uuidString).isEmpty)
    }
}

@MainActor
struct SSHConnectionTests {
    @Test func acceptsOnlyNumericNamesDirectlyInsideTheDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/turm-ssh-check-dir", isDirectory: true)
        #expect(SSHConnection.accepts(socket: "/tmp/turm-ssh-check-dir/12345", in: directory))
        #expect(!SSHConnection.accepts(socket: "/tmp/turm-ssh-check-dir/abc", in: directory))
        #expect(!SSHConnection.accepts(socket: "/tmp/turm-ssh-check-dir/12a", in: directory))
        #expect(!SSHConnection.accepts(socket: "/tmp/turm-ssh-check-dir/sub/123", in: directory))
        #expect(!SSHConnection.accepts(socket: "/tmp/other/123", in: directory))
        #expect(!SSHConnection.accepts(socket: "/tmp/turm-ssh-check-dir/../other/123", in: directory))
        #expect(!SSHConnection.accepts(socket: "relative/123", in: directory))
    }

    @Test func printableStripsCsiSequencesAndKeepsText() {
        let bytes = Array("\u{1B}[1;31mbob@example.com's\u{1B}[0m password: \u{1B}[?25h".utf8)
        #expect(SSHConnection.printable(bytes) == "bob@example.com's password: ")
    }

    @Test func printableNormalisesLineBreaksAndDropsControlBytes() {
        #expect(SSHConnection.printable(Array("a\rb\u{07}c\u{00}d".utf8)) == "a\nbcd")
    }

    @Test func printableDropsAnOscSequenceCompletely() {
        let bytes = Array("\u{1B}]0;window title\u{07}bob@example.com's password: ".utf8)
        #expect(SSHConnection.printable(bytes) == "bob@example.com's password: ")
    }
}

@MainActor
struct RemoteProbeTests {
    @Test func parsesShellAndVersion() {
        #expect(RemoteProbe(output: "zsh\n1a2b\n") == RemoteProbe(shell: "zsh", version: "1a2b"))
    }

    @Test func missingVersionIsNil() {
        #expect(RemoteProbe(output: "bash\n") == RemoteProbe(shell: "bash", version: nil))
        #expect(RemoteProbe(output: "bash") == RemoteProbe(shell: "bash", version: nil))
    }

    @Test func emptyOutputIsRejected() {
        #expect(RemoteProbe(output: "") == nil)
        #expect(RemoteProbe(output: "\n\n") == nil)
    }

    @Test func supportedShells() {
        #expect(RemoteShellKind.supports("zsh"))
        #expect(RemoteShellKind.supports("fish"))
        #expect(!RemoteShellKind.supports("tcsh"))
        #expect(RemoteShellKind(rawValue: "bash-legacy") == .legacyBash)
    }
}

@MainActor
struct RemoteInstallScriptTests {
    private func install(into home: URL) throws -> Int32 {
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        return try execute("/bin/sh", ["-s"], environment: environment, input: Data(RemoteShellInstall.installScript().utf8)).status
    }

    private func installed(_ home: URL, _ path: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(".turm/shell/" + path), encoding: .utf8)
    }

    @Test func installsEveryFileWithItsContents() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try install(into: home) == 0)

        let expectedPaths = ["bootstrap.sh", "rc.bash", "integration.fish", "zsh/.zshenv", "zsh/.zprofile", "zsh/.zshrc"]
        #expect(RemoteShellInstall.files.map(\.path) == expectedPaths)
        for file in RemoteShellInstall.files {
            // A heredoc always ends with a newline, so a file lacking one gains exactly one.
            let expected = file.contents.hasSuffix("\n") ? file.contents : file.contents + "\n"
            #expect(try installed(home, file.path) == expected, "\(file.path)")
        }
    }

    @Test func writesTheVersionFile() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try install(into: home) == 0)
        #expect(try installed(home, "version") == RemoteShellInstall.version + "\n")
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try install(into: home) == 0)
        let root = home.appendingPathComponent(".turm/shell")
        let names = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
        #expect(!names.isEmpty)
        #expect(names.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func installingTwiceIsIdempotent() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try install(into: home) == 0)
        let first = try installed(home, "bootstrap.sh")
        #expect(try install(into: home) == 0)
        #expect(try installed(home, "bootstrap.sh") == first)
    }

    @Test func versionIsStableAndShaped() {
        let version = RemoteShellInstall.version
        #expect(version == RemoteShellInstall.version)
        #expect(version.count == 16)
        #expect(version.allSatisfy { "0123456789abcdef".contains($0) })
    }
}

@MainActor
struct RemoteWrapperTests {
    private struct Rig: Sendable {
        let root: URL
        let wrapper: String
        let fake: String
        let state: String
        let hosts: URL
    }

    private func makeRig() throws -> Rig {
        let root = try scratchDirectory()
        let wrapper = root.appendingPathComponent("turm-ssh")
        try write(RemoteIntegration.wrapper, to: wrapper, mode: 0o755)
        let fake = root.appendingPathComponent("fake-ssh")
        let script = """
        #!/bin/sh
        if [ "$1" = -G ]; then
          printf 'user bob\\nhostname example.com\\nport 2222\\nsessiontype default\\nrequesttty auto\\n'
          exit 0
        fi
        for a in "$@"; do printf '[%s]\\n' "$a"; done

        """
        try write(script, to: fake, mode: 0o755)
        let hosts = root.appendingPathComponent("h", isDirectory: true)
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        return Rig(root: root, wrapper: wrapper.path, fake: fake.path, state: root.path + "/s", hosts: hosts)
    }

    private nonisolated static func environment(_ rig: Rig) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "TURM_SSH_BINARY": rig.fake, "TURM_SSH_STATE": rig.state, "TURM_SSH_HOSTS": rig.hosts.path]
    }

    @concurrent
    private nonisolated static func runOnTerminal(_ rig: Rig, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let namePointer = try #require(ptsname(master))
        let name = String(cString: namePointer)
        let slave = open(name, O_RDWR | O_NOCTTY)
        try #require(slave >= 0)
        defer { close(slave) }
        let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rig.wrapper)
        process.arguments = arguments
        process.environment = Self.environment(rig)
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if !process.isRunning {
                break
            } else {
                usleep(2000)
            }
        }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return (process.terminationStatus, text)
    }

    private func split(_ output: String) -> (socket: String?, target: String?, arguments: [String]) {
        var text = output
        var socket: String?
        var target: String?
        if let start = text.range(of: "\u{1B}]7777;S;"), let end = text.range(of: "\u{07}", range: start.upperBound..<text.endIndex) {
            let fields = text[start.upperBound..<end.lowerBound].split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            socket = fields.first.map(String.init)
            target = fields.count > 1 ? String(fields[1]) : nil
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let arguments = text.split(separator: "\n").filter { $0.hasPrefix("[") && $0.hasSuffix("]") }.map { String($0.dropFirst().dropLast()) }
        return (socket, target, arguments)
    }

    @Test func interactiveHostEmitsTheSocketEventAndUsesAControlMaster() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let result = try await Self.runOnTerminal(rig, ["prod"])
        #expect(result.status == 0)
        let parsed = split(result.output)
        let socket = try #require(parsed.socket)
        #expect(socket.hasPrefix(rig.state + "/"))
        let name = socket.dropFirst(rig.state.count + 1)
        #expect(!name.isEmpty && name.allSatisfy(\.isNumber))
        #expect(parsed.target == "bob@example.com:2222")
        #expect(parsed.arguments == [
            "-o", "ControlMaster=auto", "-o", "ControlPath=" + socket, "-o", "ControlPersist=30", "prod",
        ])
    }

    @Test func commandOnTheLineIsPassedThroughWithoutAnEvent() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let parsed = split(try await Self.runOnTerminal(rig, ["prod", "ls"]).output)
        #expect(parsed.socket == nil)
        #expect(parsed.arguments == ["prod", "ls"])
    }

    @Test func noShellOptionIsPassedThroughWithoutAnEvent() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let parsed = split(try await Self.runOnTerminal(rig, ["-N", "prod"]).output)
        #expect(parsed.socket == nil)
        #expect(parsed.arguments == ["-N", "prod"])
    }

    @Test func optionsWithValuesStillCountAsInteractive() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let parsed = split(try await Self.runOnTerminal(rig, ["-o", "User=x", "-p", "2222", "prod"]).output)
        #expect(parsed.socket != nil)
        #expect(parsed.target == "bob@example.com:2222")
        #expect(Array(parsed.arguments.suffix(5)) == ["-o", "User=x", "-p", "2222", "prod"])
        #expect(parsed.arguments.contains("ControlMaster=auto"))
    }

    @Test func aMarkedHostGetsATerminalAndTheBootstrapCommand() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try write("1\n", to: rig.hosts.appendingPathComponent("bob@example.com:2222"))
        let parsed = split(try await Self.runOnTerminal(rig, ["prod"]).output)
        let socket = try #require(parsed.socket)
        #expect(parsed.arguments == [
            "-t", "-o", "ControlMaster=auto", "-o", "ControlPath=" + socket, "-o", "ControlPersist=30", "prod",
            RemoteIntegration.launchCommand,
        ])
    }

    @Test func withoutATerminalItExecsSshWithTheOriginalArguments() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let result = try execute(rig.wrapper, ["prod"], environment: Self.environment(rig))
        #expect(result.status == 0)
        #expect(result.output == "[prod]\n")
    }

    @Test func withoutStateItExecsSshWithTheOriginalArguments() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        var env = Self.environment(rig)
        env.removeValue(forKey: "TURM_SSH_STATE")
        let result = try execute(rig.wrapper, ["-p", "22", "prod"], environment: env)
        #expect(result.output == "[-p]\n[22]\n[prod]\n")
    }
}
