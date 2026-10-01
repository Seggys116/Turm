import Foundation
import TurmCore

/// Moves private keys between files on this Mac and the keys Turm stores (and syncs).
enum StoredKeys {
    static let sizeLimit = 64 * 1024

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Reads the key file once, up to the size limit.
    static func read(path: String) throws -> String {
        let url = URL(fileURLWithPath: SSHKeyLinking.resolve(path))
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure(errorDescription: "Could not read \(url.lastPathComponent).")
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sizeLimit + 1), let text = String(data: data, encoding: .utf8) else {
            throw Failure(errorDescription: "Could not read \(url.lastPathComponent).")
        }
        return text
    }

    /// Stores the key (reusing an identical stored key) and points every host that names this file at it.
    @discardableResult
    static func store(path: String, text: String, passphrase: String?) throws -> SSHIdentity {
        let identities = SSHIdentityStore.shared
        let info = try SSHIdentityStore.inspect(text)
        let identity: SSHIdentity
        if !info.publicKey.isEmpty, let existing = identities.identities.first(where: { $0.publicKey == info.publicKey }) {
            identity = existing
        } else {
            let name = URL(fileURLWithPath: path).lastPathComponent
            identity = try identities.importKey(name: name, privateKey: text, passphrase: passphrase)
        }
        SSHHostStore.shared.link(identity.id, toFile: path)
        return identity
    }

    static func remove(_ id: UUID) {
        SSHIdentityStore.shared.remove(id)
        SSHHostStore.shared.unlink(id)
    }

    /// The stored key that matches this file, by public key fingerprint or by a host that already links it.
    static func identity(for key: SSHKey) -> SSHIdentity? {
        let identities = SSHIdentityStore.shared
        if let fingerprint = key.fingerprint,
           let match = identities.identities.first(where: { SSHKeys.parsePublicKey($0.publicKey)?.fingerprint == fingerprint }) {
            return match
        }
        for host in SSHKeyLinking.hosts(usingFile: key.path, in: SSHHostStore.shared.hosts) {
            if let id = host.identityKeyID, let match = identities.identity(id) { return match }
        }
        return nil
    }

    static func hosts(using key: SSHKey) -> [SSHHost] {
        SSHKeyLinking.hosts(usingFile: key.path, in: SSHHostStore.shared.hosts)
    }

    /// Private keys in ~/.ssh plus key files that hosts name outside it.
    static func keys(discovered: [SSHKey]) -> [SSHKey] {
        var list = discovered
        for host in SSHHostStore.shared.hosts {
            guard let file = host.identityFile, !file.isEmpty else { continue }
            let path = SSHKeyLinking.resolve(file)
            guard !list.contains(where: { SSHKeyLinking.resolve($0.path) == path }), SSHKeys.isPrivateKey(atPath: path) else { continue }
            list.append(SSHKey(path: path, type: "", comment: "", fingerprint: nil))
        }
        return list
    }
}
