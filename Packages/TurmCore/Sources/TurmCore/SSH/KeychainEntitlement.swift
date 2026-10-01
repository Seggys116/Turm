import Foundation
import Security

// asking the data-protection keychain without the entitlement can stall for a long time on macOS, so read the entitlement instead
nonisolated enum KeychainEntitlement {
    static let groups: [String]? = load()

    static var allowsDataProtection: Bool {
        #if os(macOS)
        groups?.isEmpty == false
        #else
        true
        #endif
    }

    static func group(endingWith suffix: String) -> String? {
        groups?.first { $0.hasSuffix("." + suffix) }
    }

    private static func load() -> [String]? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        else { return nil }
        return value as? [String]
        #else
        return nil
        #endif
    }
}
