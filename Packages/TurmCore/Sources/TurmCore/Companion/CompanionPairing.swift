import Foundation

public nonisolated struct CompanionPairingClient {
    public nonisolated enum Step: Equatable {
        case confirm(code: String, send: CompanionMessage)
        case waiting
        case finished(macID: UUID, macName: String, key: Data)
        case finishing(send: CompanionMessage, macID: UUID, macName: String, key: Data)
        case failed(String)
    }

    private nonisolated enum Stage {
        case start
        case awaitingKey
        case awaitingDone(macID: UUID, macName: String, result: CompanionPairingResult, approved: Bool, confirms: Bool)
        case awaitingApproval(macID: UUID, macName: String, result: CompanionPairingResult, confirms: Bool)
        case awaitingStored(macID: UUID, macName: String, key: Data)
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
        return .pairBegin(
            deviceID: deviceID, name: deviceName, commitment: CompanionCrypto.commitment(publicKey: keys.publicKey, nonce: nonce),
            confirms: bootstrap.requiresApproval ? true : nil
        )
    }

    public mutating func receive(_ message: CompanionMessage) -> Step {
        switch (stage, message) {
        case (.awaitingKey, .pairKey(let macID, let macName, let publicKey, let awaitsConfirm)):
            do {
                let result = try keys.derive(peerPublicKey: publicKey, bootstrapKey: bootstrap.key, side: .phone, deviceID: deviceID)
                let confirms = bootstrap.requiresApproval && awaitsConfirm == true
                stage = .awaitingDone(macID: macID, macName: macName, result: result, approved: !bootstrap.requiresApproval, confirms: confirms)
                let code = CompanionCrypto.checkCode(
                    phonePublicKey: keys.publicKey, macPublicKey: publicKey, nonce: nonce, deviceID: deviceID, macID: macID
                )
                let reveal = CompanionMessage.pairReveal(publicKey: keys.publicKey, nonce: nonce, confirmation: result.tag(for: .phone))
                return .confirm(code: code, send: reveal)
            } catch {
                stage = .closed
                return .failed("The Mac sent an invalid key.")
            }
        case (.awaitingDone(let macID, let macName, let result, let approved, let confirms), .pairDone(let confirmation)):
            stage = .closed
            guard result.verify(confirmation, from: .mac) else { return .failed("The Mac could not be verified.") }
            guard approved else {
                stage = .awaitingApproval(macID: macID, macName: macName, result: result, confirms: confirms)
                return .waiting
            }
            return release(macID: macID, macName: macName, key: result.key, confirms: confirms)
        case (.awaitingStored(let macID, let macName, let key), .pairConfirm):
            stage = .closed
            return .finished(macID: macID, macName: macName, key: key)
        case (_, .error(_, let text)):
            stage = .closed
            return .failed(text)
        default:
            stage = .closed
            return .failed("Unexpected message while pairing.")
        }
    }

    public mutating func approve() -> Step {
        switch stage {
        case .awaitingDone(let macID, let macName, let result, _, let confirms):
            stage = .awaitingDone(macID: macID, macName: macName, result: result, approved: true, confirms: confirms)
            return .waiting
        case .awaitingApproval(let macID, let macName, let result, let confirms):
            stage = .closed
            return release(macID: macID, macName: macName, key: result.key, confirms: confirms)
        default:
            return .failed("There is nothing to approve.")
        }
    }

    public mutating func reject() -> Step {
        stage = .closed
        return .failed("The check codes did not match, so pairing was stopped. Someone may be intercepting the connection.")
    }

    private mutating func release(macID: UUID, macName: String, key: Data, confirms: Bool) -> Step {
        guard confirms else { return .finished(macID: macID, macName: macName, key: key) }
        stage = .awaitingStored(macID: macID, macName: macName, key: key)
        return .finishing(send: .pairConfirm, macID: macID, macName: macName, key: key)
    }
}

// the Mac tries every currently valid secret, since it cannot see which one the phone used
public nonisolated struct CompanionPairingResponder {
    public nonisolated enum Step {
        case send(CompanionMessage)
        case approval(code: String, deviceID: UUID, name: String)
        case awaitConfirm(deviceID: UUID, reply: CompanionMessage)
        case confirmed(deviceID: UUID, name: String, key: Data)
        case finished(deviceID: UUID, name: String, key: Data, reply: CompanionMessage)
        case rejected(String)
    }

    private nonisolated enum Stage {
        case awaitingBegin
        case awaitingReveal(deviceID: UUID, name: String, commitment: Data, awaitsConfirm: Bool)
        case awaitingApproval(deviceID: UUID, name: String, key: Data, reply: CompanionMessage, awaitsConfirm: Bool)
        case awaitingConfirm(deviceID: UUID, name: String, key: Data)
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
        case (.awaitingBegin, .pairBegin(let deviceID, let name, let commitment, let confirms)):
            guard commitment.count == 32 else {
                stage = .closed
                return .rejected("The pairing request was malformed.")
            }
            let awaitsConfirm = confirms == true && candidates.contains { $0.requiresApproval }
            stage = .awaitingReveal(deviceID: deviceID, name: name, commitment: commitment, awaitsConfirm: awaitsConfirm)
            return .send(.pairKey(macID: macID, macName: macName, publicKey: keys.publicKey, awaitsConfirm: awaitsConfirm ? true : nil))
        case (.awaitingReveal(let deviceID, let name, let commitment, let awaitsConfirm), .pairReveal(let phoneKey, let nonce, let confirmation)):
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
                stage = .awaitingApproval(deviceID: deviceID, name: name, key: result.key, reply: reply, awaitsConfirm: awaitsConfirm)
                let code = CompanionCrypto.checkCode(
                    phonePublicKey: phoneKey, macPublicKey: keys.publicKey, nonce: nonce, deviceID: deviceID, macID: macID
                )
                return .approval(code: code, deviceID: deviceID, name: name)
            }
            return .rejected("The pairing code or QR code did not match.")
        case (.awaitingConfirm(let deviceID, let name, let key), .pairConfirm):
            stage = .closed
            return .confirmed(deviceID: deviceID, name: name, key: key)
        default:
            stage = .closed
            return .rejected("Unexpected message while pairing.")
        }
    }

    public mutating func approve() -> Step {
        guard case .awaitingApproval(let deviceID, let name, let key, let reply, let awaitsConfirm) = stage else {
            return .rejected("There is nothing to approve.")
        }
        if awaitsConfirm {
            stage = .awaitingConfirm(deviceID: deviceID, name: name, key: key)
            return .awaitConfirm(deviceID: deviceID, reply: reply)
        }
        stage = .closed
        return .finished(deviceID: deviceID, name: name, key: key, reply: reply)
    }
}
