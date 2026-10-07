import SwiftUI
import TurmCore

struct TerminalDetail: View {
    let workspace: Workspace
    @Environment(\.splitLayout) private var splitLayout

    var body: some View {
        VStack(spacing: 0) {
            if let tab = workspace.selected {
                VStack(spacing: 0) {
                    TabStrip(workspace: workspace)
                    content(of: tab)
                        .id(tab.id)
                        .transition(.opacity)
                }
            } else {
                EmptyDetail(workspace: workspace)
            }
        }
        .chromeBar(
            ChromeTopBar(
                workspace.selected == nil && !splitLayout ? "Turm" : "",
                leading: {
                    if !splitLayout {
                        SessionsBackButton(workspace: workspace)
                    } else if workspace.sidebarHidden {
                        SidebarToggleButton(workspace: workspace)
                    }
                },
                trailing: {
                    if let tab = workspace.selected { SessionButtons(workspace: workspace, tab: tab) }
                    NewMenuButton(workspace: workspace)
                    SettingsButton(workspace: workspace)
                }
            ),
            clearsCorners: workspace.selected == nil
        )
        .background(Chrome.terminalBackground.ignoresSafeArea())
        .sessionDrop(into: workspace)
    }

    @ViewBuilder
    private func content(of tab: any TerminalTab) -> some View {
        if let ssh = tab as? SSHTerminalSession {
            SessionScreen(session: ssh)
        } else if let mac = tab as? MacSession {
            BlockSessionScreen(session: mac)
        }
    }
}

private struct EmptyDetail: View {
    let workspace: Workspace
    var hosts = SSHHostStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(Chrome.Metrics.margin(for: sizeClass))
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Wordmark()
                Text("Open a shell on a paired Mac, or connect to a server over SSH.")
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(spacing: 10) { actions }
            }
            if !hosts.hosts.isEmpty {
                VStack(spacing: 8) {
                    Text("RECENT HOSTS")
                        .font(Chrome.Typeface.section)
                        .tracking(0.6)
                        .foregroundStyle(Chrome.secondaryText)
                    ForEach(hosts.hosts.prefix(4)) { host in
                        Button {
                            Haptics.tap()
                            workspace.open(host)
                        } label: {
                            HostRow(host: host)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: 360, minHeight: 52)
                                .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
                                .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip).stroke(Chrome.chipStroke, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ChromePressStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button { workspace.showsHostPicker = true } label: {
            Label("New Session", systemImage: "plus")
        }
        .buttonStyle(ChromeButtonStyle(kind: .prominent))
        Button { workspace.showsPairing = true } label: {
            Label("Pair a Mac", systemImage: "link")
        }
        .buttonStyle(ChromeButtonStyle())
    }
}

private struct Wordmark: View {
    var body: some View {
        VStack(spacing: 14) {
            Image("TurmMark")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            wordmark
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Turm")
    }

    private var wordmark: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text("Turm")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(Chrome.text)
            RoundedRectangle(cornerRadius: 2)
                .fill(Chrome.accent)
                .frame(width: 22, height: 7)
                .phaseAnimator([1.0, 0.15]) { bar, opacity in
                    bar.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.7)
                }
        }
    }
}

private struct TabStrip: View {
    let workspace: Workspace
    @Environment(\.splitLayout) private var splitLayout
    @State private var atTop = false

    var body: some View {
        ToolbarVerticalEdgeReader { rail in
            strip(rail: rail)
        }
        .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.top < 1 } action: { atTop = $0 }
    }

    // beside a vertical bar the strip reaches the top edge, so its outer end clears the display's corner
    private func strip(rail: HorizontalEdge?) -> some View {
        let leadingCorner = atTop && rail == .trailing && (!splitLayout || workspace.sidebarHidden)
        let trailingCorner = atTop && rail == .leading
        return HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.sessions, id: \.id) { tab in
                            SessionTab(tab: tab, selected: tab.id == workspace.selectedID, workspace: workspace)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: workspace.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy) { proxy.scrollTo(id) }
                }
            }
            Button {
                Haptics.tap()
                workspace.showsHostPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Chrome.text)
                    .frame(width: Chrome.Metrics.target, height: Chrome.Metrics.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChromePressStyle())
            .accessibilityLabel("New Session")
        }
        .padding(.leading, leadingCorner ? Chrome.Metrics.cornerClearance : 0)
        .padding(.trailing, trailingCorner ? Chrome.Metrics.cornerClearance : 0)
        .windowControlsOffset()
        .frame(height: Chrome.Metrics.target)
        .background(Chrome.sidebar.ignoresSafeArea(edges: [.top, .horizontal]))
        .overlay(alignment: .bottom) { Chrome.divider.frame(height: 1) }
    }
}

private struct SessionTab: View {
    let tab: any TerminalTab
    let selected: Bool
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            TabStatusMark(tab: tab, dotSize: 7, markSize: 14)
            Text(tab.title)
                .font(Chrome.Typeface.label)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button {
                Haptics.tap()
                withAnimation(.snappy) { workspace.close(tab) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
        }
        .foregroundStyle(selected ? Chrome.text : Chrome.secondaryText)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 32)
        .background(selected ? Chrome.chipFill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Chrome.chipStroke : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            Haptics.select()
            workspace.select(tab)
        }
        .sessionDrag(tab)
        .chromeContextMenu {
            workspace.windowMenuItems(for: tab) + [
                ChromeMenuItem(title: "Close Session", systemImage: "xmark", role: .destructive) { workspace.close(tab) },
            ]
        }
    }
}

private struct SessionScreen: View {
    let session: SSHTerminalSession
    private let preferences = TerminalPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(session: session)
            ReconnectBanner(session: session)
            IntegrationBanner(session: session)
            ZStack {
                Chrome.terminalBackground.ignoresSafeArea()
                if session.usesBlocks {
                    BlockSessionScreen(session: session)
                } else {
                    TerminalRepresentable(surface: session.surface, fontSize: preferences.fontSize)
                }
            }
        }
        .overlay { SessionPromptView(session: session) }
        .animation(.snappy(duration: 0.25), value: session.prompt == nil)
    }
}

private struct IntegrationBanner: View {
    let session: SSHTerminalSession

    var body: some View {
        if let activity = session.integrationActivity {
            row {
                ProgressView().controlSize(.small)
                Text(activity)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
            }
        } else if let notice = session.integrationNotice {
            row {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Chrome.secondaryText)
                Text(notice.text)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if notice.offersDecline {
                    Button("Never") { session.dismissIntegrationNotice(forever: true) }
                        .buttonStyle(ChromeButtonStyle(compact: true))
                        .accessibilityLabel("Never for This Host")
                }
                Button("Dismiss") { session.dismissIntegrationNotice(forever: false) }
                    .buttonStyle(ChromeButtonStyle(compact: true))
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(Chrome.topBar.ignoresSafeArea(edges: .horizontal))
            .overlay(alignment: .bottom) { Chrome.divider.frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct StatusBar: View {
    let session: SSHTerminalSession

    private var label: (text: String, color: Color) {
        switch session.state {
        case .idle: ("Idle", Chrome.secondaryText)
        case .connecting: ("Connecting", Chrome.warning)
        case .connected: ("Connected", Chrome.success)
        case .disconnected, .failed: ("Offline", Chrome.failure)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(session.subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if case .connecting = session.state {
                ProgressView().controlSize(.mini)
            }
            StatusDot(color: label.color, size: 6)
            Text(label.text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(label.color)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Chrome.statusBar.ignoresSafeArea(edges: .horizontal))
        .overlay(alignment: .bottom) { Chrome.divider.frame(height: 1) }
    }
}

private struct ReconnectBanner: View {
    let session: SSHTerminalSession

    private var message: String? {
        switch session.state {
        case .disconnected(let message), .failed(let message): message
        default: nil
        }
    }

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(Chrome.failure)
                Text(message)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Reconnect") {
                    Haptics.tap()
                    session.reconnect()
                }
                .buttonStyle(ChromeButtonStyle(kind: .prominent, compact: true))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Chrome.topBar.ignoresSafeArea(edges: .horizontal))
            .overlay(alignment: .bottom) { Chrome.divider.frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
