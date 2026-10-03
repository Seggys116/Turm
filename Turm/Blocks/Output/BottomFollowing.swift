import SwiftUI
import TurmCore

extension View {
    func followsBottom(_ follow: Binding<BottomFollow>, position: Binding<ScrollPosition>, driver: SelectionDriver, holding: Bool) -> some View {
        modifier(BottomFollowing(follow: follow, position: position, driver: driver, holding: holding))
    }
}

extension ScrollExtent {
    init(_ geometry: ScrollGeometry) {
        self.init(top: geometry.visibleRect.minY, height: geometry.visibleRect.height, content: geometry.contentSize.height)
    }
}

private struct BottomFollowing: ViewModifier {
    @Binding var follow: BottomFollow
    @Binding var position: ScrollPosition
    let driver: SelectionDriver
    let holding: Bool

    private var userMoving: Bool { driver.userScrolling || driver.knobDragging || holding }

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { old, phase, context in
                let user = Self.isUser(phase)
                guard user || Self.isUser(old) else { return }
                driver.userScrolling = user
                apply { $0.userScrolled(to: ScrollExtent(context.geometry)) }
            }
            .onScrollGeometryChange(for: ScrollExtent.self, of: ScrollExtent.init) { old, new in
                if userMoving {
                    apply { $0.userScrolled(to: new) }
                } else {
                    var pin = false
                    apply { pin = $0.layoutChanged(from: old, to: new) }
                    if pin { position.scrollTo(edge: .bottom) }
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(follow.following && !holding ? .bottom : .top, for: .sizeChanges)
            .overlay(alignment: .bottom) {
                if follow.unseen {
                    NewContentPill {
                        follow.jump()
                        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: follow.unseen)
    }

    private static func isUser(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    private func apply(_ change: (inout BottomFollow) -> Void) {
        var next = follow
        change(&next)
        if next != follow { follow = next }
    }
}

struct NewContentPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                Text("New Content")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.text.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.topBar.color, in: Capsule())
            .overlay(Capsule().stroke(Theme.chipStroke.color, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .help("Scroll to the latest output")
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
