import Foundation

enum ResponseFilter {
    private static let versionReply: [UInt8] = [0x1B, 0x50, 0x3E, 0x7C] + Array(TerminalIdentity.xtVersion.utf8) + [0x1B, 0x5C]

    // SwiftTerm answers DECRQM for the alternate screen modes as unrecognised, though it switches screens for all three
    private static let screenModes = [47, 1047, 1048, 1049]

    static func rewrite(_ bytes: [UInt8], colorSchemeReporting: Bool = false, alternateScreen: Bool = false) -> [UInt8] {
        if bytes == Array("\u{1B}[?2031;0$y".utf8) {
            return Array("\u{1B}[?2031;\(colorSchemeReporting ? 1 : 2)$y".utf8)
        }
        for mode in screenModes where bytes.starts(with: Array("\u{1B}[?\(mode);".utf8)) && bytes.last == 0x79 {
            let set = alternateScreen && mode != 1048
            return Array("\u{1B}[?\(mode);\(set ? 1 : 2)$y".utf8)
        }
        let prefix: [UInt8] = [0x1B, 0x50, 0x3E, 0x7C]
        let suffix: [UInt8] = [0x1B, 0x5C]
        if bytes.starts(with: prefix), bytes.suffix(2).elementsEqual(suffix) {
            return versionReply
        }
        return bytes
    }
}
