import SwiftUI

struct PieceText: View {
    let text: AttributedString
    let highlights: SegmentHighlights
    let piece: PieceRef

    var body: some View {
        BlockTextView(text: text, highlights: highlights, piece: piece, selection: piece.host.selectedRange(for: piece.id))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BlockSelection.space)) } action: { frame in
                piece.host.setFrame(frame, for: piece.id)
            }
    }
}
