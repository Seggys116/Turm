import SwiftTerm
import TurmCore
import UIKit

final class TurmTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var wheel = WheelScroll()
    private var wheelInstalled = false

    var kittyFlags: Int { getTerminal().keyboardEnhancementFlags.rawValue }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !wheelInstalled else { return }
        wheelInstalled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(wheelPanned(_:)))
        pan.allowedScrollTypesMask = .all
        pan.allowedTouchTypes = []
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func wheelPanned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { wheel.reset() }
        guard pan.state == .began || pan.state == .changed else { return }
        let translation = pan.translation(in: self).y
        pan.setTranslation(.zero, in: self)
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate, terminal.rows > 0, terminal.cols > 0 else { return }
        let size = getOptimalFrameSize()
        let cellHeight = Double(size.height) / Double(terminal.rows)
        let lines = wheel.lines(translation: Double(translation), cellHeight: cellHeight)
        guard lines != 0 else { return }
        if terminal.mouseMode != .off {
            let point = pan.location(in: self)
            let column = min(max(Int((point.x / (size.width / CGFloat(terminal.cols))).rounded(.down)), 0), terminal.cols - 1)
            let row = min(max(Int(((point.y - contentOffset.y) / (size.height / CGFloat(terminal.rows))).rounded(.down)), 0), terminal.rows - 1)
            let button = WheelScroll.wheelButton(lines: lines)
            for _ in 0..<abs(lines) {
                terminal.sendEvent(buttonFlags: button, x: column, y: row)
            }
        } else if terminal.alternateScrollMode {
            send(data: WheelScroll.arrowKeys(lines: lines, applicationCursor: terminal.applicationCursor)[...])
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var passed = Set<UIPress>()
        for press in presses {
            if let key = press.key, let bytes = HardwareNewline.bytes(for: key, kittyFlags: kittyFlags) {
                send(data: bytes[...])
            } else {
                passed.insert(press)
            }
        }
        if !passed.isEmpty { super.pressesBegan(passed, with: event) }
    }
}
