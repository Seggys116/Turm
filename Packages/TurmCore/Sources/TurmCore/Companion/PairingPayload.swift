import Foundation

public nonisolated struct PairingPayload: Codable, Sendable, Equatable {
    public static let scheme = "turm-pair"

    public var macID: UUID
    public var macName: String
    public var hosts: [String]
    public var port: UInt16
    public var secret: Data
    public var expires: Date

    public init(macID: UUID, macName: String, hosts: [String], port: UInt16, secret: Data, expires: Date) {
        self.macID = macID
        self.macName = macName
        self.hosts = hosts
        self.port = port
        self.secret = secret
        self.expires = expires
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        date >= expires
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        var items = [
            URLQueryItem(name: "m", value: macID.uuidString),
            URLQueryItem(name: "n", value: macName),
        ]
        items += hosts.map { URLQueryItem(name: "h", value: $0) }
        items += [
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "s", value: Self.base64URL(secret)),
            URLQueryItem(name: "e", value: String(Int(expires.timeIntervalSince1970))),
        ]
        components.queryItems = items
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let macID = value("m").flatMap({ UUID(uuidString: $0) }),
              let name = value("n"),
              let port = value("p").flatMap({ UInt16($0) }), port > 0,
              let secret = value("s").flatMap({ Self.data(fromBase64URL: $0) }), secret.count == CompanionCrypto.secretLength,
              let expires = value("e").flatMap({ TimeInterval($0) })
        else { return nil }
        let hosts = items.filter { $0.name == "h" }.compactMap(\.value).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        self.init(macID: macID, macName: name, hosts: hosts, port: port, secret: secret, expires: Date(timeIntervalSince1970: expires))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(fromBase64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
