import SwiftUI

struct BarLayoutItem: Identifiable, Equatable {
    let id: String
    let name: String
    let label: String
    let symbol: String?

    init(_ action: ProjectAction) {
        id = action.id
        name = action.title
        label = action.title
        symbol = action.displaySymbol
    }

    init(_ variant: ProjectVariant) {
        id = variant.id
        name = variant.title
        label = variant.option(at: nil).label
        symbol = nil
    }
}

private struct ChipFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct BarLayoutEditor: View {
    let catalogue: [BarLayoutItem]
    @Binding var ids: [String]

    private struct Drag {
        var id: String
        var fromBar: Bool
        var pointer: CGPoint
        var grab: CGSize
        var size: CGSize
        var overBar: Bool
    }

    @State private var drag: Drag?
    @State private var frames: [String: CGRect] = [:]
    @State private var barFrame = CGRect.zero

    private static let space = "barLayoutEditor"
    private static let slide = Animation.spring(duration: 0.26, bounce: 0.12)

    private var byID: [String: BarLayoutItem] {
        Dictionary(catalogue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var onBar: [String] {
        ids.filter { byID[$0] != nil }
    }

    private var removing: Bool {
        guard let drag else { return false }
        return drag.fromBar && !drag.overBar
    }

    private var layout: [String] {
        guard let drag else { return onBar }
        var rest = onBar.filter { $0 != drag.id }
        guard drag.overBar || drag.fromBar else { return rest }
        if removing { rest.append(drag.id) } else { rest.insert(drag.id, at: slot(in: rest, drag: drag)) }
        return rest
    }

    private func slot(in rest: [String], drag: Drag) -> Int {
        var index = 0
        for id in rest {
            guard let frame = frames["bar.\(id)"] else { break }
            let before = frame.maxY < drag.pointer.y ? true : (frame.minY > drag.pointer.y ? false : frame.midX < drag.pointer.x)
            guard before else { break }
            index += 1
        }
        return index
    }

    private var available: [BarLayoutItem] {
        let used = Set(onBar)
        return catalogue.filter { !used.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                caption("On the bar")
                strip
            }
            VStack(alignment: .leading, spacing: 8) {
                caption("Available")
                pool
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ChipFrames.self) { frames = $0 }
        .overlay(alignment: .topLeading) { floating }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText.color)
    }

    private var strip: some View {
        let order = layout
        return FlowLayout(spacing: 2) {
            ForEach(order, id: \.self) { id in
                if let item = byID[id] {
                    let isDragged = drag?.id == id
                    EditorChip(item: item, onRemove: drag == nil ? { remove(id) } : nil)
                        .opacity(isDragged ? 0 : 1)
                        .frame(width: isDragged && removing ? 0 : nil, alignment: .leading)
                        .clipped()
                        .reportFrame("bar.\(id)")
                        .gesture(dragGesture(id: id, fromBar: true))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
        .background(Theme.statusBar.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider.color, lineWidth: 1).allowsHitTesting(false))
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .named(Self.space)), initial: true) { _, frame in barFrame = frame }
        })
        .animation(Self.slide, value: order)
    }

    private var pool: some View {
        FlowLayout(spacing: 2) {
            ForEach(available) { item in
                EditorChip(item: item, onRemove: nil)
                    .opacity(drag?.id == item.id ? 0.35 : 1)
                    .reportFrame("pool.\(item.id)")
                    .onTapGesture { add(item.id) }
                    .gesture(dragGesture(id: item.id, fromBar: false))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
        .background(Theme.statusBar.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider.color, lineWidth: 1).allowsHitTesting(false))
    }

    @ViewBuilder
    private var floating: some View {
        if let drag, let item = byID[drag.id] {
            EditorChip(item: item, onRemove: nil)
                .background(removing ? Theme.removed.color.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .scaleEffect(1.06)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .opacity(removing ? 0.7 : 1)
                .offset(x: drag.pointer.x - drag.grab.width, y: drag.pointer.y - drag.grab.height)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(id: String, fromBar: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    let frame = frames["\(fromBar ? "bar" : "pool").\(id)"] ?? CGRect(origin: value.startLocation, size: .zero)
                    drag = Drag(
                        id: id, fromBar: fromBar, pointer: value.location,
                        grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                        size: frame.size, overBar: fromBar
                    )
                }
                drag?.pointer = value.location
                drag?.overBar = barFrame.insetBy(dx: -16, dy: -12).contains(value.location)
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        guard let current = drag else { return }
        let next: [String]
        if current.fromBar {
            next = current.overBar ? layout : onBar.filter { $0 != current.id }
        } else {
            next = current.overBar ? layout : onBar
        }
        withAnimation(Self.slide) {
            ids = next
            drag = nil
        }
    }

    private func add(_ id: String) {
        withAnimation(Self.slide) { ids = onBar + [id] }
    }

    private func remove(_ id: String) {
        withAnimation(Self.slide) { ids = onBar.filter { $0 != id } }
    }
}

private extension View {
    func reportFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ChipFrames.self, value: [key: proxy.frame(in: .named("barLayoutEditor"))])
        })
    }
}

private struct EditorChip: View {
    let item: BarLayoutItem
    var onRemove: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Group {
            if let symbol = item.symbol {
                BarButton(symbol: symbol, title: item.label, isEnabled: true, help: "") {}
            } else {
                BarChip(title: item.label, isQuiet: true) {}
            }
        }
        .allowsHitTesting(false)
        .fixedSize()
        .background(isHovering ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .topTrailing) {
            if let onRemove, isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text.color, Theme.chipFill.color)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel("Remove \(item.name)")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
