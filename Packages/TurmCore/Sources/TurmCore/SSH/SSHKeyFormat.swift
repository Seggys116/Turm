import CryptoKit
import Foundation

public nonisolated struct SSHKey: Equatable, Identifiable, Sendable {
    public let path: String
    public let type: String
    public let comment: String
    public let fingerprint: String?

    public var id: String { path }

    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, type: String, comment: String, fingerprint: String?) {
        self.path = path
        self.type = type
        self.comment = comment
        self.fingerprint = fingerprint
    }

    public var typeLabel: String {
        switch type {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case "sk-ssh-ed25519@openssh.com": "ED25519-SK"
        case "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK"
        case let other where other.hasPrefix("ecdsa-"): "ECDSA"
        case "": "Key"
        default: type
        }
    }
}

public nonisolated enum SSHKeyDetection: Equatable, Sendable {
    case accepted(path: String, authenticated: Bool)
    case none
    case hostKeyUnknown
    case unreachable(String)
}

public nonisolated enum SSHKeys {
    public static func parsePublicKey(_ line: String) -> (type: String, comment: String, fingerprint: String?)? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
        guard fields.count >= 2 else { return nil }
        let comment = fields.count > 2 ? String(fields[2]) : ""
        return (String(fields[0]), comment, fingerprint(ofBase64: String(fields[1])))
    }

    public static func fingerprint(ofBase64 blob: String) -> String? {
        guard let data = Data(base64Encoded: blob) else { return nil }
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    public static func acceptedKey(inVerboseOutput text: String) -> (path: String, authenticated: Bool)? {
        var accepted: String?
        var authenticated = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "Server accepts key: ") {
                let rest = line[range.upperBound...]
                accepted = rest.split(separator: " ").first.map(String.init)
            } else if line.contains("Authenticated to ") {
                authenticated = true
            }
        }
        return accepted.map { ($0, authenticated) }
    }
}
