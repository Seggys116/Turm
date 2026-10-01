import SwiftUI
import UIKit

final class CommandUITextField: UITextField {
    let keyBar = TerminalKeyBarView()
    var onSubmit: (() -> Void)?
    var onRecall: ((Int) -> Void)?
    var onBytes: ((Data) -> Void)?

    // while a command runs, edits and keys go to the program instead of the field
    var running = false

    override var hasText: Bool { running || super.hasText }

    override var keyCommands: [UIKeyCommand]? {
        guard !running else { return [] }
        let older = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(recallOlder))
        let newer = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(recallNewer))
        older.wantsPriorityOverSystemBehavior = true
        newer.wantsPriorityOverSystemBehavior = true
        return [older, newer]
    }

    @objc private func recallOlder() {
        onRecall?(-1)
    }

    @objc private func recallNewer() {
        onRecall?(1)
    }

    override func insertText(_ text: String) {
        guard running else { return super.insertText(text) }
        let typed = Array(text.replacingOccurrences(of: "\n", with: "\r").utf8)
        onBytes?(Data(keyBar.transform(typed: typed[...])))
    }

    override func deleteBackward() {
        guard running else { return super.deleteBackward() }
        onBytes?(Data([0x7F]))
    }

    override func paste(_ sender: Any?) {
        guard running else { return super.paste(sender) }
        guard let text = UIPasteboard.general.string else { return }
        onBytes?(Data(text.replacingOccurrences(of: "\n", with: "\r").utf8))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard running else { return super.pressesBegan(presses, with: event) }
        var passed = Set<UIPress>()
        for press in presses {
            if let key = press.key, let bytes = Self.bytes(for: key) {
                onBytes?(Data(bytes))
            } else {
                passed.insert(press)
            }
        }
        if !passed.isEmpty { super.pressesBegan(passed, with: event) }
    }

    private static func bytes(for key: UIKey) -> [UInt8]? {
        switch key.keyCode {
        case .keyboardUpArrow: return [0x1B, 0x5B, 0x41]
        case .keyboardDownArrow: return [0x1B, 0x5B, 0x42]
        case .keyboardRightArrow: return [0x1B, 0x5B, 0x43]
        case .keyboardLeftArrow: return [0x1B, 0x5B, 0x44]
        case .keyboardHome: return [0x1B, 0x5B, 0x48]
        case .keyboardEnd: return [0x1B, 0x5B, 0x46]
        case .keyboardPageUp: return [0x1B, 0x5B, 0x35, 0x7E]
        case .keyboardPageDown: return [0x1B, 0x5B, 0x36, 0x7E]
        case .keyboardDeleteForward: return [0x1B, 0x5B, 0x33, 0x7E]
        case .keyboardEscape: return [0x1B]
        case .keyboardTab: return [0x09]
        default:
            guard key.modifierFlags.contains(.control), let scalar = key.charactersIgnoringModifiers.unicodeScalars.first,
                  scalar.isASCII, (0x40...0x7F).contains(scalar.value)
            else { return nil }
            return [UInt8(scalar.value & 0x1F)]
        }
    }

    func handle(_ data: Data) {
        if running {
            onBytes?(data)
            return
        }
        switch [UInt8](data) {
        case [0x1B, 0x5B, 0x41], [0x1B, 0x4F, 0x41]: onRecall?(-1)
        case [0x1B, 0x5B, 0x42], [0x1B, 0x4F, 0x42]: onRecall?(1)
        case [0x1B, 0x5B, 0x43], [0x1B, 0x4F, 0x43]: move(by: 1)
        case [0x1B, 0x5B, 0x44], [0x1B, 0x4F, 0x44]: move(by: -1)
        case [0x1B, 0x5B, 0x48], [0x1B, 0x4F, 0x48], [0x01]: place(at: beginningOfDocument)
        case [0x1B, 0x5B, 0x46], [0x1B, 0x4F, 0x46], [0x05]: place(at: endOfDocument)
        case [0x7F], [0x08]:
            deleteBackward()
            sendActions(for: .editingChanged)
        case [0x0D], [0x0A]: onSubmit?()
        case [0x03], [0x15]: clear()
        default:
            if let typed = String(data: data, encoding: .utf8), !data.isEmpty, data.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) {
                insertText(typed)
                sendActions(for: .editingChanged)
            }
        }
    }

    private func move(by offset: Int) {
        guard let range = selectedTextRange,
              let target = position(from: offset < 0 ? range.start : range.end, offset: offset)
        else { return }
        place(at: target)
    }

    private func place(at position: UITextPosition) {
        selectedTextRange = textRange(from: position, to: position)
    }

    private func clear() {
        text = ""
        sendActions(for: .editingChanged)
    }
}

final class CommandFieldFocus {
    fileprivate weak var field: CommandUITextField?

    func activate() {
        _ = field?.becomeFirstResponder()
    }
}

struct CommandField: UIViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let running: Bool
    let focus: CommandFieldFocus
    let onSubmit: () -> Void
    let onRecall: (Int) -> Void
    let onBytes: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> CommandUITextField {
        let field = CommandUITextField()
        field.borderStyle = .none
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = false
        field.clearButtonMode = .never
        field.textColor = BlockTheme.text
        field.accessibilityLabel = "Command"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.inputAccessoryView = field.keyBar
        field.keyBar.onBytes = { [weak field] data in field?.handle(data) }
        field.keyBar.onPaste = { [weak field] in field?.paste(nil) }
        focus.field = field
        DispatchQueue.main.async { _ = field.becomeFirstResponder() }
        return field
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: CommandUITextField, context: Context) -> CGSize? {
        let height = max(36, ceil(field.intrinsicContentSize.height))
        return CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: height)
    }

    func updateUIView(_ field: CommandUITextField, context: Context) {
        context.coordinator.parent = self
        field.onSubmit = onSubmit
        field.onRecall = onRecall
        field.onBytes = onBytes
        field.running = running
        if field.text != text { field.text = text }
        let font = BlockStyle.font(style: 0, size: fontSize)
        if field.font != font { field.font = font }
        field.attributedPlaceholder = NSAttributedString(
            string: "Command", attributes: [.foregroundColor: BlockTheme.ghost, .font: font]
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CommandField

        init(_ parent: CommandField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            if parent.running {
                parent.onBytes(Data([0x0D]))
                return false
            }
            if !(field.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty { parent.onSubmit() }
            return false
        }
    }
}
