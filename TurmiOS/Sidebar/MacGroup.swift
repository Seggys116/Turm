import SwiftUI
import TurmCore

struct MacGroup: View {
    let workspace: Workspace
    let macs: MacManager
    let connection: MacConnection
    let entry: MacEntry
    @State private var expanded = true
    @State private var creating = false
    @State private var forgetting = false

    private var closeAlert: Binding<Bool> {
        Binding(get: { connection.closeRequest != nil }, set: { if !$0 { connection.closeRequest = nil } })
    }

    var body: some View {
        ChromeGroup {
            header
            if expanded { content }
        }
        .chromeDialog(isPresented: $creating) {
            ChromeDialogSpec(
                title: "New Shell",
                message: "Opens a new shell in Turm on \(connection.name).",
                field: ChromeDialogSpec.Field(placeholder: "Folder (optional)"),
                actions: [
                    ChromeDialogSpec.Action(title: "Cancel", role: .cancel),
                    ChromeDialogSpec.Action(title: "Create") { directory in
                        connection.createShell(directory: directory) { id in
                            workspace.open(connection.session(for: id))
                        }
                    },
                ]
            )
        }
        .chromeDialog(isPresented: closeAlert) {
            let request = connection.closeRequest
            return ChromeDialogSpec(
                title: "Close this shell?",
                message: request?.message,
                actions: [
                    ChromeDialogSpec.Action(title: "Cancel", role: .cancel),
                    ChromeDialogSpec.Action(title: "Close Anyway", role: .destructive) { _ in
                        if let request { connection.closeSession(request.id, force: true) }
                    },
                ]
            )
        }
        .chromeDialog(isPresented: $forgetting) {
            .confirmation(
                title: "Forget \(connection.name)?",
                message: "This device loses access to the Mac. Pair again to reconnect.",
                confirm: "Forget"
            ) { macs.forget(connection.id) }
        }
    }

    private var header: some View {
        ChromeSwipeRow(actions: [
            ChromeSwipeAction(title: "Forget", systemImage: "trash", role: .destructive) { forgetting = true },
        ]) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                MacRow(mac: entry)
            }
            .rowSurface()
            .chromeTap {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            }
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .chromeContextMenu {
                [
                    ChromeMenuItem(title: "Refresh", systemImage: "arrow.clockwise", isEnabled: connection.state == .connected) {
                        connection.refreshSessions()
                    },
                    ChromeMenuItem(title: "Forget This Mac", systemImage: "trash", role: .destructive) { forgetting = true },
                ]
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let advice = connection.updateAdvice {
            Label(advice, systemImage: "arrow.down.app")
                .font(Chrome.Typeface.caption)
                .foregroundStyle(Chrome.warning)
                .multilineTextAlignment(.leading)
                .padding(.leading, 16)
                .rowSurface()
        }
        if let notice = connection.notice {
            Label(notice, systemImage: "exclamationmark.circle")
                .font(Chrome.Typeface.caption)
                .foregroundStyle(Chrome.failure)
                .multilineTextAlignment(.leading)
                .padding(.leading, 16)
                .rowSurface()
                .chromeTap { connection.dismissNotice() }
        }
        switch connection.state {
        case .connected:
            if connection.sessions.isEmpty {
                Text("No shells open")
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.leading, 26)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            ForEach(connection.sessions) { summary in
                ChromeSwipeRow(actions: [
                    ChromeSwipeAction(title: "Close", systemImage: "xmark", role: .destructive) {
                        connection.closeSession(summary.id, force: false)
                    },
                ]) {
                    MacSessionRow(summary: summary)
                        .padding(.leading, 16)
                        .rowSurface(selected: summary.id == workspace.selectedID)
                        .chromeTap { workspace.open(connection.session(for: summary.id)) }
                        .chromeContextMenu {
                            [
                                ChromeMenuItem(title: "Close Session", systemImage: "xmark", role: .destructive) {
                                    connection.closeSession(summary.id, force: false)
                                },
                            ]
                        }
                }
            }
            SidebarAction(title: "New Shell", systemImage: "plus", indent: 16) { creating = true }
        case .failed:
            SidebarAction(title: "Try Again", systemImage: "arrow.clockwise", indent: 16) { connection.start() }
        case .offline, .connecting, .retrying:
            EmptyView()
        }
    }
}

private struct MacSessionRow: View {
    let summary: SessionSummary

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title.isEmpty ? "Shell" : summary.title)
                    .font(Chrome.Typeface.monoBody)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                Text(summary.location)
                    .font(Chrome.Typeface.mono)
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                if let label = summary.remoteLabel, !label.isEmpty {
                    ChromeTag(text: label)
                }
            }
            Spacer(minLength: 8)
            ActivityBadge(activity: summary.activity, phase: summary.phase)
        }
    }
}

struct ActivityBadge: View {
    let activity: CompanionActivity
    let phase: CompanionPhase

    var body: some View {
        switch activity {
        case .working:
            ProgressView().controlSize(.small)
        case .progress(let percent):
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Chrome.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Chrome.failure)
        case .inactive:
            if phase == .running {
                Image(systemName: "ellipsis").foregroundStyle(Chrome.secondaryText)
            }
        }
    }
}
