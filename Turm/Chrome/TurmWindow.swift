import SwiftUI
import TurmCore

struct TurmWindow<Sidebar: View, Content: View, TopBar: View>: View {
    @Binding var isSidebarVisible: Bool
    var sidebarWidth: CGFloat
    var onSidebarWidth: (CGFloat) -> Void
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var topBar: () -> TopBar
    @ViewBuilder var content: () -> Content

    @AppStorage(CollapsedSidebarMode.topBarKey) private var topBarEnabled = true
    @AppStorage(CollapsedSidebarMode.popOutKey) private var popOutEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The column is laid out docked. It follows `isSidebarVisible`, a beat late when the sidebar is shown, so the top bar can leave first.
    @State private var isDocked: Bool
    @State private var topBarShown: Bool
    @State private var dockTask: Task<Void, Never>?
    @State private var hoverPhase: SidebarHoverPhase = .hidden
    @State private var hoverHideTask: Task<Void, Never>?
    @State private var pointerInEdge = false
    @State private var pointerInPanel = false

    init(
        isSidebarVisible: Binding<Bool>,
        sidebarWidth: CGFloat,
        onSidebarWidth: @escaping (CGFloat) -> Void,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder topBar: @escaping () -> TopBar,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isSidebarVisible = isSidebarVisible
        self.sidebarWidth = sidebarWidth
        self.onSidebarWidth = onSidebarWidth
        self.sidebar = sidebar
        self.topBar = topBar
        self.content = content
        let mode = CollapsedSidebarMode(defaults: .standard)
        _isDocked = State(initialValue: isSidebarVisible.wrappedValue)
        _topBarShown = State(initialValue: !isSidebarVisible.wrappedValue && mode.topBar)
    }

    private var mode: CollapsedSidebarMode { CollapsedSidebarMode(topBar: topBarEnabled, popOut: popOutEnabled) }

    private var reservesTopBand: Bool { !isDocked && mode.topBar }

    private var showsWindowControls: Bool { isDocked || mode.topBar }

    private var dockedColumnWidth: CGFloat {
        sidebarWidth + ChromeMetrics.sidebarResizeHandleWidth
    }

    private var leadingInset: CGFloat {
        isDocked ? ChromeMetrics.contentCardLeadingSeam : ChromeMetrics.cardInset
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.windowBackground.color

            HStack(spacing: 0) {
                if isDocked {
                    HStack(spacing: 0) {
                        sidebar()
                            .frame(width: sidebarWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                        SidebarResizeHandle(width: sidebarWidth, onWidth: onSidebarWidth)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.sidebarCollapse(width: dockedColumnWidth))
                }

                content()
                    .padding(EdgeInsets(
                        top: reservesTopBand ? ChromeMetrics.topRowHeight : ChromeMetrics.cardInset,
                        leading: leadingInset,
                        bottom: ChromeMetrics.cardInset,
                        trailing: ChromeMetrics.cardInset
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !isDocked && mode.topBar {
                topBar()
                    .opacity(topBarShown ? 1 : 0)
                    .allowsHitTesting(topBarShown && !isSidebarVisible)
                    .accessibilityHidden(!topBarShown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .zIndex(1)
            }

            WindowControls()
                .opacity(showsWindowControls ? 1 : 0)
                .allowsHitTesting(showsWindowControls)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(1.5)

            if !isSidebarVisible && mode.popOut {
                hoverLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(ChromeMetrics.motion, value: isDocked)
        .animation(ChromeMetrics.motion, value: mode.topBar)
        .onChange(of: isSidebarVisible) { _, visible in
            hoverHideTask?.cancel()
            hoverHideTask = nil
            pointerInEdge = false
            pointerInPanel = false
            hoverPhase = .hidden
            applyDocking(visible)
        }
        .onChange(of: mode.topBar) { _, enabled in
            withAnimation(.easeOut(duration: 0.18)) { topBarShown = enabled && !isSidebarVisible }
        }
    }

    /// Hiding closes the column first and fades the top bar in once it is gone. Showing fades the top bar out first, then opens the column.
    private func applyDocking(_ visible: Bool) {
        dockTask?.cancel()
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) {
                isDocked = visible
                topBarShown = !visible && mode.topBar
            }
            return
        }
        dockTask = Task { @MainActor in
            if visible {
                withAnimation(.easeOut(duration: 0.1)) { topBarShown = false }
                if mode.topBar { try? await Task.sleep(for: .milliseconds(100)) }
                guard !Task.isCancelled else { return }
                withAnimation(ChromeMetrics.motion) { isDocked = true }
            } else {
                withAnimation(ChromeMetrics.motion) { isDocked = false }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { topBarShown = mode.topBar }
            }
        }
    }

    /// The sidebar slides over the card while it is hidden. The strip at the left edge opens it,
    /// and moving into the panel keeps it up; leaving both, or clicking the card, puts it away.
    private var hoverLayer: some View {
        ZStack(alignment: .leading) {
            SidebarEdgeCatcher(hotZoneWidth: ChromeMetrics.sidebarHoverEdgeWidth) { hovering in
                pointerInEdge = hovering
                updateHover()
            } onClick: {
                withAnimation(ChromeMetrics.motion) { isSidebarVisible = true }
            }
            .frame(width: ChromeMetrics.sidebarHoverEdgeWidth)
            .frame(maxHeight: .infinity, alignment: .leading)
            .zIndex(hoverPhase.showsPanel ? 0 : 1)

            HStack(spacing: 0) {
                sidebar()
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                SidebarResizeHandle(width: sidebarWidth, onWidth: onSidebarWidth)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topLeading) { WindowControls() }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.cardCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: ChromeMetrics.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ChromeMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.28), radius: 16, x: 6, y: 0)
            .background {
                SidebarPanelTracker(isActive: hoverPhase.showsPanel) { inside in
                    pointerInPanel = inside
                    updateHover()
                } onClickOutside: {
                    hideHoverNow()
                }
            }
            .padding(.leading, ChromeMetrics.cardInset / 2)
            .padding(.vertical, ChromeMetrics.cardInset / 2)
            .offset(x: hoverPhase.showsPanel ? 0 : -(sidebarWidth + 48))
            .opacity(hoverPhase.showsPanel ? 1 : 0)
            .allowsHitTesting(hoverPhase.showsPanel)
            .accessibilityHidden(!hoverPhase.showsPanel)
            .zIndex(hoverPhase.showsPanel ? 1 : 0)
        }
    }

    private func updateHover() {
        handleHover(pointerInEdge || pointerInPanel)
    }

    private func handleHover(_ hovering: Bool) {
        if hovering {
            hoverHideTask?.cancel()
            hoverHideTask = nil
            guard hoverPhase != .revealed else { return }
            if hoverPhase == .hidden {
                hoverHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ChromeMetrics.sidebarRevealDelay))
                    guard !Task.isCancelled else { return }
                    withAnimation(ChromeMetrics.motion) { hoverPhase = .revealed }
                }
                return
            }
            withAnimation(ChromeMetrics.motion) { hoverPhase = .revealed }
            return
        }
        guard hoverPhase == .revealed || hoverPhase == .peeking else {
            hoverHideTask?.cancel()
            hoverHideTask = nil
            return
        }
        hoverPhase = .hiding
        hoverHideTask?.cancel()
        hoverHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(ChromeMetrics.sidebarAutoHideDelay))
            guard !Task.isCancelled, hoverPhase == .hiding else { return }
            withAnimation(ChromeMetrics.sidebarHide) { hoverPhase = .hidden }
        }
    }

    private func hideHoverNow() {
        hoverHideTask?.cancel()
        hoverHideTask = nil
        pointerInEdge = false
        pointerInPanel = false
        guard hoverPhase.showsPanel else { return }
        withAnimation(ChromeMetrics.sidebarHide) { hoverPhase = .hidden }
    }
}

private struct SidebarCollapseModifier: ViewModifier, Animatable {
    var progress: Double
    let fullWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clamped = min(max(progress, 0), 1)
        content
            .frame(width: fullWidth, alignment: .leading)
            .frame(width: fullWidth * clamped, alignment: .trailing)
            .clipped()
            .opacity(clamped)
    }
}

extension AnyTransition {
    static func sidebarCollapse(width: CGFloat) -> AnyTransition {
        .modifier(
            active: SidebarCollapseModifier(progress: 0, fullWidth: width),
            identity: SidebarCollapseModifier(progress: 1, fullWidth: width)
        )
    }
}

struct PaneCard: ViewModifier {
    var isSplit: Bool
    var isFocused: Bool
    var corners: PaneCorners

    func body(content: Content) -> some View {
        if isSplit {
            content
                .background(Theme.terminalBackground.color)
                .clipShape(corners.shape)
                .overlay {
                    insideStroke(
                        corners.shape,
                        color: isFocused ? Color.accentColor.opacity(0.9) : Theme.divider.color,
                        width: isFocused ? 2 : 1
                    )
                }
        } else {
            content
        }
    }
}

extension View {
    func paneCard(isSplit: Bool, isFocused: Bool, corners: PaneCorners = PaneCorners(topLeading: 0, bottomLeading: 0, bottomTrailing: 0, topTrailing: 0)) -> some View {
        modifier(PaneCard(isSplit: isSplit, isFocused: isFocused, corners: corners))
    }
}

/// An inside stroke whose outer edge is the shape itself, so the line follows that corner instead of a smaller one.
private func insideStroke<S: Shape>(_ shape: S, color: Color, width: CGFloat) -> some View {
    shape
        .stroke(color, lineWidth: width * 2)
        .mask(shape)
        .allowsHitTesting(false)
}
