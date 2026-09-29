import AppKit
import Foundation
import Observation

struct PieceRef {
    let id: PieceID
    let host: BlockSelection
}

@Observable
final class BlockSelection {
    static let space = "turm.blocks"

    private(set) var anchor: SelectionPoint?
    private(set) var focus: SelectionPoint?

    @ObservationIgnored var listFrame = CGRect.zero
    @ObservationIgnored weak var responder: SelectionResponderView?
    @ObservationIgnored var source: () -> [SearchDocument] = { [] }
    @ObservationIgnored private(set) var layout = SelectionLayout(pieces: [])
    @ObservationIgnored private var frames: [PieceID: CGRect] = [:]
    @ObservationIgnored private var views: [PieceID: WeakText] = [:]
    @ObservationIgnored private var unit: SelectionUnit?
    @ObservationIgnored private var granularity = SelectionGranularity.character

    private struct WeakText {
        weak var view: BlockTextNSView?
    }

    var hasSelection: Bool {
        guard let anchor, let focus else { return false }
        return anchor != focus
    }

    func selectedRange(for id: PieceID) -> NSRange? {
        guard let anchor, let focus else { return nil }
        return layout.range(of: id, anchor: anchor, focus: focus)
    }

    func register(_ id: PieceID, view: BlockTextNSView) {
        views[id] = WeakText(view: view)
    }

    func unregister(_ id: PieceID, view: BlockTextNSView) {
        if views[id]?.view === view {
            views[id] = nil
            frames[id] = nil
        }
    }

    func setFrame(_ frame: CGRect, for id: PieceID) {
        frames[id] = frame
    }

    func clear() {
        anchor = nil
        focus = nil
        unit = nil
        responder?.release()
    }

    func selectAll() {
        refreshLayout()
        guard let all = layout.everything() else { return }
        anchor = all.anchor
        focus = all.focus
    }

    func claimFocus() {
        responder?.claim()
    }

    func releaseFocus() {
        responder?.release()
    }

    func selectedText() -> String? {
        guard let anchor, let focus, anchor != focus else { return nil }
        if layout.index(of: anchor.piece) == nil || layout.index(of: focus.piece) == nil { refreshLayout() }
        let text = layout.text(anchor: anchor, focus: focus)
        return text.isEmpty ? nil : text
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let text = selectedText() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    func press(at point: CGPoint, clicks: Int, extend: Bool) {
        refreshLayout()
        granularity = SelectionGranularity(clicks: clicks)
        guard let hit = hit(point, insertion: granularity == .character) else {
            clear()
            return
        }
        if extend, clicks <= 1, let anchor, layout.index(of: anchor.piece) != nil {
            unit = SelectionUnit(start: anchor, end: anchor)
            focus = hit
            return
        }
        let picked = layout.unit(at: hit, granularity: granularity)
        unit = picked
        anchor = picked.start
        focus = picked.end
    }

    func drag(to point: CGPoint) {
        guard let unit, let hit = hit(point, insertion: granularity == .character) else { return }
        let extended = layout.extend(from: unit, to: hit, granularity: granularity)
        anchor = extended.anchor
        focus = extended.focus
    }

    func link(at point: CGPoint) -> URL? {
        guard let target = pieceView(at: point) else { return nil }
        return target.view.link(at: target.local)
    }

    private func refreshLayout() {
        layout = SelectionLayout(documents: source())
    }

    private func pieceView(at point: CGPoint) -> (view: BlockTextNSView, local: NSPoint)? {
        for (id, frame) in frames where frame.contains(point) {
            if let view = views[id]?.view {
                return (view, NSPoint(x: point.x - frame.minX, y: point.y - frame.minY))
            }
        }
        return nil
    }

    private func hit(_ point: CGPoint, insertion: Bool) -> SelectionPoint? {
        var best: (piece: SelectionLayout.Piece, frame: CGRect, distance: CGFloat)?
        for piece in layout.pieces {
            guard let frame = frames[piece.id] else { continue }
            let distance = point.y < frame.minY ? frame.minY - point.y : (point.y > frame.maxY ? point.y - frame.maxY : 0)
            if best == nil || distance < best!.distance { best = (piece, frame, distance) }
            if distance == 0 { break }
        }
        guard let best else { return nil }
        let piece = best.piece
        if point.y < best.frame.minY { return SelectionPoint(piece: piece.id, offset: 0) }
        if point.y > best.frame.maxY { return SelectionPoint(piece: piece.id, offset: piece.length) }
        guard let view = views[piece.id]?.view else { return SelectionPoint(piece: piece.id, offset: 0) }
        let local = NSPoint(x: point.x - best.frame.minX, y: point.y - best.frame.minY)
        let offset = insertion ? view.insertionOffset(at: local) : view.characterOffset(at: local)
        return SelectionPoint(piece: piece.id, offset: min(max(offset, 0), piece.length))
    }
}
