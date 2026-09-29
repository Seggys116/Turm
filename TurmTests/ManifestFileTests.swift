import Foundation
import Testing
@testable import Turm

struct ManifestFileTests {
    private func scratch() throws -> String {
        let path = NSTemporaryDirectory() + "turm-manifest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func plainFileIsAccepted() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "{}".write(toFile: dir + "/Turm.json", atomically: true, encoding: .utf8)
        #expect(ProjectManifest.resolvedFile(in: dir) != nil)
    }

    @Test(arguments: ["turm.json", "TURM.json", "Turm.JSON", "tUrM.JsOn"])
    func fileNameIgnoresCase(name: String) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "{}".write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        let resolved = try #require(ProjectManifest.resolvedFile(in: dir))
        #expect((resolved as NSString).lastPathComponent == name)
    }

    @Test func otherJSONIsIgnored() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "{}".write(toFile: dir + "/turm.jsonc", atomically: true, encoding: .utf8)
        #expect(ProjectManifest.resolvedFile(in: dir) == nil)
    }

    @Test func symlinkToPlainFileResolves() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "{}".write(toFile: dir + "/real.json", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/Turm.json", withDestinationPath: dir + "/real.json")
        let resolved = try #require(ProjectManifest.resolvedFile(in: dir))
        #expect(resolved.hasSuffix("real.json"))
    }

    @Test func directoryIsRejected() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/Turm.json", withIntermediateDirectories: false)
        #expect(ProjectManifest.resolvedFile(in: dir) == nil)
    }

    @Test func deviceSymlinkIsRejected() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir + "/Turm.json", withDestinationPath: "/dev/zero")
        #expect(ProjectManifest.resolvedFile(in: dir) == nil)
    }

    @Test func oversizeFileIsRejected() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let big = String(repeating: "a", count: ProjectManifest.maxBytes + 1)
        try big.write(toFile: dir + "/Turm.json", atomically: true, encoding: .utf8)
        #expect(ProjectManifest.resolvedFile(in: dir) == nil)
    }

    @Test func missingFileIsRejected() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(ProjectManifest.resolvedFile(in: dir) == nil)
    }
}
