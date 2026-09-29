import Foundation

enum TerminalIdentity {
    static let program = "ghostty"
    static let version = "1.1.3"
    static let xtVersion = "ghostty \(version)"

    static let environment: [String] = [
        "TERM_PROGRAM=\(program)",
        "TERM_PROGRAM_VERSION=\(version)",
    ]
}
