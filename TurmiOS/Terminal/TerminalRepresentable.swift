import SwiftTerm
import SwiftUI

struct TerminalRepresentable: UIViewRepresentable {
    let surface: TerminalSurface
    let fontSize: Double
    var focusOnAppear = true
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> TerminalView {
        surface.apply(dark: colorScheme == .dark)
        surface.apply(fontSize: fontSize)
        let view = surface.view
        if focusOnAppear { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        surface.apply(dark: colorScheme == .dark)
        surface.apply(fontSize: fontSize)
    }
}
