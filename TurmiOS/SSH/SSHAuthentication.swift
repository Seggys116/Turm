import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import TurmCore

nonisolated struct SSHHostKeyRejected: Error {}

nonisolated enum SSHKeyError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let algorithm):
            "Keys of type \(algorithm.isEmpty ? "unknown" : algorithm) are not supported. Use ed25519, RSA, or an ECDSA key in PEM format."
        }
    }
}

nonisolated enum SSHAuthentication {
    static func method(
        username: String, algorithm: String, privateKey: String, passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let decryption = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        switch algorithm {
        case "ssh-ed25519":
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: privateKey, decryptionKey: decryption)
            return .ed25519(username: username, privateKey: key)
        case "ssh-rsa":
            let key = try Insecure.RSA.PrivateKey(sshRsa: privateKey, decryptionKey: decryption)
            return .rsa(username: username, privateKey: key)
        case "ecdsa-sha2-nistp256":
            return .p256(username: username, privateKey: try P256.Signing.PrivateKey(pemRepresentation: privateKey))
        case "ecdsa-sha2-nistp384":
            return .p384(username: username, privateKey: try P384.Signing.PrivateKey(pemRepresentation: privateKey))
        case "ecdsa-sha2-nistp521":
            return .p521(username: username, privateKey: try P521.Signing.PrivateKey(pemRepresentation: privateKey))
        default:
            throw SSHKeyError.unsupported(algorithm)
        }
    }
}

nonisolated final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let decide: @MainActor @Sendable (String) async -> Bool

    init(decide: @escaping @MainActor @Sendable (String) async -> Bool) {
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let decide = decide
        Task {
            if await decide(line) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHHostKeyRejected())
            }
        }
    }
}
