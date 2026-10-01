import Foundation
import Testing
@testable import TurmCore

struct CompanionPairingTests {
    private let device = UUID()

    private func fail(_ text: Comment) {
        Issue.record(text)
    }

    private func exchange(
        phoneBootstrap: CompanionBootstrap, macBootstrap: CompanionBootstrap
    ) throws -> (phone: CompanionPairingResult, mac: CompanionPairingResult) {
        let phone = CompanionPairingKeys()
        let mac = CompanionPairingKeys()
        return (
            try phone.derive(peerPublicKey: mac.publicKey, bootstrapKey: phoneBootstrap.key, side: .phone, deviceID: device),
            try mac.derive(peerPublicKey: phone.publicKey, bootstrapKey: macBootstrap.key, side: .mac, deviceID: device)
        )
    }

    @Test func bothSidesAgreeOnTheKey() throws {
        let secret = CompanionCrypto.generateSecret()
        let result = try exchange(phoneBootstrap: .qr(secret: secret), macBootstrap: .qr(secret: secret))
        #expect(result.phone.key == result.mac.key)
        #expect(result.phone.key.count == 32)
        #expect(result.mac.verify(result.phone.tag(for: .phone), from: .phone))
        #expect(result.phone.verify(result.mac.tag(for: .mac), from: .mac))
    }

    @Test func aWrongCodeDisagrees() throws {
        let result = try exchange(phoneBootstrap: .code("12345678"), macBootstrap: .code("12345679"))
        #expect(result.phone.key != result.mac.key)
        #expect(!result.mac.verify(result.phone.tag(for: .phone), from: .phone))
    }

    @Test func aTagCannotBeReplayedAsTheOtherSide() throws {
        let result = try exchange(phoneBootstrap: .code("00000001"), macBootstrap: .code("00000001"))
        #expect(!result.mac.verify(result.mac.tag(for: .mac), from: .phone))
    }

    @Test func eachExchangeProducesANewKey() throws {
        let first = try exchange(phoneBootstrap: .code("11112222"), macBootstrap: .code("11112222"))
        let second = try exchange(phoneBootstrap: .code("11112222"), macBootstrap: .code("11112222"))
        #expect(first.phone.key != second.phone.key)
    }

    @Test func rejectsMalformedPublicKeys() {
        let keys = CompanionPairingKeys()
        #expect(throws: CompanionCryptoError.invalidPublicKey) {
            try keys.derive(peerPublicKey: Data([1, 2, 3]), bootstrapKey: Data(count: 32), side: .phone, deviceID: device)
        }
        #expect(throws: (any Error).self) {
            try keys.derive(peerPublicKey: Data(count: 32), bootstrapKey: Data(count: 32), side: .phone, deviceID: device)
        }
    }

    @Test func codesAreEightDigits() {
        for _ in 0..<200 {
            let code = CompanionCrypto.generateCode()
            #expect(code.count == 8)
            #expect(code.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }

    @Test func codeInputIsNormalised() {
        #expect(CompanionCrypto.normalizeCode("1234 5678") == "12345678")
        #expect(CompanionCrypto.normalizeCode("1234-5678") == "12345678")
        #expect(CompanionBootstrap.code("1234 5678").key == CompanionBootstrap.code("12345678").key)
        #expect(!CompanionCrypto.isValidCode("1234567"))
        #expect(CompanionCrypto.isValidCode("12345678"))
    }

    @Test func secretsAreRandom() {
        #expect(CompanionCrypto.generateSecret().count == 32)
        #expect(CompanionCrypto.generateSecret() != CompanionCrypto.generateSecret())
    }

    @Test func constantTimeCompare() {
        #expect(CompanionCrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!CompanionCrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!CompanionCrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2])))
    }

    @Test func helloProofBindsKeyAndDevice() {
        let key = CompanionCrypto.generateSecret()
        let proof = CompanionCrypto.helloProof(key: key, deviceID: device)
        #expect(CompanionCrypto.verifyHelloProof(proof, key: key, deviceID: device))
        #expect(!CompanionCrypto.verifyHelloProof(proof, key: key, deviceID: UUID()))
        #expect(!CompanionCrypto.verifyHelloProof(proof, key: CompanionCrypto.generateSecret(), deviceID: device))
    }

    @Test func stateMachinesPairOverQR() {
        let secret = CompanionCrypto.generateSecret()
        let macID = UUID()
        var client = CompanionPairingClient(bootstrap: .qr(secret: secret), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(
            candidates: [.code("87654321"), .qr(secret: secret)], macID: macID, macName: "Mac"
        )

        guard case .send(let key) = responder.receive(client.begin()) else { return fail("no key reply") }
        guard case .confirm(_, let reveal) = client.receive(key) else { return fail("no confirmation") }
        guard case .finished(let paired, let name, let macSide, let reply) = responder.receive(reveal) else {
            return fail("Mac should not need approval for a QR code")
        }
        #expect(paired == device)
        #expect(name == "Phone")
        guard case .finished(let seenMac, let macName, let phoneSide) = client.receive(reply) else {
            return fail("phone did not finish")
        }
        #expect(seenMac == macID)
        #expect(macName == "Mac")
        #expect(macSide == phoneSide)
    }

    @Test func typedCodePairingNeedsApprovalAndBothSidesShowTheSameCheckCode() {
        var client = CompanionPairingClient(bootstrap: .code("1234 5678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(let phoneCode, let reveal) = client.receive(key),
              case .approval(let macCode, let paired, let name) = responder.receive(reveal)
        else { return fail("pairing did not reach approval") }
        #expect(phoneCode == macCode)
        #expect(phoneCode.count == 6)
        #expect(paired == device)
        #expect(name == "Phone")
        guard case .finished(_, _, let macKey, let reply) = responder.approve(),
              case .finished(_, _, let phoneKey) = client.receive(reply)
        else { return fail("approval did not finish pairing") }
        #expect(macKey == phoneKey)
    }

    @Test func approvalIsOnlyPossibleOnce() {
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .rejected = responder.approve() else { return fail("approved with nothing pending") }
    }

    @Test func aManInTheMiddleGetsDifferentCheckCodes() {
        let code = CompanionBootstrap.code("12345678")
        var phone = CompanionPairingClient(bootstrap: code, deviceID: device, deviceName: "Phone")
        var mac = CompanionPairingResponder(candidates: [code], macID: UUID(), macName: "Mac")
        var attackerFacingPhone = CompanionPairingResponder(candidates: [code], macID: UUID(), macName: "Mac")
        var attackerFacingMac = CompanionPairingClient(bootstrap: code, deviceID: device, deviceName: "Phone")

        guard case .send(let fakeKey) = attackerFacingPhone.receive(phone.begin()),
              case .confirm(let phoneCode, let phoneReveal) = phone.receive(fakeKey),
              case .approval = attackerFacingPhone.receive(phoneReveal),
              case .send(let realKey) = mac.receive(attackerFacingMac.begin()),
              case .confirm(_, let attackerReveal) = attackerFacingMac.receive(realKey),
              case .approval(let macCode, _, _) = mac.receive(attackerReveal)
        else { return fail("relay did not run") }
        #expect(phoneCode != macCode)
    }

    @Test func aMismatchedCommitmentIsRejected() {
        let code = CompanionBootstrap.code("12345678")
        var phone = CompanionPairingClient(bootstrap: code, deviceID: device, deviceName: "Phone")
        var mac = CompanionPairingResponder(candidates: [code], macID: UUID(), macName: "Mac")
        guard case .send(let key) = mac.receive(phone.begin()),
              case .confirm(_, .pairReveal(let publicKey, _, let confirmation)) = phone.receive(key)
        else { return fail("exchange did not start") }
        let swapped = CompanionMessage.pairReveal(publicKey: publicKey, nonce: Data(repeating: 1, count: 32), confirmation: confirmation)
        guard case .rejected = mac.receive(swapped) else { return fail("Mac accepted a different nonce") }
    }

    @Test func aSubstitutedKeyAfterCommitmentIsRejected() {
        let code = CompanionBootstrap.code("12345678")
        var phone = CompanionPairingClient(bootstrap: code, deviceID: device, deviceName: "Phone")
        var mac = CompanionPairingResponder(candidates: [code], macID: UUID(), macName: "Mac")
        guard case .send(let key) = mac.receive(phone.begin()),
              case .confirm(_, .pairReveal(_, let nonce, let confirmation)) = phone.receive(key)
        else { return fail("exchange did not start") }
        let other = CompanionMessage.pairReveal(publicKey: CompanionPairingKeys().publicKey, nonce: nonce, confirmation: confirmation)
        guard case .rejected = mac.receive(other) else { return fail("Mac accepted a different key") }
    }

    @Test func aWrongCodeIsRejectedByTheMac() {
        var client = CompanionPairingClient(bootstrap: .code("11111111"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("22222222")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(_, let reveal) = client.receive(key)
        else { return fail("exchange did not start") }
        guard case .rejected = responder.receive(reveal) else { return fail("Mac accepted a wrong code") }
    }

    @Test func aFakeMacCannotFinishThePhone() {
        var client = CompanionPairingClient(bootstrap: .code("11111111"), deviceID: device, deviceName: "Phone")
        var fake = CompanionPairingResponder(candidates: [.code("22222222")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = fake.receive(client.begin()),
              case .confirm = client.receive(key)
        else { return fail("exchange did not start") }
        let forged = CompanionMessage.pairDone(confirmation: Data(repeating: 9, count: 32))
        guard case .failed = client.receive(forged) else { return fail("phone accepted a forged confirmation") }
    }

    @Test func messagesOutOfOrderFail() {
        var responder = CompanionPairingResponder(candidates: [.code("11111111")], macID: UUID(), macName: "Mac")
        guard case .rejected = responder.receive(.pairDone(confirmation: Data())) else {
            return fail("accepted pairDone before pairBegin")
        }
        var client = CompanionPairingClient(bootstrap: .code("11111111"), deviceID: device, deviceName: "Phone")
        _ = client.begin()
        guard case .failed = client.receive(.ping) else { return fail("phone accepted ping") }
    }
}
