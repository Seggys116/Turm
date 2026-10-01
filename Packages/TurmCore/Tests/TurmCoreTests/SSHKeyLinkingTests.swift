import Foundation
import Testing
@testable import TurmCore

struct SSHKeyLinkingTests {
    private let home = "/Users/me"

    @Test func resolvesTildeAndDots() {
        #expect(SSHKeyLinking.resolve("~/.ssh/id_ed25519", home: home) == "/Users/me/.ssh/id_ed25519")
        #expect(SSHKeyLinking.resolve("/Users/me/.ssh/../.ssh/./id_ed25519", home: home) == "/Users/me/.ssh/id_ed25519")
        #expect(SSHKeyLinking.resolve(" ~ ", home: home) == "/Users/me")
        #expect(SSHKeyLinking.resolve("~other/key", home: home).hasSuffix("~other/key"))
    }

    @Test func findsHostsByResolvedPath() {
        let hosts = [
            SSHHost(key: "a", hostname: "a.com", identityFile: "~/.ssh/id_ed25519"),
            SSHHost(key: "b", hostname: "b.com", identityFile: "/Users/me/.ssh/id_ed25519"),
            SSHHost(key: "c", hostname: "c.com", identityFile: "/Users/me/.ssh/other"),
            SSHHost(key: "d", hostname: "d.com"),
        ]
        let found = SSHKeyLinking.hosts(usingFile: "/Users/me/.ssh/id_ed25519", in: hosts, home: home)
        #expect(found.map(\.key) == ["a", "b"])
    }

    @Test func linkingSkipsHostsAlreadyLinked() {
        let id = UUID()
        let hosts = [
            SSHHost(key: "a", hostname: "a.com", identityFile: "~/.ssh/k", identityKeyID: id),
            SSHHost(key: "b", hostname: "b.com", identityFile: "~/.ssh/k"),
        ]
        let updated = SSHKeyLinking.linked(id, toFile: "/Users/me/.ssh/k", in: hosts, home: home)
        #expect(updated.map(\.key) == ["b"])
        #expect(updated.first?.identityKeyID == id)
    }

    @Test func unlinkingClearsOnlyThatKey() {
        let id = UUID()
        let hosts = [
            SSHHost(key: "a", hostname: "a.com", identityKeyID: id),
            SSHHost(key: "b", hostname: "b.com", identityKeyID: UUID()),
        ]
        let updated = SSHKeyLinking.unlinked(id, in: hosts)
        #expect(updated.map(\.key) == ["a"])
        #expect(updated.first?.identityKeyID == nil)
    }

    @Test func storeLinkSavesAndStamps() throws {
        let suite = "turm.link.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostStore(defaults: defaults)
        let file = NSHomeDirectory() + "/.ssh/turm-link-test"
        store.save(SSHHost(key: "a", hostname: "a.com", identityFile: file))
        store.save(SSHHost(key: "b", hostname: "b.com"))
        let id = UUID()
        #expect(store.link(id, toFile: file) == 1)
        #expect(store.hosts.first { $0.key == "a" }?.identityKeyID == id)
        #expect(store.hosts.first { $0.key == "b" }?.identityKeyID == nil)
        #expect(store.unlink(id) == 1)
        #expect(store.hosts.allSatisfy { $0.identityKeyID == nil })
    }
}

struct SSHIdentityOrderTests {
    @Test func edBeforeEcdsaBeforeRSAStable() {
        func make(_ name: String, _ algorithm: String) -> SSHIdentity { SSHIdentity(name: name, algorithm: algorithm, publicKey: "") }
        let list = [
            make("rsa1", "ssh-rsa"), make("ec", "ecdsa-sha2-nistp256"), make("ed1", "ssh-ed25519"),
            make("odd", "ssh-dss"), make("ed2", "ssh-ed25519"), make("rsa2", "ssh-rsa"),
        ]
        #expect(SSHIdentity.defaultOrder(list).map(\.name) == ["ed1", "ed2", "ec", "rsa1", "rsa2", "odd"])
    }
}
