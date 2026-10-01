import SwiftUI

struct PieceText: View {
    let chunk: TextChunk
    let highlights: SegmentHighlights
    let piece: PieceRef
    var cursor: OutputCursor?
    var cursorFocused = false

    var body: some View {
        BlockTextView(
            chunk: chunk, highlights: highlights, piece: piece,
            selection: piece.local(piece.host.selectedRange(for: piece.id), length: chunk.length),
            cursor: cursor, cursorFocused: cursorFocused
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BlockSelection.space)) } action: { frame in
            piece.host.setFrame(frame, for: piece)
        }
    }
}

struct OutputTextView: View {
    let text: OutputText
    let highlights: SegmentHighlights
    let piece: PieceRef
    var cursor: OutputCursor?
    var cursorFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.chunks.enumerated()), id: \.element.id) { index, chunk in
                let offset = text.starts[index]
                PieceText(
                    chunk: chunk,
                    highlights: highlights.local(offset: offset, length: chunk.length),
                    piece: piece.slice(slot: chunk.id, offset: offset),
                    cursor: cursor?.chunk == chunk.id ? cursor : nil,
                    cursorFocused: cursorFocused
                )
            }
        }
    }
}
