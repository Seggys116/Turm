import Foundation
import Testing
@testable import Turm

struct ThirdPartyNoticesTests {
    private struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { var version: String? }
            var identity: String
            var state: State
        }
        var pins: [Pin]
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func pins() throws -> [Resolved.Pin] {
        let url = Self.root.appendingPathComponent("Turm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        return try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url)).pins
    }

    private func headers() throws -> Set<String> {
        let url = Self.root.appendingPathComponent("SharedResources/ThirdPartyNotices.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    @Test func everyResolvedPackageHasANoticeAtItsPinnedVersion() throws {
        let headers = try headers()
        let pins = try pins()
        #expect(!pins.isEmpty)
        for pin in pins {
            let version = try #require(pin.state.version, "\(pin.identity) is not pinned to a release")
            #expect(headers.contains("\(pin.identity) \(version)"), "ThirdPartyNotices.txt has no \(pin.identity) \(version) section")
        }
    }

    @Test func eachNoticeSectionCarriesLicenceText() throws {
        let url = Self.root.appendingPathComponent("SharedResources/ThirdPartyNotices.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let sections = text.components(separatedBy: String(repeating: "=", count: 80) + "\n").dropFirst()
        let pinCount = try pins().count
        #expect(sections.count >= 2 * pinCount)
        for body in sections.enumerated().filter({ $0.offset % 2 == 1 }).map(\.element) {
            #expect(body.contains("Permission is hereby granted") || body.contains("Apache License") || body.contains("Redistribution and use"))
        }
    }
}
