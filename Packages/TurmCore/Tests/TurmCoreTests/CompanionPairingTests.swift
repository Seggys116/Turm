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
        guard case .awaitConfirm(_, let reply) = responder.approve(),
              case .waiting = client.receive(reply),
              case .finishing(let confirm, _, _, let phoneKey) = client.approve(),
              case .confirmed(_, _, let macKey) = responder.receive(confirm)
        else { return fail("approval did not finish pairing") }
        #expect(macKey == phoneKey)
    }

    private func reachApproval(
        client: inout CompanionPairingClient, responder: inout CompanionPairingResponder, begin: CompanionMessage? = nil
    ) -> Bool {
        guard case .send(let key) = responder.receive(begin ?? client.begin()),
              case .confirm(_, let reveal) = client.receive(key),
              case .approval = responder.receive(reveal)
        else { return false }
        return true
    }

    private func oldBegin(_ message: CompanionMessage) -> CompanionMessage {
        guard case .pairBegin(let id, let name, let commitment, _) = message else { return message }
        return .pairBegin(deviceID: id, name: name, commitment: commitment)
    }

    @Test func theMacStoresNothingUntilTheClientConfirms() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard reachApproval(client: &client, responder: &responder) else { return fail("did not reach approval") }
        guard case .awaitConfirm = responder.approve() else { return fail("approve finished before the client confirmed") }
        guard case .rejected = responder.receive(.ping) else { return fail("Mac accepted a message other than the confirmation") }
    }

    @Test func aClientThatRejectsAfterPairDoneLeavesNothingToStore() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard reachApproval(client: &client, responder: &responder),
              case .awaitConfirm(_, let reply) = responder.approve(),
              case .waiting = client.receive(reply)
        else { return fail("pairing did not reach the confirmation wait") }
        guard case .failed = client.reject() else { return fail("reject did not fail the pairing") }
        guard case .failed = client.approve() else { return fail("client confirmed after rejecting") }
        guard case .rejected = responder.receive(.error(code: CompanionErrorCode.failed, text: "closed")) else {
            return fail("Mac produced a stored device without a confirmation")
        }
    }

    @Test func aConfirmBeforeApprovalIsRefused() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard reachApproval(client: &client, responder: &responder) else { return fail("did not reach approval") }
        guard case .rejected = responder.receive(.pairConfirm) else { return fail("Mac stored a device the user had not approved") }
    }

    @Test func aClientThatApprovedEarlyConfirmsWhenPairDoneArrives() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard reachApproval(client: &client, responder: &responder),
              case .waiting = client.approve(),
              case .awaitConfirm(_, let reply) = responder.approve(),
              case .finishing(let confirm, _, _, let phoneKey) = client.receive(reply),
              case .confirmed(_, _, let macKey) = responder.receive(confirm)
        else { return fail("early approval did not complete") }
        #expect(confirm == .pairConfirm)
        #expect(macKey == phoneKey)
    }

    @Test func aNewMacStoresOnApprovalForAnOldClient() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(oldBegin(client.begin())) else { return fail("no key reply") }
        guard case .pairKey(_, _, _, let echo) = key else { return fail("no key") }
        #expect(echo == nil)
        guard case .confirm(_, let reveal) = client.receive(key),
              case .approval = responder.receive(reveal),
              case .finished(_, _, let macKey, let reply) = responder.approve()
        else { return fail("Mac did not store on approval") }
        guard case .waiting = client.receive(reply),
              case .finished(_, _, let phoneKey) = client.approve()
        else { return fail("old-style client did not finish") }
        #expect(macKey == phoneKey)
    }

    @Test func aNewClientWorksWithAnOldMac() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        let begin = client.begin()
        guard case .pairBegin(_, _, _, let confirms) = begin else { return fail("no begin") }
        #expect(confirms == true)
        guard case .send(.pairKey(let macID, let macName, let publicKey, let echo)) = responder.receive(oldBegin(begin)) else {
            return fail("no key reply")
        }
        #expect(echo == nil)
        let oldKey = CompanionMessage.pairKey(macID: macID, macName: macName, publicKey: publicKey)
        guard case .confirm(_, let reveal) = client.receive(oldKey),
              case .approval = responder.receive(reveal),
              case .finished(_, _, _, let reply) = responder.approve(),
              case .waiting = client.receive(reply)
        else { return fail("exchange with an old Mac did not run") }
        guard case .finished = client.approve() else { return fail("client waited for a confirmation the Mac never asked for") }
    }

    @Test func qrPairingNeverDeclaresOrEchoesConfirmation() {
        let secret = CompanionCrypto.generateSecret()
        var client = CompanionPairingClient(bootstrap: .qr(secret: secret), deviceID: device, deviceName: "Phone")
        guard case .pairBegin(_, _, _, let confirms) = client.begin() else { return fail("no begin") }
        #expect(confirms == nil)
        var responder = CompanionPairingResponder(candidates: [.qr(secret: secret)], macID: UUID(), macName: "Mac")
        let claimed = CompanionMessage.pairBegin(deviceID: device, name: "Phone", commitment: Data(repeating: 1, count: 32), confirms: true)
        guard case .send(.pairKey(_, _, _, let echo)) = responder.receive(claimed) else { return fail("no key reply") }
        #expect(echo == nil)
    }

    @Test func theClientHoldsTheKeyUntilTheUserApproves() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(_, let reveal) = client.receive(key),
              case .approval = responder.receive(reveal),
              case .awaitConfirm(_, let reply) = responder.approve()
        else { return fail("pairing did not reach the Mac's approval") }
        guard case .waiting = client.receive(reply) else { return fail("client released the key before approval") }
        guard case .finishing = client.approve() else { return fail("approval did not release the key") }
    }

    @Test func approvingBeforeTheMacFinishesStillWaitsForTheMac() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(_, let reveal) = client.receive(key),
              case .approval = responder.receive(reveal)
        else { return fail("pairing did not reach the Mac's approval") }
        guard case .waiting = client.approve() else { return fail("approval released a key the Mac had not sent") }
        guard case .awaitConfirm(_, let reply) = responder.approve(),
              case .finishing(let confirm, _, _, let phoneKey) = client.receive(reply),
              case .confirmed(_, _, let macKey) = responder.receive(confirm)
        else { return fail("pairing did not finish") }
        #expect(macKey == phoneKey)
    }

    @Test func theClientKeepsTheKeyOnlyOnceTheMacAcknowledgesStoringIt() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(_, let reveal) = client.receive(key),
              case .approval = responder.receive(reveal),
              case .awaitConfirm(_, let reply) = responder.approve(),
              case .waiting = client.receive(reply),
              case .finishing(_, _, _, let phoneKey) = client.approve()
        else { return fail("pairing did not reach the confirmation") }
        guard case .finished(_, _, let kept) = client.receive(.pairConfirm) else { return fail("the acknowledgement did not finish pairing") }
        #expect(kept == phoneKey)
    }

    @Test func aMacErrorAfterTheConfirmationStopsThePhoneKeepingTheKey() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(_, let reveal) = client.receive(key),
              case .approval = responder.receive(reveal),
              case .awaitConfirm(_, let reply) = responder.approve(),
              case .waiting = client.receive(reply),
              case .finishing = client.approve()
        else { return fail("pairing did not reach the confirmation") }
        guard case .failed = client.receive(.error(code: "pairing", text: "Pairing expired")) else { return fail("the phone kept a key the Mac refused") }
    }

    @Test func aRejectedCodeYieldsNoKey() {
        var client = CompanionPairingClient(bootstrap: .code("12345678"), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.code("12345678")], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(_, let reveal) = client.receive(key),
              case .approval = responder.receive(reveal),
              case .awaitConfirm(_, let reply) = responder.approve()
        else { return fail("pairing did not reach the Mac's approval") }
        guard case .failed = client.reject() else { return fail("reject did not fail the pairing") }
        guard case .failed = client.receive(reply) else { return fail("client accepted a key after rejecting") }
        guard case .failed = client.approve() else { return fail("client approved after rejecting") }
    }

    @Test func anImpostorThatKnowsTheCodeCannotStoreAKeyWithoutApproval() {
        let code = CompanionBootstrap.code("12345678")
        var phone = CompanionPairingClient(bootstrap: code, deviceID: device, deviceName: "Phone")
        var impostor = CompanionPairingResponder(candidates: [code], macID: UUID(), macName: "Mac")
        guard case .send(let fakeKey) = impostor.receive(phone.begin()),
              case .confirm(_, let reveal) = phone.receive(fakeKey),
              case .approval = impostor.receive(reveal),
              case .awaitConfirm(_, let done) = impostor.approve()
        else { return fail("impostor did not complete its side") }
        guard case .waiting = phone.receive(done) else { return fail("phone released the impostor's key") }
        guard case .failed = phone.reject() else { return fail("reject did not fail the pairing") }
    }

    @Test func qrPairingNeedsNoConfirmationOnTheStartingSide() {
        let secret = CompanionCrypto.generateSecret()
        var client = CompanionPairingClient(bootstrap: .qr(secret: secret), deviceID: device, deviceName: "Phone")
        var responder = CompanionPairingResponder(candidates: [.qr(secret: secret)], macID: UUID(), macName: "Mac")
        guard case .send(let key) = responder.receive(client.begin()),
              case .confirm(_, let reveal) = client.receive(key),
              case .finished(_, _, _, let reply) = responder.receive(reveal)
        else { return fail("QR pairing did not reach the Mac's finish") }
        guard case .finished = client.receive(reply) else { return fail("QR pairing waited for a confirmation") }
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
