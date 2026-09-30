import SwiftUI

@Observable
final class CompletionModel {
    private(set) var items: [CompletionItem] = []
    private(set) var engaged = false
    var selected = 0
    var hinted = false
    @ObservationIgnored var onAccept: (Int) -> Void = { _ in }
    @ObservationIgnored var onPresentation: () -> Void = {}

    var isOpen: Bool { !items.isEmpty }
    var consumesEnter: Bool { isOpen && engaged }

    func show(_ items: [CompletionItem], engaged: Bool) {
        self.items = items
        self.engaged = engaged
        selected = 0
        hinted = false
        onPresentation()
    }

    func close() {
        guard !items.isEmpty else { return }
        items = []
        selected = 0
        engaged = false
        hinted = false
        onPresentation()
    }

    func move(by step: Int) {
        guard !items.isEmpty else { return }
        if !engaged {
            engaged = true
            if step > 0 {
                selected = hinted && items.count > 1 ? 1 : 0
            } else {
                selected = items.count - 1
            }
            return
        }
        selected = (selected + step + items.count) % items.count
    }
}

nonisolated enum AutoTrigger {
    static func eligible(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return !last.isWhitespace
    }
}

struct CompletionList: View {
    let model: CompletionModel

    static let rowHeight: CGFloat = 24
    static let maxRows = 9

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        CompletionRow(item: item, highlight: highlight(index))
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onAccept(index) }
                    }
                }
                .padding(.vertical, 4)
            }
            .squareScrollbar()
            .onAppear { proxy.scrollTo(model.selected) }
            .onChange(of: model.selected) { _, value in
                proxy.scrollTo(value)
            }
        }
        .frame(height: CGFloat(min(model.items.count, Self.maxRows)) * Self.rowHeight + 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
    }

    private func highlight(_ index: Int) -> Double {
        if model.engaged { return index == model.selected ? 0.28 : 0 }
        return model.hinted && index == 0 ? 0.12 : 0
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let highlight: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText.color)
                .frame(width: 14)
            Text(item.display)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(item.kind.label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText.color)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.accentColor.opacity(highlight), in: RoundedRectangle(cornerRadius: 5))
        .animation(.easeOut(duration: 0.1), value: highlight)
        .padding(.horizontal, 8)
    }
}
