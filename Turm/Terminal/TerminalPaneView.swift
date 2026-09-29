import SwiftUI

struct TerminalPaneView: NSViewRepresentable {
    let session: TerminalSession
    let isFocused: Bool

    func makeNSView(context: Context) -> TerminalContainerView {
        session.view
    }

    func updateNSView(_ view: TerminalContainerView, context: Context) {
        guard isFocused else { return }
        // the view may not be in a window yet
        DispatchQueue.main.async { session.focus() }
    }
}
