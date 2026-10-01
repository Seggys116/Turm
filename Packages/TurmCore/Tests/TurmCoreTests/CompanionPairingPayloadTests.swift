import Foundation
import Testing
@testable import TurmCore

struct CompanionPairingPayloadTests {
    private func payload(hosts: [String] = ["192.168.1.20", "100.101.102.103", "studio.local", "fd7a::1"]) -> PairingPayload {
        PairingPayload(
            macID: UUID(), macName: "Zak's Mac Studio & more", hosts: hosts, port: 7337,
            secret: CompanionCrypto.generateSecret(), expires: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func roundTripsThroughAURL() throws {
        let original = payload()
        let url = try #require(original.url)
        #expect(url.scheme == "turm-pair")
        #expect(PairingPayload(url: url) == original)
    }

    @Test func roundTripsThroughItsStringForm() throws {
        let original = payload()
        let text = try #require(original.url?.absoluteString)
        #expect(PairingPayload(url: try #require(URL(string: text))) == original)
    }

    @Test func staysCompactEnoughForAQRCode() throws {
        let text = try #require(payload().url?.absoluteString)
        #expect(text.count < 300)
    }

    @Test func rejectsForeignSchemes() throws {
        let url = try #require(payload().url)
        let swapped = try #require(URL(string: url.absoluteString.replacingOccurrences(of: "turm-pair", with: "https")))
        #expect(PairingPayload(url: swapped) == nil)
    }

    @Test func rejectsAShortSecret() throws {
        var short = payload()
        short.secret = Data(count: 16)
        let url = try #require(short.url)
        #expect(PairingPayload(url: url) == nil)
    }

    @Test func rejectsNoHosts() throws {
        let url = try #require(payload(hosts: []).url)
        #expect(PairingPayload(url: url) == nil)
    }

    @Test func rejectsMissingFields() throws {
        #expect(PairingPayload(url: try #require(URL(string: "turm-pair://pair?v=1"))) == nil)
    }

    @Test func expiry() {
        let value = payload()
        #expect(!value.isExpired(at: value.expires.addingTimeInterval(-1)))
        #expect(value.isExpired(at: value.expires))
    }
}
