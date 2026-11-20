import AppKit
import Foundation
import Observation

/// The app-wide terminal text size. Views that read `size` while building their body refresh when it changes.
@Observable
final class TerminalZoom {
    static let shared = TerminalZoom()
    static let key = "turm.terminalFontSize"
    static let defaultSize: CGFloat = 13
    static let range: ClosedRange<CGFloat> = 9...32
    static let step: CGFloat = 1

    static func clamped(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return defaultSize }
        return min(max(size.rounded(), range.lowerBound), range.upperBound)
    }

    static func zoomedIn(_ size: CGFloat) -> CGFloat { clamped(size + step) }

    static func zoomedOut(_ size: CGFloat) -> CGFloat { clamped(size - step) }

    static func stored(in defaults: UserDefaults) -> CGFloat {
        guard let value = defaults.object(forKey: key) as? Double else { return defaultSize }
        return clamped(CGFloat(value))
    }

    private(set) var size: CGFloat
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        size = Self.stored(in: defaults)
    }

    /// Bumped by every zoom command, so the window can show the new size for a moment.
    private(set) var announcement = 0

    /// The size as a share of the default, which is what the zoom indicator shows.
    var percent: Int { Int((size / Self.defaultSize * 100).rounded()) }

    var canZoomIn: Bool { size < Self.range.upperBound }
    var canZoomOut: Bool { size > Self.range.lowerBound }
    var isDefault: Bool { size == Self.defaultSize }

    func zoomIn() { set(Self.zoomedIn(size)) }

    func zoomOut() { set(Self.zoomedOut(size)) }

    func reset() { set(Self.defaultSize) }

    private func set(_ next: CGFloat) {
        announcement += 1
        guard next != size else { return }
        size = next
        if next == Self.defaultSize {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(Double(next), forKey: Self.key)
        }
    }
}
