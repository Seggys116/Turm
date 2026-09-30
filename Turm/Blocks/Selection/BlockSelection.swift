import AppKit
import Foundation
import Observation

struct PieceRef {
    let id: PieceID
    let host: BlockSelection
    var slot = 0
    var offset = 0

    func slice(slot: Int, offset: Int) -> PieceRef {
        PieceRef(id: id, host: host, slot: slot, offset: offset)
    }

    func local(_ range: NSRange?, length: Int) -> NSRange? {
        guard let range else { return nil }
        let clipped = NSIntersectionRange(range, NSRange(location: offset, length: length))
        guard clipped.length > 0 else { return nil }
        return NSRange(location: clipped.location - offset, length: clipped.length)
    }
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
    @ObservationIgnored private var frames: [PieceID: [Int: CGRect]] = [:]
    @ObservationIgnored private var views: [PieceID: [Int: WeakText]] = [:]
    @ObservationIgnored private var unit: SelectionUnit?
    @ObservationIgnored private var granularity = SelectionGranularity.character

    private struct WeakText {
        weak var view: BlockTextNSView?
        let offset: Int
    }

    private struct Target {
        let piece: SelectionLayout.Piece
        let frame: CGRect
        let text: WeakText?
    }

    var hasSelection: Bool {
        guard let anchor, let focus else { return false }
        return anchor != focus
    }

    func selectedRange(for id: PieceID) -> NSRange? {
        guard let anchor, let focus else { return nil }
        return layout.range(of: id, anchor: anchor, focus: focus)
    }

    func register(_ piece: PieceRef, view: BlockTextNSView) {
        views[piece.id, default: [:]][piece.slot] = WeakText(view: view, offset: piece.offset)
    }

    func unregister(_ piece: PieceRef, view: BlockTextNSView) {
        guard views[piece.id]?[piece.slot]?.view === view else { return }
        views[piece.id]?[piece.slot] = nil
        frames[piece.id]?[piece.slot] = nil
        if views[piece.id]?.isEmpty == true { views[piece.id] = nil }
        if frames[piece.id]?.isEmpty == true { frames[piece.id] = nil }
    }

    func setFrame(_ frame: CGRect, for piece: PieceRef) {
        frames[piece.id, default: [:]][piece.slot] = frame
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
        guard unit != nil else { return }
        refreshLayout()
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
        for (id, slots) in frames {
            for (slot, frame) in slots where frame.contains(point) {
                if let view = views[id]?[slot]?.view {
                    return (view, NSPoint(x: point.x - frame.minX, y: point.y - frame.minY))
                }
            }
        }
        return nil
    }

    private func hit(_ point: CGPoint, insertion: Bool) -> SelectionPoint? {
        var best: (target: Target, distance: CGFloat)?
        search: for piece in layout.pieces {
            guard let slots = frames[piece.id] else { continue }
            for (slot, frame) in slots {
                let distance = point.y < frame.minY ? frame.minY - point.y : (point.y > frame.maxY ? point.y - frame.maxY : 0)
                if best == nil || distance < best!.distance {
                    best = (Target(piece: piece, frame: frame, text: views[piece.id]?[slot]), distance)
                }
                if distance == 0 { break search }
            }
        }
        guard let target = best?.target else { return nil }
        let piece = target.piece
        let start = target.text?.offset ?? 0
        let end = target.text?.view.map { start + $0.textLength } ?? piece.length
        if point.y < target.frame.minY { return SelectionPoint(piece: piece.id, offset: min(start, piece.length)) }
        if point.y > target.frame.maxY { return SelectionPoint(piece: piece.id, offset: min(end, piece.length)) }
        guard let view = target.text?.view else { return SelectionPoint(piece: piece.id, offset: 0) }
        let local = NSPoint(x: point.x - target.frame.minX, y: point.y - target.frame.minY)
        let offset = start + (insertion ? view.insertionOffset(at: local) : view.characterOffset(at: local))
        return SelectionPoint(piece: piece.id, offset: min(max(offset, 0), piece.length))
    }
}
