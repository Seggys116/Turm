import CryptoKit
import Foundation
import Observation

@Observable
final class SSHKnownHosts {
    static let shared = SSHKnownHosts(fileURL: defaultURL)

    private(set) var entries: [String: String]
    @ObservationIgnored private let fileURL: URL

    private static var defaultURL: URL {
        let base = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "known_hosts.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        entries = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func identifier(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    nonisolated static func fingerprint(ofKeyLine line: String) -> String? {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func algorithm(ofKeyLine line: String) -> String {
        line.split(separator: " ").first.map(String.init) ?? ""
    }

    func key(host: String, port: Int) -> String? {
        entries[Self.identifier(host: host, port: port)]
    }

    func trust(_ keyLine: String, host: String, port: Int) {
        let fields = keyLine.split(separator: " ")
        guard fields.count >= 2 else { return }
        entries[Self.identifier(host: host, port: port)] = "\(fields[0]) \(fields[1])"
        persist()
    }

    func forget(host: String, port: Int) {
        entries[Self.identifier(host: host, port: port)] = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
