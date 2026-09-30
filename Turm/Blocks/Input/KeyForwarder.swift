import AppKit
import SwiftUI

struct KeyForwarder: NSViewRepresentable {
    let session: TerminalSession
    let isFocused: Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.session = session
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.session = session
        guard isFocused else { return }
        DispatchQueue.main.async {
            // a forwarder fading out after its command ended must not pull focus from the input
            guard view.session?.isRunning == true, let window = view.window, window.firstResponder !== view,
                  !(window.firstResponder is SelectionResponderView)
            else { return }
            window.makeFirstResponder(view)
        }
    }
}

final class KeyView: NSView {
    var session: TerminalSession?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        session?.focus()
        return true
    }

    override func keyDown(with event: NSEvent) {
        forward(event, type: event.isARepeat ? .repeated : .press)
    }

    override func keyUp(with event: NSEvent) {
        guard session?.keyModes.reportEvents == true else { return }
        forward(event, type: .release)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let session, session.keyModes.reportAllKeys, let pressed = Self.isPressed(event) else { return }
        let key = KeyInput(
            keyCode: event.keyCode,
            characters: "",
            unmodified: "",
            shift: event.modifierFlags.contains(.shift),
            control: event.modifierFlags.contains(.control),
            option: event.modifierFlags.contains(.option),
            command: event.modifierFlags.contains(.command),
            capsLock: event.modifierFlags.contains(.capsLock),
            event: pressed ? .press : .release
        )
        guard let bytes = KeyEncoder.encode(key, modes: session.keyModes) else { return }
        session.sendInput(bytes)
    }

    private func forward(_ event: NSEvent, type: KeyEventType) {
        guard let session, !event.modifierFlags.contains(.command) else { return }
        let flags = event.modifierFlags
        let key = KeyInput(
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            unmodified: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "",
            shift: flags.contains(.shift),
            control: flags.contains(.control),
            option: flags.contains(.option),
            command: false,
            capsLock: flags.contains(.capsLock),
            event: type,
            shifted: event.characters(byApplyingModifiers: .shift)
        )
        guard let bytes = KeyEncoder.encode(key, modes: session.keyModes) else { return }
        session.sendInput(bytes)
    }

    private static func isPressed(_ event: NSEvent) -> Bool? {
        let raw = event.modifierFlags.rawValue
        switch event.keyCode {
        case 57: return event.modifierFlags.contains(.capsLock)
        case 56: return raw & 0x2 != 0
        case 60: return raw & 0x4 != 0
        case 59: return raw & 0x1 != 0
        case 62: return raw & 0x2000 != 0
        case 58: return raw & 0x20 != 0
        case 61: return raw & 0x40 != 0
        case 55: return raw & 0x8 != 0
        case 54: return raw & 0x10 != 0
        default: return nil
        }
    }

    @objc func paste(_ sender: Any?) {
        let files = AttachmentStore.urls(from: .general, imageOverridesText: false)
        if !files.isEmpty {
            session?.pasteFiles(files)
        } else if let text = NSPasteboard.general.string(forType: .string) {
            session?.pasteText(text)
        }
    }
}
