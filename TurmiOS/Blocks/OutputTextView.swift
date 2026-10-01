import SwiftUI
import UIKit

struct BlockActions {
    let copyCommand: () -> Void
    let copyOutput: () -> Void
    let rerun: (() -> Void)?
    let shortcutTitle: String?
    let shortcut: (() -> Void)?
}

struct OutputTextView: UIViewRepresentable {
    let id: UUID
    let text: NSAttributedString
    let revision: Int
    let fontSize: Double
    let actions: BlockActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeUIView(context: Context) -> OutputUITextView {
        let view = OutputUITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = [.link]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: OutputUITextView, context: Context) {
        context.coordinator.actions = actions
        apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: OutputUITextView, context: Context) -> CGSize? {
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let width = proposed ?? max(view.bounds.width, view.window?.windowScene?.screen.bounds.width ?? 320)
        apply(to: view)
        let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    private func apply(to view: OutputUITextView) {
        let key = OutputUITextView.Key(id: id, revision: revision, fontSize: fontSize)
        guard view.applied != key else { return }
        view.applied = key
        view.attributedText = BlockStyle.display(text, size: fontSize)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var actions: BlockActions

        init(actions: BlockActions) {
            self.actions = actions
        }

        func textView(
            _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            let current = self.actions
            var custom = [
                UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { _ in current.copyCommand() },
                UIAction(title: "Copy Output", image: UIImage(systemName: "doc.on.doc")) { _ in current.copyOutput() },
            ]
            if let rerun = current.rerun {
                custom.append(UIAction(title: "Run Again", image: UIImage(systemName: "arrow.clockwise")) { _ in rerun() })
            }
            if let title = current.shortcutTitle, let shortcut = current.shortcut {
                custom.append(UIAction(title: title, image: UIImage(systemName: "at")) { _ in shortcut() })
            }
            return UIMenu(children: suggestedActions + [UIMenu(options: .displayInline, children: custom)])
        }
    }
}

final class OutputUITextView: UITextView {
    struct Key: Equatable {
        let id: UUID
        let revision: Int
        let fontSize: Double
    }

    var applied: Key?
}
