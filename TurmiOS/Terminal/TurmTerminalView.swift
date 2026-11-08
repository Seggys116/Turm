import SwiftTerm
import TurmCore
import UIKit

final class TurmTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var wheel = WheelScroll()
    private var wheelInstalled = false
    private let capture = TerminalCaptureField()

    var kittyFlags: Int { getTerminal().keyboardEnhancementFlags.rawValue }
    var onScroll: (() -> Void)?
    var onLayout: (() -> Void)?
    /// The background shown behind a transparent default background, reported in its place to color queries.
    var clearedBackground: UIColor?

    override var contentOffset: CGPoint {
        didSet { onScroll?() }
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        super.send(source: source, data: Self.report(data, background: clearedBackground))
    }

    private static let clearReport = Array("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\".utf8)

    static func report(_ data: ArraySlice<UInt8>, background: UIColor?) -> ArraySlice<UInt8> {
        guard let background, data.elementsEqual(clearReport) else { return data }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> String {
            String(format: "%04x", Int(UInt16(min(max(value, 0), 1) * 65535)))
        }
        return Array("\u{1B}]11;rgb:\(channel(red))/\(channel(green))/\(channel(blue))\u{1B}\\".utf8)[...]
    }

    /// A full-screen program covers the command field. iOS only delivers typing to a text field, so a hidden one
    /// stays first responder and this view reports that focus, which keeps taps working as mouse input.
    var capturesKeyboard = false {
        didSet {
            guard capturesKeyboard != oldValue else { return }
            if capturesKeyboard { installCapture() } else { removeCapture() }
        }
    }

    override var isFirstResponder: Bool {
        capturesKeyboard ? capture.isFirstResponder : super.isFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        guard capturesKeyboard else { return super.becomeFirstResponder() }
        placeCapture()
        return capture.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        guard capturesKeyboard else { return super.resignFirstResponder() }
        return capture.resignFirstResponder()
    }

    func syncCapturedKeyboardAppearance() {
        guard capturesKeyboard else { return }
        capture.keyboardAppearance = keyboardAppearance
        if capture.isFirstResponder { capture.reloadInputViews() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // focus before the tap ends, so the same touch both clicks the program's text box and keeps the keyboard
        if capturesKeyboard, window != nil {
            placeCapture()
            _ = capture.becomeFirstResponder()
        }
        super.touchesBegan(touches, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if !wheelInstalled {
            wheelInstalled = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(wheelPanned(_:)))
            pan.allowedScrollTypesMask = .all
            pan.allowedTouchTypes = []
            pan.delegate = self
            addGestureRecognizer(pan)
        }
        guard capturesKeyboard, window != nil else { return }
        claimKeyboard()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
        guard capturesKeyboard else { return }
        placeCapture()
    }

    private func installCapture() {
        capture.terminal = self
        capture.onFocusChange = { [weak self] focused in
            self?.getTerminal().setTerminalFocus(focused)
        }
        capture.keyboardAppearance = keyboardAppearance
        if let accessory = inputAccessoryView {
            capture.inputAccessoryView = accessory
            inputAccessoryView = nil
        }
        if capture.superview == nil { addSubview(capture) }
        placeCapture()
        if window != nil { claimKeyboard() }
    }

    private func removeCapture() {
        if capture.inputAccessoryView != nil {
            inputAccessoryView = capture.inputAccessoryView
            capture.inputAccessoryView = nil
        }
        capture.onFocusChange = nil
        capture.removeFromSuperview()
    }

    // a real text field has to cover the visible terminal, or iOS will not deliver typing to it. It does not take taps.
    private func placeCapture() {
        let frame = CGRect(origin: contentOffset, size: bounds.size)
        guard frame.width > 1, frame.height > 1, capture.frame != frame else { return }
        capture.frame = frame
    }

    private func claimKeyboard() {
        guard capturesKeyboard, window != nil, !capture.isFirstResponder else { return }
        if becomeFirstResponder() { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.capturesKeyboard, self.window != nil, !self.capture.isFirstResponder else { return }
            _ = self.becomeFirstResponder()
        }
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
