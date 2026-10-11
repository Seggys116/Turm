import AppKit
import SwiftUI
import TurmCore

struct PathMenu: View {
    let session: TerminalSession
    let path: String
    let close: () -> Void
    let editShortcut: () -> Void
    var store = ShortcutStore.shared

    var body: some View {
        MenuSurface(width: 220) {
            if let shortcut = store.directory(at: path) {
                MenuRow(title: "Edit Shortcut", symbol: "at", detail: shortcut.token, action: editShortcut)
                MenuRow(title: "Remove Shortcut", symbol: "trash", isDestructive: true) {
                    store.remove(shortcut.id)
                    close()
                }
            } else {
                MenuRow(title: "Add Shortcut...", symbol: "at", action: editShortcut)
            }
            MenuDivider()
            MenuRow(title: session.showsFiles ? "Hide Files" : "Show Files", symbol: "sidebar.left") {
                session.showsFiles.toggle()
                close()
            }
            MenuRow(title: "Open in Finder", symbol: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                close()
            }
            MenuRow(title: "Copy Path", symbol: "doc.on.doc") {
                copyToPasteboard(path)
                close()
            }
            MenuRow(title: "Copy Folder Name", symbol: "textformat") {
                copyToPasteboard((path as NSString).lastPathComponent)
                close()
            }
        }
    }
}

struct BranchMenu: View {
    let session: TerminalSession
    let close: () -> Void
    let create: () -> Void
    @State private var branches: [String]?
    @State private var error: String?
    @State private var switching: String?

    private static let rowHeight: CGFloat = 24
    private static let maxRows = 8

    var body: some View {
        MenuSurface(width: 260) {
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.removed.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MenuDivider()
            }
            list
            MenuDivider()
            MenuRow(title: "New Branch...", symbol: "plus", action: create)
            MenuRow(title: "Copy Branch Name", symbol: "doc.on.doc") {
                if let name = session.git?.branch { copyToPasteboard(name) }
                close()
            }
        }
        .task { branches = await session.branches() }
    }

    @ViewBuilder
    private var list: some View {
        if let branches {
            let rows = CGFloat(min(max(branches.count, 1), Self.maxRows))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(branches, id: \.self) { name in
                        MenuRow(
                            title: name,
                            detail: switching == name ? "switching" : nil,
                            isCurrent: name == session.git?.branch
                        ) { switchTo(name) }
                    }
                }
            }
            .squareScrollbar()
            .frame(height: rows * Self.rowHeight)
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
        }
    }

    private func switchTo(_ name: String) {
        guard name != session.git?.branch, switching == nil else { return }
        switching = name
        error = nil
        Task {
            let failure = await session.switchBranch(to: name)
            switching = nil
            if let failure {
                error = failure
            } else {
                close()
            }
        }
    }
}

struct NewBranchPanel: View {
    let create: (String) async -> String?
    let close: () -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var creating = false
    @FocusState private var focused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Branch")
                .font(.system(size: 13, weight: .medium))
            Text("Creates a branch from the current commit and switches to it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Branch name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)
                .disabled(creating)
                .onSubmit { confirm() }
                .onChange(of: name) { _, _ in error = nil }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SettingsButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: confirm)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || creating)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(Theme.inputBackground.color)
        .onAppear { focused = true }
    }

    private func confirm() {
        guard !trimmed.isEmpty, !creating else { return }
        creating = true
        error = nil
        let requested = trimmed
        Task {
            let failure = await create(requested)
            creating = false
            if let failure {
                error = failure
            } else {
                close()
            }
        }
    }
}
