import Foundation
import Testing
@testable import TurmCore

struct CompanionVersionTests {
    private let device = UUID(uuidString: "6F1C2B9E-6A55-4D7B-9C1E-2D3F4A5B6C7D")!

    private func version(_ kinds: Set<String>, essential: Set<String> = [], app: String = "1.0.0") -> CompanionVersion {
        CompanionVersion(app: app, kinds: kinds, essential: essential)
    }

    private func decode(_ json: String) throws -> CompanionMessage {
        try JSONDecoder().decode(CompanionMessage.self, from: Data(json.utf8))
    }

    // these are the bytes released builds put on the wire; if one stops decoding, old and new apps can no longer meet
    @Test func frozenHandshakeFramesStillDecode() throws {
        #expect(try decode(#"{"hello":{"version":{"app":"1.4.0","kinds":["hello","ping"],"essential":["hello"]},"deviceID":"6F1C2B9E-6A55-4D7B-9C1E-2D3F4A5B6C7D","name":"Phone","proof":"AQID"}}"#)
            == .hello(version: version(["hello", "ping"], essential: ["hello"], app: "1.4.0"), deviceID: device, name: "Phone", proof: Data([1, 2, 3])))
        #expect(try decode(#"{"welcome":{"version":{"app":"1.4.0","kinds":["welcome"],"essential":[]},"macName":"Studio"}}"#)
            == .welcome(version: version(["welcome"], app: "1.4.0"), macName: "Studio"))
        #expect(try decode(#"{"incompatible":{"version":{"app":"1.4.0","kinds":["hello"],"essential":["hello"]}}}"#)
            == .incompatible(version: version(["hello"], essential: ["hello"], app: "1.4.0")))
        #expect(try decode(#"{"addresses":{"hosts":["192.168.1.5","mac.local"],"port":7337}}"#)
            == .addresses(hosts: ["192.168.1.5", "mac.local"], port: 7337))
        #expect(try decode(#"{"error":{"code":"unauthorized","text":"No"}}"#) == .error(code: "unauthorized", text: "No"))
        #expect(try decode(#"{"ping":{}}"#) == .ping)
    }

    @Test func handshakeFramesKeepTheirFieldNames() throws {
        let hello = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CompanionMessage.hello(version: .current, deviceID: device, name: "P", proof: Data()))
        ) as? [String: [String: Any]]
        #expect(Set(hello?["hello"]?.keys ?? [:].keys) == ["version", "deviceID", "name", "proof"])
        let fields = (hello?["hello"]?["version"] as? [String: Any]).map { Set($0.keys) }
        #expect(fields == ["app", "kinds", "essential"])
    }

    @Test func aHelloFromALaterBuildWithExtraFieldsStillDecodes() throws {
        let json = #"{"hello":{"version":{"app":"9.0","kinds":["hello"],"essential":[],"region":"eu"},"deviceID":"6F1C2B9E-6A55-4D7B-9C1E-2D3F4A5B6C7D","name":"P","proof":"","colour":"red"}}"#
        guard case .hello(let decoded, _, _, _) = try decode(json) else {
            Issue.record("not a hello")
            return
        }
        #expect(decoded == version(["hello"], app: "9.0"))
    }

    @Test func aVersionWithMissingFieldsDecodesAsEmpty() throws {
        let decoded = try JSONDecoder().decode(CompanionVersion.self, from: Data("{}".utf8))
        #expect(decoded == version([], app: ""))
    }

    @Test func currentAdvertisesEveryKindAndOnlyEssentialOnesAsEssential() {
        let current = CompanionVersion.current
        #expect(current.kinds == Set(CompanionMessage.Kind.allCases.map(\.rawValue)))
        #expect(current.essential.isSubset(of: current.kinds))
        #expect(current.essential.contains("hello") && current.essential.contains("welcome") && current.essential.contains("incompatible"))
        #expect(!current.essential.contains("addresses"))
        #expect(CompanionCompatibility.between(current, current) == .compatible(outdated: nil))
    }

    @Test func outdatedSideFollowsMissingKinds() {
        let base: Set<String> = ["hello", "welcome"]
        #expect(CompanionCompatibility.between(version(base), version(base.union(["x"]))) == .compatible(outdated: .local))
        #expect(CompanionCompatibility.between(version(base.union(["x"])), version(base)) == .compatible(outdated: .remote))
        #expect(CompanionCompatibility.between(version(base, essential: ["x"]), version(base.union(["y"]))) == .incompatible(outdated: .remote))
        #expect(CompanionCompatibility.between(version(base), version(base.union(["x"]), essential: ["x"])) == .incompatible(outdated: .local))
    }

    @Test func divergedBuildsFallBackToTheAppVersion() {
        let older = version(["hello", "a"], app: "1.9.0")
        let newer = version(["hello", "b"], app: "1.10.0")
        #expect(CompanionCompatibility.between(older, newer) == .compatible(outdated: .local))
        #expect(CompanionCompatibility.between(newer, older) == .compatible(outdated: .remote))
        #expect(CompanionCompatibility.between(older, version(["hello", "b"], app: "1.9.0")) == .compatible(outdated: nil))
    }

    // both apps run the same rule from opposite ends, so their verdicts must mirror each other exactly
    @Test func bothEndsAlwaysAgreeOnWhoMustUpdate() {
        var generator = SystemRandomNumberGenerator()
        let universe = ["hello", "welcome", "a", "b", "c", "d"]
        let apps = ["1.0.0", "1.2.0", "1.10.0"]
        func random() -> CompanionVersion {
            let kinds = Set(universe.filter { _ in Bool.random(using: &generator) })
            let essential = Set(universe.filter { _ in Int.random(in: 0..<4, using: &generator) == 0 })
            return version(kinds, essential: essential, app: apps.randomElement(using: &generator)!)
        }
        for _ in 0..<2000 {
            let mac = random()
            let phone = random()
            let atMac = CompanionHandshake.answer(hello: phone, local: mac, macName: "M")
            let atPhone = CompanionHandshake.read(atMac.reply, local: phone)
            let mirrored: CompanionCompatibility.Side? = atMac.compatibility.outdated.map { $0 == .local ? .remote : .local }
            #expect(atPhone?.remote == mac)
            #expect(atPhone?.compatibility.isCompatible == atMac.compatibility.isCompatible)
            #expect(atPhone?.compatibility.outdated == mirrored)
            if atMac.compatibility.isCompatible {
                #expect(phone.essential.isSubset(of: mac.kinds) && mac.essential.isSubset(of: phone.kinds))
            }
        }
    }

    @Test func aRefusalThePhoneCannotExplainStillCountsAsIncompatible() {
        let same = version(["hello"])
        #expect(CompanionHandshake.read(.incompatible(version: same), local: same)?.compatibility == .incompatible(outdated: nil))
        #expect(CompanionHandshake.read(.ping, local: same) == nil)
    }

    @Test func adviceNamesTheDeviceToUpdate() {
        let mac = version(["hello"], app: "1.3.0")
        let phone = version(["hello"], app: "1.5.0")
        #expect(CompanionCompatibility.compatible(outdated: nil).advice(local: phone, remote: mac, here: "this device", there: "Studio") == nil)
        #expect(CompanionCompatibility.incompatible(outdated: .remote).advice(local: phone, remote: mac, here: "this device", there: "Studio")
            == "Studio (Turm 1.3.0) is too old to connect to this device (Turm 1.5.0). Update Turm on Studio.")
        #expect(CompanionCompatibility.incompatible(outdated: .local).advice(local: phone, remote: mac, here: "this device", there: "Studio")
            == "this device (Turm 1.5.0) is too old to connect to Studio (Turm 1.3.0). Update Turm on this device.")
        #expect(CompanionCompatibility.compatible(outdated: .local).advice(local: version([], app: ""), remote: mac, here: "this Mac", there: "iPhone")?
            .hasPrefix("iPhone (Turm 1.3.0) runs a newer Turm. Update Turm on this Mac") == true)
    }

    @Test func aFrameOfAnUnknownKindIsSkippedAndTheStreamContinues() throws {
        var coder = CompanionFrameCoder()
        let body = Data(#"{"fromTheFuture":{"x":1}}"#.utf8)
        var length = UInt32(body.count).bigEndian
        var stream = Data(bytes: &length, count: 4)
        stream.append(body)
        stream.append(try CompanionFrameCoder.encode(.pong))
        #expect(try coder.feed(stream) == [.pong])
    }

    @Test func aKnownKindWithABrokenPayloadIsStillMalformed() throws {
        for json in [#"{"attach":{"id":"not-a-uuid"}}"#, #"{"a":1,"b":2}"#, #"[1]"#] {
            let body = Data(json.utf8)
            var length = UInt32(body.count).bigEndian
            var frame = Data(bytes: &length, count: 4)
            frame.append(body)
            #expect(throws: CompanionFrameError.malformed) {
                var coder = CompanionFrameCoder()
                _ = try coder.feed(frame)
            }
        }
    }

    @Test func learningAddressesDropsStalePrivateIPsAndLeadsWithTheWorkingOne() {
        var record = CompanionPeerRecord(
            id: UUID(), name: "Studio", key: Data(),
            hosts: ["192.168.1.20", "100.101.102.103", "studio.tail1234.ts.net", "203.0.113.9", "10.0.0.7"], port: 7337
        )
        let changed = record.learn(hosts: ["192.168.1.44", "100.101.102.103", "Studio.local"], port: 7337, via: "100.101.102.103")
        #expect(changed)
        #expect(record.hosts == ["100.101.102.103", "192.168.1.44", "Studio.local", "studio.tail1234.ts.net", "203.0.113.9"])
    }

    @Test func learningKeepsAnAddressThatWorkedEvenIfTheMacNoLongerListsIt() {
        var record = CompanionPeerRecord(id: UUID(), name: "Studio", key: Data(), hosts: ["192.168.1.20"], port: 7337)
        record.learn(hosts: ["192.168.1.44"], port: 8000, via: "192.168.1.20")
        #expect(record.hosts == ["192.168.1.20", "192.168.1.44"])
        #expect(record.port == 8000)
    }

    @Test func learningTheSameListChangesNothing() {
        var record = CompanionPeerRecord(id: UUID(), name: "Studio", key: Data(), hosts: ["192.168.1.44", "studio.local"], port: 7337)
        let changed = record.learn(hosts: ["192.168.1.44", "studio.local", "192.168.1.44"], port: 0, via: nil)
        #expect(!changed)
        #expect(record.hosts == ["192.168.1.44", "studio.local"])
        #expect(record.port == 7337)
    }

    @Test func privateAddressRanges() {
        for host in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.1", "100.64.0.1", "100.127.255.255", "169.254.1.1", "fd00::1", "fe80::1"] {
            #expect(CompanionPeerRecord.isPrivateAddress(host), "\(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "203.0.113.9", "2001:db8::1", "mac.local", "studio.ts.net"] {
            #expect(!CompanionPeerRecord.isPrivateAddress(host), "\(host)")
        }
    }
}
