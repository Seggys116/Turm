import Foundation
import Testing
@testable import TurmCore

struct SSHPrivateKeyParserTests {
    @Test func readsEd25519Container() throws {
        let parsed = try SSHPrivateKeyParser.parse(KeyFixtures.ed25519())
        #expect(parsed.algorithm == "ssh-ed25519")
        #expect(parsed.publicKey == KeyFixtures.edPublicLine)
        #expect(!parsed.encrypted)
    }

    @Test func readsRSAContainer() throws {
        let parsed = try SSHPrivateKeyParser.parse(KeyFixtures.rsa())
        #expect(parsed.algorithm == "ssh-rsa")
        #expect(parsed.publicKey == KeyFixtures.rsaPublicLine)
    }

    @Test func flagsEncryptedContainer() throws {
        let parsed = try SSHPrivateKeyParser.parse(KeyFixtures.ed25519(cipher: "aes256-ctr"))
        #expect(parsed.encrypted)
        #expect(parsed.algorithm == "ssh-ed25519")
    }

    @Test func acceptsLegacyRSAPEMWithoutPublicKey() throws {
        let parsed = try SSHPrivateKeyParser.parse(KeyFixtures.pemRSA())
        #expect(parsed.algorithm == "ssh-rsa")
        #expect(parsed.publicKey.isEmpty)
        #expect(!parsed.encrypted)
        #expect(try SSHPrivateKeyParser.parse(KeyFixtures.pemRSA(encrypted: true)).encrypted)
    }

    @Test func rejectsPublicKeys() {
        #expect(throws: SSHIdentityError.publicKeyOnly) { try SSHPrivateKeyParser.parse(KeyFixtures.edPublicLine + " me@host") }
        #expect(throws: SSHIdentityError.publicKeyOnly) { try SSHPrivateKeyParser.parse("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----") }
    }

    @Test func rejectsOtherFormats() {
        #expect(throws: SSHIdentityError.unsupportedFormat) {
            try SSHPrivateKeyParser.parse("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")
        }
        #expect(throws: SSHIdentityError.unsupportedFormat) {
            try SSHPrivateKeyParser.parse("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----")
        }
        #expect(throws: SSHIdentityError.unsupportedFormat) { try SSHPrivateKeyParser.parse("hello") }
    }

    @Test func rejectsDamagedContainers() {
        let truncated = KeyFixtures.armor(Data("openssh-key-v1\0".utf8) + KeyFixtures.string("none"), label: "OPENSSH PRIVATE KEY")
        #expect(throws: SSHIdentityError.malformed) { try SSHPrivateKeyParser.parse(truncated) }
        let notBase64 = "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!!\n-----END OPENSSH PRIVATE KEY-----"
        #expect(throws: SSHIdentityError.malformed) { try SSHPrivateKeyParser.parse(notBase64) }
        let wrongMagic = KeyFixtures.armor(Data("not-a-key-at-all-here".utf8), label: "OPENSSH PRIVATE KEY")
        #expect(throws: SSHIdentityError.malformed) { try SSHPrivateKeyParser.parse(wrongMagic) }
    }

    @Test func rejectsTrailingBytes() {
        let valid = KeyFixtures.container(publicBlob: KeyFixtures.edBlob, privateSection: Data(repeating: 1, count: 16))
        let raw = valid + Data([0, 0, 0])
        #expect(throws: SSHIdentityError.malformed) {
            try SSHPrivateKeyParser.parse(KeyFixtures.armor(raw, label: "OPENSSH PRIVATE KEY"))
        }
    }

    @Test func rejectsOversizedInput() {
        let huge = String(repeating: "A", count: SSHPrivateKeyParser.sizeLimit + 1)
        #expect(throws: SSHIdentityError.tooLarge) { try SSHPrivateKeyParser.parse(huge) }
    }

    @Test func rejectsGarbageBetweenArmorAndBody() {
        let text = "junk\n" + KeyFixtures.ed25519()
        #expect(throws: SSHIdentityError.unsupportedFormat) { try SSHPrivateKeyParser.parse(text) }
    }
}

struct SSHIdentityStoreTests {
    private func makeStore(backing: MemoryBacking = MemoryBacking()) throws -> (SSHIdentityStore, MemoryBacking, UserDefaults, () -> Void) {
        let suite = "turm.identity.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = SSHIdentityStore(defaults: defaults, backing: backing)
        return (store, backing, defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func importKeepsSecretsOutOfDefaults() throws {
        let (store, backing, defaults, cleanup) = try makeStore()
        defer { cleanup() }
        let text = KeyFixtures.ed25519(cipher: "aes256-ctr")
        let identity = try store.importKey(name: "work", privateKey: text, passphrase: "hunter2")
        #expect(identity.name == "work")
        #expect(identity.algorithm == "ssh-ed25519")
        #expect(identity.publicKey == KeyFixtures.edPublicLine)
        #expect(store.privateKey(for: identity.id) == text)
        #expect(store.passphrase(for: identity.id) == "hunter2")
        #expect(store.identity(identity.id) == identity)
        #expect(Set(backing.accounts) == [identity.id.uuidString + ".key", identity.id.uuidString + ".pass"])
        let stored = defaults.string(forKey: SSHIdentityStore.defaultsKey) ?? ""
        #expect(!stored.contains("OPENSSH"))
        #expect(!stored.contains("hunter2"))
        #expect(stored.contains(identity.id.uuidString))
    }

    @Test func passphraseIsStoredOnlyWhenGiven() throws {
        let (store, backing, _, cleanup) = try makeStore()
        defer { cleanup() }
        let identity = try store.importKey(name: "k", privateKey: KeyFixtures.rsa(), passphrase: nil)
        #expect(store.passphrase(for: identity.id) == nil)
        #expect(backing.accounts == [identity.id.uuidString + ".key"])
        let empty = try store.importKey(name: "e", privateKey: KeyFixtures.rsa(), passphrase: "")
        #expect(store.passphrase(for: empty.id) == nil)
    }

    @Test func blankNameFallsBackToAlgorithm() throws {
        let (store, _, _, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(try store.importKey(name: "  ", privateKey: KeyFixtures.pemRSA(), passphrase: nil).name == "ssh-rsa")
    }

    @Test func removeDeletesSecretsAndMetadata() throws {
        let (store, backing, defaults, cleanup) = try makeStore()
        defer { cleanup() }
        let identity = try store.importKey(name: "k", privateKey: KeyFixtures.ed25519(), passphrase: "x")
        store.remove(identity.id)
        #expect(store.identities.isEmpty)
        #expect(backing.accounts.isEmpty)
        #expect(store.privateKey(for: identity.id) == nil)
        #expect(SSHIdentityStore(defaults: defaults, backing: backing).identities.isEmpty)
    }

    @Test func failedStorageLeavesNothingBehind() throws {
        let backing = MemoryBacking()
        backing.failWrites = true
        let (store, _, _, cleanup) = try makeStore(backing: backing)
        defer { cleanup() }
        #expect(throws: SSHIdentityError.storageFailed) { try store.importKey(name: "k", privateKey: KeyFixtures.ed25519(), passphrase: nil) }
        #expect(store.identities.isEmpty)
    }

    @Test func rejectedKeyIsNotStored() throws {
        let (store, backing, _, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(throws: SSHIdentityError.publicKeyOnly) { try store.importKey(name: "k", privateKey: KeyFixtures.edPublicLine, passphrase: nil) }
        #expect(store.identities.isEmpty)
        #expect(backing.accounts.isEmpty)
    }

    @Test func reportsLocalChangesButNotRemoteOnes() throws {
        let (store, _, _, cleanup) = try makeStore()
        defer { cleanup() }
        var changes = 0
        store.onChange = { _ in changes += 1 }
        let identity = try store.importKey(name: "k", privateKey: KeyFixtures.ed25519(), passphrase: nil)
        #expect(changes == 1)
        store.applyRemote([SSHIdentity(name: "r", algorithm: "ssh-rsa", publicKey: "")], removing: [identity.id])
        #expect(changes == 1)
        #expect(store.identities.map(\.name) == ["r"])
    }
}
