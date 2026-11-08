import SwiftTerm
import SwiftUI

struct TerminalRepresentable: UIViewRepresentable {
    let surface: TerminalSurface
    let fontSize: Double
    var focusOnAppear = true
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> TerminalStage {
        surface.apply(dark: colorScheme == .dark)
        surface.apply(fontSize: fontSize)
        let stage = surface.stage
        stage.adopt()
        let view = surface.view
        if focusOnAppear { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        return stage
    }

    func updateUIView(_ stage: TerminalStage, context: Context) {
        stage.adopt()
        surface.apply(dark: colorScheme == .dark)
        surface.apply(fontSize: fontSize)
    }
}
