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

    static func shouldShow(text: String, range: NSRange, items: [CompletionItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let typed = (text as NSString).substring(with: range)
        let opensVariable = text.hasSuffix("$") || text.hasSuffix("${")
        if range.length == 0 && !opensVariable { return false }
        if items.count == 1, items[0].insert == typed || items[0].insert + items[0].terminator == typed { return false }
        return true
    }
}

struct CompletionPopup: View {
    let model: CompletionModel
    let width: CGFloat

    static let rowHeight: CGFloat = 24
    static let maxRows = 9
    static let margin: CGFloat = 12
    static let footerHeight: CGFloat = 22

    static func height(forRows rows: Int) -> CGFloat {
        CGFloat(min(rows, maxRows)) * rowHeight + 8 + footerHeight
    }

    var body: some View {
        VStack(spacing: 0) {
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
                .onChange(of: model.selected) { _, value in
                    proxy.scrollTo(value)
                }
            }
            CompletionFooter(count: model.items.count, position: model.engaged ? model.selected + 1 : nil)
                .frame(height: Self.footerHeight)
        }
        .frame(width: width, height: Self.height(forRows: model.items.count))
        .background(Theme.inputBackground.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.chipStroke.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(Self.margin)
    }

    private func highlight(_ index: Int) -> Double {
        if model.engaged { return index == model.selected ? 0.28 : 0 }
        return model.hinted && index == 0 ? 0.12 : 0
    }
}

private struct CompletionFooter: View {
    let count: Int
    let position: Int?

    var body: some View {
        HStack(spacing: 12) {
            hint("tab", "step")
            hint("\u{2192}", "accept")
            hint("\u{2191}\u{2193}", "browse")
            hint("esc", "close")
            Spacer(minLength: 4)
            Text(position.map { "\($0) of \(count)" } ?? "\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.secondaryText.color)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.chipStroke.color).frame(height: 1)
        }
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text.color)
            Text(action)
        }
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
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.accentColor.opacity(highlight))
    }
}
