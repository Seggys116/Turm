import Observation
import QuartzCore
import SwiftUI
import UIKit

@Observable
final class KeyboardOverlap {
    static let shared = KeyboardOverlap()

    private(set) var height: CGFloat = 0

    @ObservationIgnored private weak var bar: UIView?
    @ObservationIgnored private var link: CADisplayLink?

    func track(_ bar: UIView) {
        self.bar = bar
        if link == nil {
            let link = CADisplayLink(target: LinkTarget { [weak self] in self?.measure() }, selector: #selector(LinkTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        measure()
    }

    func stopTracking(_ bar: UIView) {
        guard self.bar === bar else { return }
        self.bar = nil
        link?.invalidate()
        link = nil
        update(0)
    }

    private func measure() {
        guard let bar, let barWindow = bar.window, let appWindow = barWindow.windowScene?.keyWindow else { return }
        let windowLayer = barWindow.layer.presentation() ?? barWindow.layer
        let barLayer = windowLayer === barWindow.layer ? bar.layer : bar.layer.presentation() ?? bar.layer
        let frame = appWindow.convert(barLayer.convert(barLayer.bounds, to: windowLayer), from: barWindow)
        let docked = frame.width >= appWindow.bounds.width * 0.9
        update(docked ? max(0, appWindow.bounds.maxY - frame.minY) : 0)
    }

    private func update(_ value: CGFloat) {
        guard abs(value - height) >= 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { height = value }
    }
}

private final class LinkTarget: NSObject {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func tick() {
        action()
    }
}
