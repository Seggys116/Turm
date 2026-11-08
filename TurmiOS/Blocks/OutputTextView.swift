import SwiftUI
import TurmCore
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
    var graphics = BlockGraphics.empty
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
        view.show(graphics, cell: BlockStyle.cellSize(fontSize: fontSize))
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
    private var graphics = BlockGraphics.empty
    private var cell = CGSize.zero
    private var painter: GraphicsLayerPainter?
    private var paintedSize: CGSize?

    func show(_ graphics: BlockGraphics, cell: CGSize) {
        self.graphics = graphics
        self.cell = cell
        paintedSize = nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard paintedSize != bounds.size else { return }
        paintedSize = bounds.size
        paint()
    }

    private func paint() {
        guard !graphics.isEmpty, cell.width > 0, cell.height > 0, let firstTop = rowTop(graphics.firstRow) else {
            painter?.removeAll()
            return
        }
        let painter = self.painter ?? makePainter()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let geometry = GraphicsLayerPainter.Geometry(
            top: graphics.firstRow, cellWidth: cell.width, cellHeight: cell.height, scale: scale, origin: CGPoint(x: 0, y: firstTop)
        )
        var placed: [GraphicsPlacement] = []
        for var placement in graphics.placements {
            guard let top = rowTop(placement.origin.row) else { continue }
            // rows laid out taller than a cell, such as Sixel attachments, push later images down
            let expected = firstTop + CGFloat(placement.origin.row - graphics.firstRow) * cell.height
            let factor = placement.scale > 0 ? placement.scale : max(scale, 1)
            placement.pixelOffset.height += (top - expected) * factor
            placed.append(placement)
        }
        painter.update(placements: placed, geometry: geometry)
    }

    private func makePainter() -> GraphicsLayerPainter {
        let painter = GraphicsLayerPainter()
        painter.underlay.zPosition = -1
        painter.overlay.zPosition = 1
        layer.insertSublayer(painter.underlay, at: 0)
        layer.addSublayer(painter.overlay)
        self.painter = painter
        return painter
    }

    private func rowTop(_ row: Int) -> CGFloat? {
        let starts = graphics.rowStarts
        guard !starts.isEmpty else { return nil }
        let index = min(max(row - graphics.firstRow, 0), starts.count - 1)
        guard let top = lineTop(at: starts[index]) else { return nil }
        return top + CGFloat(row - graphics.firstRow - index) * cell.height
    }

    private func lineTop(at offset: Int) -> CGFloat? {
        guard let start = position(from: beginningOfDocument, offset: offset) else { return nil }
        if let end = position(from: start, offset: 1), let range = textRange(from: start, to: end) {
            let rect = firstRect(for: range)
            if !rect.isNull, !rect.isInfinite, rect.height > 0 { return rect.minY }
        }
        let caret = caretRect(for: start)
        return caret.isNull || caret.isInfinite ? nil : caret.minY
    }
}
