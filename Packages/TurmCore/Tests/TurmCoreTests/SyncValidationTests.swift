import Foundation
import Testing
@testable import TurmCore

struct SSHHostValidationTests {
    private func accepts(_ host: SSHHost) -> Bool { SSHHostValidation.normalized(host) != nil }

    @Test func rejectsOptionLikeAndMalformedFields() {
        #expect(!accepts(SSHHost(key: "a", hostname: "-oProxyCommand=touch /tmp/x")))
        #expect(!accepts(SSHHost(key: "a", hostname: "-oProxyCommand=id")))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com", user: "-oProxyCommand=id")))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com", user: "bob@evil")))
        #expect(!accepts(SSHHost(key: "a", hostname: "exa mple.com")))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com\nid")))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com", user: "bo b")))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com", port: 0)))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com", port: 70000)))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com", identityFile: "-oProxyCommand=id")))
        #expect(!accepts(SSHHost(key: "a", hostname: "example.com", identityFile: "/k\u{0}ey")))
        #expect(!accepts(SSHHost(key: "!!!", hostname: "example.com")))
    }

    @Test func problemExplainsEachRefusal() {
        #expect(SSHHostValidation.problem(SSHHost(key: "a", hostname: "-oX")) != nil)
        #expect(SSHHostValidation.problem(SSHHost(key: "a", hostname: "a b")) != nil)
        #expect(SSHHostValidation.problem(SSHHost(key: "a", hostname: "h", user: "u@v")) != nil)
        #expect(SSHHostValidation.problem(SSHHost(key: "a", hostname: "h", port: 0)) != nil)
        #expect(SSHHostValidation.problem(SSHHost(key: "a", hostname: "h", identityFile: "-i")) != nil)
        #expect(SSHHostValidation.problem(SSHHost(key: "", hostname: "")) == nil)
        #expect(SSHHostValidation.problem(SSHHost(key: "a", hostname: "example.com", user: "bob")) == nil)
    }

    @Test func acceptsOrdinaryHostsAndNormalises() throws {
        let host = SSHHost(key: " prod ", hostname: " example.com ", user: " bob ", port: 22, identityFile: "  ")
        let clean = try #require(SSHHostValidation.normalized(host))
        #expect(clean.key == "prod")
        #expect(clean.hostname == "example.com")
        #expect(clean.user == "bob")
        #expect(clean.identityFile == nil)
        #expect(accepts(SSHHost(key: "v6", hostname: "::1")))
        #expect(accepts(SSHHost(key: "k", hostname: "10.0.0.5", identityFile: "/Users/me/.ssh/id_ed25519")))
    }

    @Test func saveRefusesDangerousHosts() throws {
        let suite = "turm.validation.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostStore(defaults: defaults)
        #expect(!store.save(SSHHost(key: "bad", hostname: "-oProxyCommand=id")))
        #expect(store.hosts.isEmpty)
        #expect(store.save(SSHHost(key: "ok", hostname: "example.com", port: 99999)))
        #expect(store.hosts.first?.port == nil)
    }

    @Test func applyRemoteDropsDangerousRecordsAndKeepsLocal() throws {
        let suite = "turm.validation.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostStore(defaults: defaults)
        store.save(SSHHost(key: "prod", hostname: "example.com"))
        let local = try #require(store.hosts.first)
        var hostile = local
        hostile.hostname = "-oProxyCommand=id"
        hostile.modified = Date().addingTimeInterval(60)
        let fresh = SSHHost(key: "new", hostname: "a b", modified: Date())
        store.applyRemote([hostile, fresh], removing: [])
        #expect(store.hosts == [local])
    }

    @Test func applyRemoteSanitisesShortcutKeys() throws {
        let suite = "turm.validation.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        store.applyRemote([
            Shortcut(kind: .command, key: "!ll", name: "", value: "ls -la", modified: Date()),
            Shortcut(kind: .command, key: "!!!", name: "", value: "ls", modified: Date()),
            Shortcut(kind: .command, key: "empty", name: "", value: "  ", modified: Date()),
        ], removing: [])
        #expect(store.items.map(\.key) == ["ll"])
    }
}

struct SSHRouteArgumentTests {
    private func single(_ text: String) -> String { "'" + text + "'" }

    @Test func destinationFollowsDoubleDash() throws {
        let host = SSHHost(key: "prod", hostname: "example.com", user: "bob", port: 2200, identityFile: "/keys/id")
        let route = try #require(SSHRoute.parse(">prod uptime", hosts: [host]))
        #expect(route.command(remote: false, quote: single) == "ssh -p 2200 -i '/keys/id' -o IdentitiesOnly=yes -- 'bob@example.com' uptime")
    }

    @Test func hostileDestinationIsNeverParsedAsAnOption() throws {
        let host = SSHHost(key: "bad", hostname: "-oProxyCommand=id")
        let route = try #require(SSHRoute.parse(">bad", hosts: [host]))
        let words = route.command(remote: false, quote: single).components(separatedBy: " ")
        let dashes = try #require(words.firstIndex(of: "--"))
        let option = try #require(words.firstIndex { $0.contains("ProxyCommand") })
        #expect(dashes < option)
    }

    @Test func adHocTokenAlsoGetsDoubleDash() throws {
        let route = try #require(SSHRoute.parse(">-oProxy", hosts: []))
        #expect(route.command(remote: false, quote: single) == "ssh -- '-oProxy'")
    }
}
