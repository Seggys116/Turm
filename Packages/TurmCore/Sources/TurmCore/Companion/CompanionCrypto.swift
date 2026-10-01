import CryptoKit
import Foundation
import Security

public nonisolated enum CompanionSide: Sendable {
    case phone
    case mac
}

public nonisolated enum CompanionCryptoError: Error, Equatable {
    case invalidPublicKey
    case weakSharedSecret
}

public nonisolated enum CompanionBootstrap: Sendable, Equatable {
    case qr(secret: Data)
    case code(String)

    public static let qrIdentity = "pair.qr"
    public static let codeIdentity = "pair.code"

    public var identity: String {
        switch self {
        case .qr: Self.qrIdentity
        case .code: Self.codeIdentity
        }
    }

    // a typed code is guessable offline, so the Mac user must confirm the check code before it trusts the device
    public var requiresApproval: Bool {
        if case .code = self { return true }
        return false
    }

    public var key: Data {
        switch self {
        case .qr(let secret):
            CompanionCrypto.hkdf(secret, salt: "turm.companion.v1.bootstrap", info: "qr")
        case .code(let code):
            CompanionCrypto.hkdf(Data(CompanionCrypto.normalizeCode(code).utf8), salt: "turm.companion.v1.bootstrap", info: "code")
        }
    }
}

public nonisolated enum CompanionCrypto {
    public static let secretLength = 32
    public static let codeLength = 8

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    public static func generateSecret() -> Data {
        randomBytes(secretLength)
    }

    public static func generateCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt64.random(in: 0..<100_000_000, using: &generator)
        return String(format: "%08llu", value)
    }

    public static func normalizeCode(_ text: String) -> String {
        String(text.filter(\.isASCII).filter(\.isNumber))
    }

    public static func isValidCode(_ text: String) -> Bool {
        normalizeCode(text).count == codeLength
    }

    public static func hkdf(_ material: Data, salt: String, info: String, count: Int = 32) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: count
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    public static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("turm.companion.v1.commit".utf8) + publicKey + nonce))
    }

    public static func checkCode(phonePublicKey: Data, macPublicKey: Data, nonce: Data, deviceID: UUID, macID: UUID) -> String {
        var material = phonePublicKey + macPublicKey + nonce
        withUnsafeBytes(of: deviceID.uuid) { material.append(contentsOf: $0) }
        withUnsafeBytes(of: macID.uuid) { material.append(contentsOf: $0) }
        let bytes = hkdf(material, salt: "turm.companion.v1", info: "turm.companion.v1.sas", count: 4)
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    private static func helloMessage(_ deviceID: UUID) -> Data {
        var data = Data("turm.companion.v1.hello".utf8)
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }
        return data
    }

    public static func helloProof(key: Data, deviceID: UUID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: helloMessage(deviceID), using: SymmetricKey(data: key)))
    }

    public static func verifyHelloProof(_ proof: Data, key: Data, deviceID: UUID) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: helloMessage(deviceID), using: SymmetricKey(data: key))
    }
}

public nonisolated struct CompanionPairingResult: Sendable, Equatable {
    public let key: Data
    let transcript: Data

    private func label(_ side: CompanionSide) -> Data {
        Data((side == .phone ? "turm.companion.v1.confirm.phone" : "turm.companion.v1.confirm.mac").utf8) + transcript
    }

    public func tag(for side: CompanionSide) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: label(side), using: SymmetricKey(data: key)))
    }

    public func verify(_ tag: Data, from side: CompanionSide) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: label(side), using: SymmetricKey(data: key))
    }

    init(key: Data, transcript: Data) {
        self.key = key
        self.transcript = transcript
    }
}

public nonisolated struct CompanionPairingKeys {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()

    public init() {}

    public var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }

    public func derive(
        peerPublicKey: Data, bootstrapKey: Data, side: CompanionSide, deviceID: UUID
    ) throws -> CompanionPairingResult {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else {
            throw CompanionCryptoError.invalidPublicKey
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        guard sharedBytes.contains(where: { $0 != 0 }) else { throw CompanionCryptoError.weakSharedSecret }
        let phone = side == .phone ? publicKey : peerPublicKey
        let mac = side == .phone ? peerPublicKey : publicKey
        var transcript = phone + mac
        withUnsafeBytes(of: deviceID.uuid) { transcript.append(contentsOf: $0) }
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: bootstrapKey, sharedInfo: Data("turm.companion.v1".utf8) + transcript, outputByteCount: 32
        )
        return CompanionPairingResult(key: derived.withUnsafeBytes { Data($0) }, transcript: transcript)
    }
}
