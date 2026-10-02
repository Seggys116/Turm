import SwiftUI
import TurmCore

struct RemoteMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("Remote Macs") { openWindow(id: RemoteMacsWindow.id) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

extension RemoteMacConnection {
    var statusText: String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .offline: "Not connected"
        case .retrying(let reason), .failed(let reason): reason
        }
    }
}

private struct RemoteShellID: Hashable {
    let mac: UUID
    let shell: UUID
}

struct RemoteMacsWindow: View {
    static let id = "remote-macs"

    var manager = RemoteMacManager.shared
    @State private var selection: RemoteShellID?
    @State private var pairing = false
    @State private var preselected: DiscoveredRemoteMac?
    @State private var creating: RemoteMacConnection?
    @State private var forgetting: RemoteMacConnection?

    private var nearby: [DiscoveredRemoteMac] {
        let paired = Set(manager.connections.map(\.id))
        return manager.discovered.filter { found in
            guard let macID = found.macID else { return true }
            return macID != RemoteMacIdentity.id && !paired.contains(macID)
        }
    }

    private var target: RemoteMacConnection? {
        let chosen = (selection?.mac.uuidString ?? manager.selectedID).flatMap { id in manager.connections.first { $0.id.uuidString == id } }
        let fallback = manager.connections.count == 1 ? manager.connections.first : nil
        return (chosen ?? fallback).flatMap { $0.state == .connected ? $0 : nil }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 520)
        .onChange(of: selection) { _, new in
            if let new { manager.selectedID = new.mac.uuidString }
        }
        .onAppear { manager.beginDiscovery() }
        .onDisappear { manager.endDiscovery() }
        .sheet(isPresented: $pairing) { RemotePairingSheet(preselected: preselected) }
        .sheet(item: $creating) { connection in
            RemoteNewShellSheet(connection: connection) { shell in
                selection = RemoteShellID(mac: connection.id, shell: shell)
            }
        }
        .alert("Forget \(forgetting?.name ?? "this Mac")?", isPresented: Binding(
            get: { forgetting != nil },
            set: { if !$0 { forgetting = nil } }
        )) {
            Button("Forget", role: .destructive) { forgetting.map { manager.forget($0.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac will no longer be able to control it until you pair again.")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(manager.connections) { connection in
                Section {
                    ForEach(connection.sessions) { summary in
                        RemoteShellRow(summary: summary)
                            .tag(RemoteShellID(mac: connection.id, shell: summary.id))
                            .contextMenu {
                                Button("Close Shell") { connection.closeSession(summary.id, force: false) }
                            }
                    }
                } header: {
                    RemoteMacHeader(connection: connection)
                        .modifier(RemoteCloseRequestAlert(connection: connection))
                        .contextMenu {
                            Button("New Shell...") { creating = connection }
                                .disabled(connection.state != .connected)
                            Divider()
                            Button("Forget Mac...") { forgetting = connection }
                        }
                }
            }
            if !nearby.isEmpty {
                Section("Nearby") {
                    ForEach(nearby) { found in
                        HStack {
                            Text(found.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button("Pair") {
                                preselected = found
                                pairing = true
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if manager.connections.isEmpty, nearby.isEmpty {
                ContentUnavailableView(
                    "No Macs Yet", systemImage: "desktopcomputer",
                    description: Text("Pair with another Mac running Turm to control its shells from here.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    preselected = nil
                    pairing = true
                } label: {
                    Label("Pair with a Mac", systemImage: "link.badge.plus")
                }
                .help("Pair with a Mac")
            }
            ToolbarItem {
                Button {
                    creating = target
                } label: {
                    Label("New Shell", systemImage: "plus")
                }
                .help("New shell on the selected Mac")
                .disabled(target == nil)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let connection = manager.connections.first(where: { $0.id == selection.mac }) {
            RemoteShellView(connection: connection, shellID: selection.shell)
                .id(selection)
        } else {
            ContentUnavailableView("No Shell Selected", systemImage: "terminal", description: Text("Choose a shell from a paired Mac."))
        }
    }
}

private struct RemoteMacHeader: View {
    let connection: RemoteMacConnection

    private var tint: Color {
        switch connection.state {
        case .connected: Theme.added.color
        case .failed: Theme.failure.color
        case .offline, .connecting, .retrying: Theme.secondaryText.color
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(connection.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.color)
                    .lineLimit(2)
            }
        }
    }
}

private struct RemoteShellRow: View {
    let summary: SessionSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title)
                    .lineLimit(1)
                Text(summary.location)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            RemoteActivityGlyph(summary: summary)
        }
    }
}

private struct RemoteActivityGlyph: View {
    let summary: SessionSummary
    private let size: CGFloat = 14

    var body: some View {
        Group {
            switch summary.activity {
            case .working:
                if let program = summary.program { pulsing(program) } else { ProgressView().controlSize(.mini) }
            case .progress(let percent):
                if let program = summary.program {
                    pulsing(program)
                } else {
                    ZStack {
                        Circle().stroke(Theme.subtleDivider.color, lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: percent / 100)
                            .stroke(Theme.added.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(1)
                }
            case .succeeded:
                marker(Theme.added.color)
            case .failed:
                marker(Theme.failure.color)
            case .inactive:
                if summary.phase == .running {
                    ProgressView().controlSize(.mini)
                } else {
                    dot(Theme.secondaryText.color)
                }
            }
        }
        .frame(width: size, height: size)
        .help(summary.program.map { $0.name + (summary.phase == .running ? ", running" : "") } ?? (summary.phase == .running ? "Running" : ""))
    }

    private func pulsing(_ program: RunningProgram) -> some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            ProgramGlyph(program, size: size)
                .foregroundStyle(Theme.text.color)
                .opacity(0.65 + 0.35 * (0.5 + 0.5 * sin(phase * 2 * .pi)))
        }
    }

    @ViewBuilder
    private func marker(_ color: Color) -> some View {
        if let program = summary.program {
            ProgramGlyph(program, size: size).foregroundStyle(color)
        } else {
            dot(color)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: size * 0.6, height: size * 0.6)
    }
}

private struct RemoteCloseRequestAlert: ViewModifier {
    let connection: RemoteMacConnection

    func body(content: Content) -> some View {
        content.alert("Close this shell?", isPresented: Binding(
            get: { connection.closeRequest != nil },
            set: { if !$0 { connection.closeRequest = nil } }
        ), presenting: connection.closeRequest) { request in
            Button("Close", role: .destructive) { connection.closeSession(request.id, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

private struct RemoteNewShellSheet: View {
    let connection: RemoteMacConnection
    let created: (UUID) -> Void
    @State private var directory = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New shell on \(connection.name)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            TextField("Folder (optional)", text: $directory)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SettingsButtonStyle())
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.inputBackground.color)
    }

    private func create() {
        connection.createShell(directory: directory, created: created)
        dismiss()
    }
}
