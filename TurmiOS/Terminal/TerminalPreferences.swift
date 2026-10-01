import Foundation
import Observation

@Observable
final class TerminalPreferences {
    static let shared = TerminalPreferences()
    static let fontSizeKey = "turm.ios.fontSize"
    static let sizes: ClosedRange<Double> = 8...32
    static let defaultSize = 13.0

    @ObservationIgnored private let defaults: UserDefaults

    var fontSize: Double {
        didSet {
            let clamped = min(max(fontSize.rounded(), Self.sizes.lowerBound), Self.sizes.upperBound)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            defaults.set(fontSize, forKey: Self.fontSizeKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.fontSizeKey) as? Double ?? Self.defaultSize
        fontSize = min(max(stored, Self.sizes.lowerBound), Self.sizes.upperBound)
    }
}
