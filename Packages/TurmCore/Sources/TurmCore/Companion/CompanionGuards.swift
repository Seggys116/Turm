import Foundation

public nonisolated enum CompanionTerminalSize {
    public static let columns = 2...500
    public static let rows = 2...300

    public static func contains(cols: Int, rows: Int) -> Bool {
        Self.columns.contains(cols) && Self.rows.contains(rows)
    }

    public static func clamped(cols: Int, rows: Int) -> (cols: Int, rows: Int) {
        (cols.clamped(to: Self.columns), rows.clamped(to: Self.rows))
    }
}

private extension Int {
    nonisolated func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

public nonisolated enum CompanionPeerAddress {
    public static func key(_ host: String) -> String {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return host }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return bytes[12..<16].map { String($0) }.joined(separator: ".")
        }
        let groups = stride(from: 0, to: 8, by: 2).map { String(Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]), radix: 16) }
        return groups.joined(separator: ":") + "::/64"
    }
}

public nonisolated enum CompanionUploads {
    public enum Refusal: Error, Equatable {
        case disabled
        case noFolder

        public var text: String {
            switch self {
            case .disabled: "File uploads are turned off. Turn on Allow file uploads in Turm's Remote Access settings on the Mac."
            case .noFolder: "No upload folder is chosen. Choose one in Turm's Remote Access settings on the Mac."
            }
        }
    }

    public static func roots(uploadsEnabled: Bool, uploadRoot: String, shellDirectory: String?) -> Result<[String], Refusal> {
        guard uploadsEnabled else { return .failure(.disabled) }
        guard !uploadRoot.isEmpty else { return .failure(.noFolder) }
        guard let shellDirectory, !shellDirectory.isEmpty else { return .success([uploadRoot]) }
        return .success([uploadRoot, shellDirectory])
    }
}
