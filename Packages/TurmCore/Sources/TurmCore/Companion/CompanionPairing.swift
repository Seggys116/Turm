import Foundation

public nonisolated struct CompanionPairingClient {
    public nonisolated enum Step: Equatable {
        case confirm(code: String, send: CompanionMessage)
        case finished(macID: UUID, macName: String, key: Data)
        case failed(String)
    }

    private nonisolated enum Stage {
        case start
        case awaitingKey
        case awaitingDone(macID: UUID, macName: String, result: CompanionPairingResult)
        case closed
    }

    private let bootstrap: CompanionBootstrap
    private let deviceID: UUID
    private let deviceName: String
    private let keys = CompanionPairingKeys()
    private let nonce = CompanionCrypto.randomBytes(32)
    private var stage = Stage.start

    public init(bootstrap: CompanionBootstrap, deviceID: UUID, deviceName: String) {
        self.bootstrap = bootstrap
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public mutating func begin() -> CompanionMessage {
        stage = .awaitingKey
        return .pairBegin(deviceID: deviceID, name: deviceName, commitment: CompanionCrypto.commitment(publicKey: keys.publicKey, nonce: nonce))
    }

    public mutating func receive(_ message: CompanionMessage) -> Step {
        switch (stage, message) {
        case (.awaitingKey, .pairKey(let macID, let macName, let publicKey)):
            do {
                let result = try keys.derive(peerPublicKey: publicKey, bootstrapKey: bootstrap.key, side: .phone, deviceID: deviceID)
                stage = .awaitingDone(macID: macID, macName: macName, result: result)
                let code = CompanionCrypto.checkCode(
                    phonePublicKey: keys.publicKey, macPublicKey: publicKey, nonce: nonce, deviceID: deviceID, macID: macID
                )
                let reveal = CompanionMessage.pairReveal(publicKey: keys.publicKey, nonce: nonce, confirmation: result.tag(for: .phone))
                return .confirm(code: code, send: reveal)
            } catch {
                stage = .closed
                return .failed("The Mac sent an invalid key.")
            }
        case (.awaitingDone(let macID, let macName, let result), .pairDone(let confirmation)):
            stage = .closed
            guard result.verify(confirmation, from: .mac) else { return .failed("The Mac could not be verified.") }
            return .finished(macID: macID, macName: macName, key: result.key)
        case (_, .error(_, let text)):
            stage = .closed
            return .failed(text)
        default:
            stage = .closed
            return .failed("Unexpected message while pairing.")
        }
    }
}

// the Mac tries every currently valid secret, since it cannot see which one the phone used
public nonisolated struct CompanionPairingResponder {
    public nonisolated enum Step {
        case send(CompanionMessage)
        case approval(code: String, deviceID: UUID, name: String)
        case finished(deviceID: UUID, name: String, key: Data, reply: CompanionMessage)
        case rejected(String)
    }

    private nonisolated enum Stage {
        case awaitingBegin
        case awaitingReveal(deviceID: UUID, name: String, commitment: Data)
        case awaitingApproval(deviceID: UUID, name: String, key: Data, reply: CompanionMessage)
        case closed
    }

    private let candidates: [CompanionBootstrap]
    private let macID: UUID
    private let macName: String
    private let keys = CompanionPairingKeys()
    private var stage = Stage.awaitingBegin

    public init(candidates: [CompanionBootstrap], macID: UUID, macName: String) {
        self.candidates = candidates
        self.macID = macID
        self.macName = macName
    }

    public mutating func receive(_ message: CompanionMessage) -> Step {
        switch (stage, message) {
        case (.awaitingBegin, .pairBegin(let deviceID, let name, let commitment)):
            guard commitment.count == 32 else {
                stage = .closed
                return .rejected("The pairing request was malformed.")
            }
            stage = .awaitingReveal(deviceID: deviceID, name: name, commitment: commitment)
            return .send(.pairKey(macID: macID, macName: macName, publicKey: keys.publicKey))
        case (.awaitingReveal(let deviceID, let name, let commitment), .pairReveal(let phoneKey, let nonce, let confirmation)):
            stage = .closed
            guard nonce.count == 32,
                  CompanionCrypto.constantTimeEqual(CompanionCrypto.commitment(publicKey: phoneKey, nonce: nonce), commitment)
            else { return .rejected("The pairing commitment did not match.") }
            for candidate in candidates {
                guard let result = try? keys.derive(peerPublicKey: phoneKey, bootstrapKey: candidate.key, side: .mac, deviceID: deviceID),
                      result.verify(confirmation, from: .phone)
                else { continue }
                let reply = CompanionMessage.pairDone(confirmation: result.tag(for: .mac))
                guard candidate.requiresApproval else {
                    return .finished(deviceID: deviceID, name: name, key: result.key, reply: reply)
                }
                stage = .awaitingApproval(deviceID: deviceID, name: name, key: result.key, reply: reply)
                let code = CompanionCrypto.checkCode(
                    phonePublicKey: phoneKey, macPublicKey: keys.publicKey, nonce: nonce, deviceID: deviceID, macID: macID
                )
                return .approval(code: code, deviceID: deviceID, name: name)
            }
            return .rejected("The pairing code or QR code did not match.")
        default:
            stage = .closed
            return .rejected("Unexpected message while pairing.")
        }
    }

    public mutating func approve() -> Step {
        guard case .awaitingApproval(let deviceID, let name, let key, let reply) = stage else {
            return .rejected("There is nothing to approve.")
        }
        stage = .closed
        return .finished(deviceID: deviceID, name: name, key: key, reply: reply)
    }
}
