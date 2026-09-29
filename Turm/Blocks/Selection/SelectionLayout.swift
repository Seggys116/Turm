import Foundation

nonisolated struct PieceID: Hashable, Sendable {
    let blockID: UUID
    let target: SearchMatch.Target
}

nonisolated struct SelectionPoint: Hashable, Sendable {
    var piece: PieceID
    var offset: Int
}

nonisolated enum SelectionGranularity: Sendable {
    case character
    case word
    case line

    init(clicks: Int) {
        switch clicks {
        case ...1: self = .character
        case 2: self = .word
        default: self = .line
        }
    }
}

nonisolated struct SelectionUnit: Equatable, Sendable {
    var start: SelectionPoint
    var end: SelectionPoint
}

nonisolated struct SelectionLayout: Sendable {
    nonisolated struct Piece: Sendable {
        let id: PieceID
        let text: String
        let length: Int
    }

    let pieces: [Piece]
    private let order: [PieceID: Int]

    init(pieces: [Piece]) {
        self.pieces = pieces
        var order: [PieceID: Int] = [:]
        for (index, piece) in pieces.enumerated() { order[piece.id] = index }
        self.order = order
    }

    init(documents: [SearchDocument]) {
        var pieces: [Piece] = []
        for document in documents {
            pieces.append(Self.piece(document.id, .command, document.command))
            for part in document.parts {
                pieces.append(Self.piece(document.id, .segment(part.index), part.text))
            }
        }
        self.init(pieces: pieces)
    }

    private static func piece(_ id: UUID, _ target: SearchMatch.Target, _ text: String) -> Piece {
        Piece(id: PieceID(blockID: id, target: target), text: text, length: text.utf16.count)
    }

    func index(of id: PieceID) -> Int? {
        order[id]
    }

    func isBefore(_ lhs: SelectionPoint, _ rhs: SelectionPoint) -> Bool {
        guard let left = order[lhs.piece], let right = order[rhs.piece] else { return false }
        return left != right ? left < right : lhs.offset < rhs.offset
    }

    func ordered(_ anchor: SelectionPoint, _ focus: SelectionPoint) -> (start: SelectionPoint, end: SelectionPoint) {
        isBefore(focus, anchor) ? (focus, anchor) : (anchor, focus)
    }

    func range(of id: PieceID, anchor: SelectionPoint, focus: SelectionPoint) -> NSRange? {
        guard let position = order[id], let span = span(anchor, focus), position >= span.first, position <= span.last else { return nil }
        return slice(position, span)
    }

    func text(anchor: SelectionPoint, focus: SelectionPoint) -> String {
        guard let span = span(anchor, focus) else { return "" }
        var result = ""
        var wrote = false
        for position in span.first...span.last {
            guard let range = slice(position, span) else { continue }
            let piece = pieces[position]
            let text = range.length == piece.length ? piece.text : (piece.text as NSString).substring(with: range)
            if wrote { result.append("\n") }
            result.append(Self.tidy(text))
            wrote = true
        }
        return result
    }

    private struct Span {
        let first: Int
        let last: Int
        let start: SelectionPoint
        let end: SelectionPoint
    }

    private func span(_ anchor: SelectionPoint, _ focus: SelectionPoint) -> Span? {
        guard order[anchor.piece] != nil, order[focus.piece] != nil else { return nil }
        let (start, end) = ordered(anchor, focus)
        guard let first = order[start.piece], let last = order[end.piece] else { return nil }
        return Span(first: first, last: last, start: start, end: end)
    }

    private func slice(_ position: Int, _ span: Span) -> NSRange? {
        let length = pieces[position].length
        let from = position == span.first ? min(max(span.start.offset, 0), length) : 0
        let to = position == span.last ? min(max(span.end.offset, 0), length) : length
        return to > from ? NSRange(location: from, length: to - from) : nil
    }

    func everything() -> (anchor: SelectionPoint, focus: SelectionPoint)? {
        guard let first = pieces.first, let last = pieces.last else { return nil }
        return (SelectionPoint(piece: first.id, offset: 0), SelectionPoint(piece: last.id, offset: last.length))
    }

    func unit(at point: SelectionPoint, granularity: SelectionGranularity) -> SelectionUnit {
        guard granularity != .character, let position = order[point.piece] else {
            return SelectionUnit(start: point, end: point)
        }
        let piece = pieces[position]
        let text = piece.text as NSString
        let range = granularity == .word ? Self.wordRange(in: text, at: point.offset) : Self.lineRange(in: text, at: point.offset)
        return SelectionUnit(
            start: SelectionPoint(piece: piece.id, offset: range.location),
            end: SelectionPoint(piece: piece.id, offset: NSMaxRange(range))
        )
    }

    func extend(from anchor: SelectionUnit, to point: SelectionPoint, granularity: SelectionGranularity) -> (anchor: SelectionPoint, focus: SelectionPoint) {
        let target = unit(at: point, granularity: granularity)
        if isBefore(point, anchor.start) {
            return (anchor.end, target.start)
        }
        return (anchor.start, target.end)
    }

    static func tidy(_ slice: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(slice.utf8.count)
        var kept = 0
        for byte in slice.utf8 {
            if byte == 10 {
                bytes.removeLast(bytes.count - kept)
                bytes.append(10)
                kept = bytes.count
            } else {
                bytes.append(byte)
                if byte != 32 && byte != 9 { kept = bytes.count }
            }
        }
        bytes.removeLast(bytes.count - kept)
        while bytes.last == 10 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func kind(_ unit: unichar) -> Int {
        guard let scalar = Unicode.Scalar(unit) else { return 1 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 0 }
        if CharacterSet.alphanumerics.contains(scalar) || "_-./~".unicodeScalars.contains(scalar) { return 1 }
        return 2
    }

    static func wordRange(in text: NSString, at offset: Int) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let index = min(max(offset, 0), length - 1)
        let target = kind(text.character(at: index))
        var start = index
        var end = index + 1
        while start > 0, kind(text.character(at: start - 1)) == target { start -= 1 }
        while end < length, kind(text.character(at: end)) == target { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    static func lineRange(in text: NSString, at offset: Int) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        var start = 0
        var end = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(max(offset, 0), length - 1), length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }
}
