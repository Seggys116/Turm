import AppKit
import SwiftUI

enum SpotlightKey {
    case up
    case down
    case tab
    case submit
    case cancel
}

struct SpotlightField: NSViewRepresentable {
    @Binding var text: String
    let directory: String
    let placeholder: String
    let onKey: (SpotlightKey) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        let view = SpotlightTextView()
        view.placeholder = placeholder
        view.font = TerminalMetrics.font
        view.textColor = Theme.text.dynamicNS
        view.insertionPointColor = Theme.text.dynamicNS
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: TerminalMetrics.lineHeight)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: TerminalMetrics.lineHeight)
        view.minSize = NSSize(width: 0, height: TerminalMetrics.lineHeight)
        view.typingAttributes = HighlightStyle.base
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        context.coordinator.textView = view
        context.coordinator.restyle()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.textView else { return }
        if view.string != text {
            view.string = text
            view.moveToEndOfDocument(nil)
        }
        coordinator.restyle()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpotlightField
        weak var textView: SpotlightTextView?

        init(_ parent: SpotlightField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            if view.string.contains(where: \.isNewline) {
                let flat = view.string.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                view.string = flat
            }
            parent.text = view.string
            restyle()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: SpotlightKey
            switch selector {
            case #selector(NSResponder.moveUp(_:)): key = .up
            case #selector(NSResponder.moveDown(_:)): key = .down
            case #selector(NSResponder.insertTab(_:)): key = .tab
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)): key = .submit
            case #selector(NSResponder.cancelOperation(_:)): key = .cancel
            default: return false
            }
            parent.onKey(key)
            return true
        }

        func restyle() {
            guard let view = textView, !view.hasMarkedText(), let storage = view.textStorage else { return }
            let text = view.string
            if SpotlightModel.isSearch(text) {
                view.typingAttributes = HighlightStyle.apply([], to: storage)
                if let sigil = text.firstIndex(of: SpotlightModel.searchSigil) {
                    storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: NSRange(sigil...sigil, in: text))
                }
            } else {
                let spans = SyntaxHighlighter.spans(for: text, directory: parent.directory, environment: SystemCompletionEnvironment.shared)
                view.typingAttributes = HighlightStyle.apply(spans, to: storage)
            }
            view.needsDisplay = true
        }
    }
}

final class SpotlightTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? TerminalMetrics.font,
            .foregroundColor: Theme.secondaryText.dynamicNS,
        ]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attributes)
    }
}
