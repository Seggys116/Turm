import AppKit
import SwiftUI

struct PathMenu: View {
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
            MenuRow(title: "Copy Branch Name", symbol: "doc.on.doc") {
                if let name = session.git?.branch { copyToPasteboard(name) }
                close()
            }
        }
        .task { branches = await GitInspector.branches(in: session.directory) }
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
