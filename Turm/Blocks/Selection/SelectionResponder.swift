import AppKit
import SwiftUI

struct SelectionResponder: NSViewRepresentable {
    let selection: BlockSelection

    func makeNSView(context: Context) -> SelectionResponderView {
        let view = SelectionResponderView()
        view.selection = selection
        selection.responder = view
        return view
    }

    func updateNSView(_ view: SelectionResponderView, context: Context) {
        view.selection = selection
        selection.responder = view
    }
}

final class SelectionResponderView: NSView, NSUserInterfaceValidations {
    weak var selection: BlockSelection?
    private weak var previous: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func claim() {
        guard let window else { return }
        if window.firstResponder !== self {
            previous = window.firstResponder
            window.makeFirstResponder(self)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let window = self.window, self.selection?.hasSelection == true,
                  window.firstResponder !== self
            else { return }
            window.makeFirstResponder(self)
        }
    }

    func release() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(previous)
        previous = nil
    }

    override func keyDown(with event: NSEvent) {
        release()
        if let responder = window?.firstResponder, responder !== self {
            responder.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        selection?.copySelection()
    }

    @objc override func selectAll(_ sender: Any?) {
        selection?.selectAll()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selection?.hasSelection == true
        case #selector(selectAll(_:)): true
        default: false
        }
    }
}
