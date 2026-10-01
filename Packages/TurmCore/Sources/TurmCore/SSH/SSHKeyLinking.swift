import Foundation

/// Matches hosts to key files and stored keys.
public nonisolated enum SSHKeyLinking {
    public static func resolve(_ path: String, home: String = NSHomeDirectory()) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = home + String(text.dropFirst(1))
        }
        return URL(fileURLWithPath: text).standardizedFileURL.path
    }

    public static func hosts(usingFile path: String, in hosts: [SSHHost], home: String = NSHomeDirectory()) -> [SSHHost] {
        let target = resolve(path, home: home)
        return hosts.filter { host in
            guard let file = host.identityFile, !file.isEmpty else { return false }
            return resolve(file, home: home) == target
        }
    }

    /// Hosts that should point at `keyID` after the key in `path` was stored in Turm.
    public static func linked(_ keyID: UUID, toFile path: String, in hosts: [SSHHost], home: String = NSHomeDirectory()) -> [SSHHost] {
        Self.hosts(usingFile: path, in: hosts, home: home).filter { $0.identityKeyID != keyID }.map {
            var host = $0
            host.identityKeyID = keyID
            return host
        }
    }

    public static func unlinked(_ keyID: UUID, in hosts: [SSHHost]) -> [SSHHost] {
        hosts.filter { $0.identityKeyID == keyID }.map {
            var host = $0
            host.identityKeyID = nil
            return host
        }
    }
}

extension SSHHostStore {
    /// Points every host whose identity file is `path` at the stored key, through save() so the change syncs.
    @discardableResult
    public func link(_ keyID: UUID, toFile path: String) -> Int {
        SSHKeyLinking.linked(keyID, toFile: path, in: hosts).filter { save($0) }.count
    }

    @discardableResult
    public func unlink(_ keyID: UUID) -> Int {
        SSHKeyLinking.unlinked(keyID, in: hosts).filter { save($0) }.count
    }
}
