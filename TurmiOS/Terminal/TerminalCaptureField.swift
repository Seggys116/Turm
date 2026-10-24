import SwiftTerm
import UIKit

/// The text field a full-screen program types into. Tapping the program's own box only moves its cursor; iOS still
/// needs a real text field, and that field has to forward every edit or the keystrokes stay on the phone.
final class TerminalCaptureField: UITextField, UITextFieldDelegate {
    weak var terminal: TurmTerminalView?
    var onFocusChange: ((Bool) -> Void)?
    private var lastEmit: (bytes: [UInt8], at: CFTimeInterval)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        borderStyle = .none
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        enablesReturnKeyAutomatically = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    // taps have to reach the terminal, so a touch on Claude's box still clicks it
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    // an empty field would swallow backspace and disable return
    override var hasText: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
    ) -> Bool {
        if string.isEmpty {
            emit(Array(repeating: 0x7F, count: max(range.length, 1)))
        } else {
            emit(Array(string.replacingOccurrences(of: "\n", with: "\r").utf8))
        }
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        emit([0x0D])
        return false
    }

    override func deleteBackward() {
        emit([0x7F])
    }

    override func paste(_ sender: Any?) {
        terminal?.paste(sender)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let terminal else {
            super.pressesBegan(presses, with: event)
            return
        }
        var text = Set<UIPress>()
        var encoded = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                text.insert(press)
                continue
            }
            if Self.commandShortcut(key, on: terminal) { continue }
            if Self.systemShouldInsert(key) {
                text.insert(press)
            } else {
                encoded.insert(press)
            }
        }
        if !encoded.isEmpty { terminal.pressesBegan(encoded, with: event) }
        if !text.isEmpty { super.pressesBegan(text, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        terminal?.pressesEnded(presses, with: event)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        terminal?.pressesCancelled(presses, with: event)
        super.pressesCancelled(presses, with: event)
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let terminal else { return }
        let now = CACurrentMediaTime()
        if let lastEmit, lastEmit.bytes == bytes, now - lastEmit.at < 0.002 { return }
        lastEmit = (bytes, now)
        terminal.send(data: bytes[...])
    }

    /// Command shortcuts belong to the terminal. Letting the empty field handle them would copy nothing over the clipboard.
    private static func commandShortcut(_ key: UIKey, on terminal: TurmTerminalView) -> Bool {
        let flags = key.modifierFlags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.alternate) else { return false }
        switch key.charactersIgnoringModifiers.lowercased() {
        case "v": terminal.paste(nil)
        case "c": terminal.copy(nil)
        case "a": terminal.selectAll(nil)
        default: return false
        }
        return true
    }

    /// Characters and backspace still have to go through the text field. Keys the terminal encodes itself must not,
    /// or they are sent twice.
    private static func systemShouldInsert(_ key: UIKey) -> Bool {
        if HardwareNewline.bytes(for: key, kittyFlags: 0) != nil { return false }
        let flags = key.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.alternate) { return false }
        switch key.keyCode {
        case .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
             .keyboardPageUp, .keyboardPageDown, .keyboardHome, .keyboardEnd,
             .keyboardEscape, .keyboardTab, .keyboardDeleteForward,
             .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
             .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
             .keyboardInsert:
            return false
        case .keyboardDeleteOrBackspace, .keyboardReturnOrEnter, .keypadEnter:
            return true
        default:
            return !key.characters.isEmpty
        }
    }
}
