import AppKit
import SwiftUI

struct SearchBar: View {
    @Bindable var search: BlockSearch
    @FocusState private var fieldFocused: Bool
    @State private var anchor = BarAnchor()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryText.color)
            TextField("Find", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .focused($fieldFocused)
                .frame(minWidth: 140, idealWidth: 200)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) { search.previous() } else { search.next() }
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
            Text(status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(search.invalidPattern == nil ? Theme.secondaryText.color : Theme.failure.color)
                .lineLimit(1)
                .fixedSize()
            SearchToggle(label: "Aa", help: "Match Case", isOn: $search.caseSensitive)
            SearchToggle(label: "W", help: "Whole Word", isOn: $search.wholeWord)
            SearchToggle(label: ".*", help: "Regular Expression", isOn: $search.useRegex)
            Button { search.previous() } label: { Image(systemName: "chevron.up") }
                .help("Previous Match")
                .disabled(search.matchCount == 0)
            Button { search.next() } label: { Image(systemName: "chevron.down") }
                .help("Next Match")
                .disabled(search.matchCount == 0)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .help("Close")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.searchBarFill.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.top, 8)
        .padding(.trailing, 14)
        .background(BarLocator(anchor: anchor))
        .onChange(of: search.focusRequest, initial: true) { fieldFocused = true }
    }

    private var borderColor: SwiftUI.Color {
        search.invalidPattern == nil ? Theme.divider.color : Theme.failure.color
    }

    private var status: String {
        if search.invalidPattern != nil { return "Invalid regex" }
        if search.query.isEmpty { return "" }
        if search.matchCount == 0 { return "No results" }
        let total = search.isTruncated ? "\(search.matchCount)+" : "\(search.matchCount)"
        return "\(search.activeIndex + 1) of \(total)"
    }

    private func dismiss() {
        search.close()
        anchor.focusEditor()
    }
}

private struct SearchToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(minWidth: 22, minHeight: 20)
                .foregroundStyle(isOn ? Theme.text.color : Theme.secondaryText.color)
                .background(isOn ? Theme.chipFill.color : SwiftUI.Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(isOn ? Theme.chipStroke.color : SwiftUI.Color.clear, lineWidth: 1))
        }
        .help(help)
    }
}

final class BarAnchor {
    weak var view: NSView?

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let bar = self?.view, let window = bar.window, let root = window.contentView else { return }
            let barFrame = bar.convert(bar.bounds, to: nil)
            let target = Self.editors(in: root)
                .map { ($0, $0.convert($0.bounds, to: nil)) }
                .filter { $0.1.maxY <= barFrame.minY + 1 && $0.1.minX < barFrame.maxX && $0.1.maxX > barFrame.minX }
                .max { $0.1.maxY < $1.1.maxY }?.0
            if let target { window.makeFirstResponder(target) }
        }
    }

    private static func editors(in view: NSView) -> [EditorTextView] {
        var found: [EditorTextView] = []
        if let editor = view as? EditorTextView { found.append(editor) }
        for child in view.subviews { found.append(contentsOf: editors(in: child)) }
        return found
    }
}

private struct BarLocator: NSViewRepresentable {
    let anchor: BarAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
