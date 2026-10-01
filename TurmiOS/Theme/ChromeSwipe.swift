import Observation
import SwiftUI

struct ChromeSwipeAction: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var role: ButtonRole?
    var handler: () -> Void
}

@Observable
final class SwipeCoordinator {
    var open: UUID?
}

private let defaultSwipeCoordinator = SwipeCoordinator()

extension EnvironmentValues {
    @Entry var swipeCoordinator = defaultSwipeCoordinator
}

extension View {
    func closesSwipeRowsOnScroll() -> some View {
        modifier(SwipeScrollCloser())
    }
}

private struct SwipeScrollCloser: ViewModifier {
    @Environment(\.swipeCoordinator) private var coordinator

    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, phase in
            if phase == .interacting { coordinator.open = nil }
        }
    }
}

/// A row that reveals themed actions on a leading swipe; the first action fires on a full swipe.
struct ChromeSwipeRow<Content: View>: View {
    let actions: [ChromeSwipeAction]
    let content: Content
    @Environment(\.swipeCoordinator) private var coordinator
    @State private var identity = UUID()
    @State private var settled: CGFloat = 0
    @State private var drag: CGFloat = 0
    @State private var horizontal: Bool?
    @State private var rowWidth: CGFloat = 0
    @GestureState private var touching = false
    @ScaledMetric(relativeTo: .caption) private var actionWidth: CGFloat = 76

    private static var spring: Animation { .spring(duration: 0.36, bounce: 0.24) }
    private static var inset: CGFloat { 4 }

    init(actions: [ChromeSwipeAction], @ViewBuilder content: () -> Content) {
        self.actions = actions
        self.content = content()
    }

    private var reveal: CGFloat { actionWidth * CGFloat(actions.count) }
    private var threshold: CGFloat { max(reveal + 44, rowWidth * 0.5) }
    private var raw: CGFloat { settled + drag }
    private var armed: Bool { !actions.isEmpty && raw < -threshold }

    private var offset: CGFloat {
        if raw > 0 { return 30 * (1 - 1 / (raw / 60 + 1)) }
        return max(raw, -rowWidth)
    }

    var body: some View {
        content
            .offset(x: offset)
            .overlay {
                if settled < 0 {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .offset(x: offset)
                        .accessibilityHidden(true)
                }
            }
            .background(alignment: .trailing) { revealed }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .simultaneousGesture(swipe)
            .onChange(of: armed) { _, now in
                if now { Haptics.press() }
            }
            .onChange(of: touching) { _, now in
                if !now, drag != 0 { withAnimation(Self.spring) { drag = 0 } }
            }
            .onChange(of: coordinator.open) { _, current in
                if current != identity, settled != 0 { close() }
            }
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(action.title) { action.handler() }
                }
            }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if horizontal == nil { horizontal = abs(value.translation.width) > abs(value.translation.height) }
                guard horizontal == true, !actions.isEmpty else { return }
                drag = value.translation.width
            }
            .onEnded { value in
                defer { horizontal = nil }
                guard horizontal == true, !actions.isEmpty else {
                    drag = 0
                    return
                }
                let final = settled + value.translation.width
                let projected = settled + value.predictedEndTranslation.width
                if final < -threshold {
                    fire(actions[0])
                } else if final < -reveal / 2 || projected < -reveal {
                    withAnimation(Self.spring) {
                        settled = -reveal
                        drag = 0
                    }
                    coordinator.open = identity
                } else {
                    close()
                }
            }
    }

    private var revealed: some View {
        let width = max(0, -offset)
        let others = reveal - actionWidth
        return HStack(spacing: 0) {
            ForEach(Array(actions.enumerated().reversed()), id: \.element.id) { index, action in
                pill(action, width: index == 0 ? max(actionWidth, width - others) : actionWidth)
            }
        }
        .frame(width: width, alignment: .trailing)
        .clipped()
        .allowsHitTesting(settled < 0)
    }

    private func pill(_ action: ChromeSwipeAction, width: CGFloat) -> some View {
        Button {
            fire(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(action.title)
                    .font(Chrome.Typeface.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(action.role == .destructive ? Color.white : Chrome.onAccent)
            .frame(width: width - Self.inset, alignment: .center)
            .frame(maxHeight: .infinity)
            .background(
                action.role == .destructive ? Chrome.failure : Chrome.accent,
                in: RoundedRectangle(cornerRadius: Chrome.Radius.chip)
            )
            .padding(.vertical, Self.inset)
            .padding(.trailing, Self.inset)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChromePressStyle())
    }

    private func close() {
        withAnimation(Self.spring) {
            settled = 0
            drag = 0
        }
        if coordinator.open == identity { coordinator.open = nil }
    }

    private func fire(_ action: ChromeSwipeAction) {
        if action.role == .destructive { Haptics.warn() } else { Haptics.tap() }
        withAnimation(Self.spring) {
            settled = -rowWidth
            drag = 0
        }
        if coordinator.open == identity { coordinator.open = nil }
        action.handler()
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(Self.spring) { settled = 0 }
        }
    }
}
