import Foundation

public struct CollapsedSidebarMode: Equatable, Sendable {
    public static let topBarKey = "turm.collapsedTopBar"
    public static let popOutKey = "turm.collapsedPopOut"

    public let topBar: Bool
    public let popOut: Bool

    public init(topBar: Bool = true, popOut: Bool = true) {
        self.topBar = topBar || !popOut
        self.popOut = popOut
    }

    public init(defaults: UserDefaults) {
        self.init(
            topBar: defaults.object(forKey: Self.topBarKey) as? Bool ?? true,
            popOut: defaults.object(forKey: Self.popOutKey) as? Bool ?? true
        )
    }

    public var canDisableTopBar: Bool { popOut }

    public var canDisablePopOut: Bool { topBar }
}
