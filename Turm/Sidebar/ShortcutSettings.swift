import SwiftUI
import TurmCore

struct ShortcutSettings: View {
    var store = ShortcutStore.shared
    @State private var editing: UUID?
    @State private var adding: Shortcut?
    @AppStorage(ShortcutSuggestionTracker.enabledKey) private var suggestionsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Suggestions") {
                SettingsFormRow("Suggest shortcuts", detail: "Offer to save folders you open and commands you type often. Turning this off also stops counting them.") {
                    Toggle("Suggest shortcuts", isOn: $suggestionsEnabled)
                        .labelsHidden()
                        .toggleStyle(SquareToggleStyle())
                }
            }
            ForEach(ShortcutKind.allCases) { kind in
                section(kind)
            }
            Text("A command shortcut can take arguments: {1}, {2} and so on insert the words typed after it, and {@} inserts all of them. A project's Turm.json can add shortcuts that only apply inside that project.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
            Text("Shortcuts expand when you press Return. A directory shortcut at the start of a line changes to that folder, and @shortcut/sub/folder reaches below it. Anywhere else, directory and file shortcuts become their quoted path and command shortcuts become the command.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }

    private func section(_ kind: ShortcutKind) -> some View {
        SettingsSection("\(kind.title) Shortcuts  \(kind.sigil)") {
            let items = store.items(of: kind)
            if items.isEmpty {
                SettingsFormRow("None yet", detail: emptyDetail(kind)) { EmptyView() }
            }
            ForEach(items) { shortcut in
                SettingsFormRow(shortcut.token + (shortcut.name.isEmpty ? "" : "  " + shortcut.name), detail: describe(shortcut)) {
                    HStack(spacing: 8) {
                        if shortcut.isMissing({ FileManager.default.fileExists(atPath: $0) }) {
                            Text("Missing")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.failure.color)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.failure.color.opacity(0.6), lineWidth: 1))
                                .help("\(shortcut.value) no longer exists. Use Change... to point it somewhere else.")
                        }
                        Button("Edit") { editing = shortcut.id }
                            .popover(isPresented: isEditing(shortcut.id), arrowEdge: .bottom) {
                                ShortcutEditor(shortcut) { editing = nil }
                            }
                        if kind != .command {
                            Button("Change...") { change(shortcut) }
                        }
                        Button("Remove") { store.remove(shortcut.id) }
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }
            SettingsFormRow(addTitle(kind), detail: nil) {
                Button(kind == .command ? "Add Command..." : kind == .directory ? "Choose Folder..." : "Choose File...") { add(kind) }
                    .buttonStyle(SettingsButtonStyle())
                    .popover(isPresented: isAdding(kind), arrowEdge: .bottom) {
                        if let adding {
                            ShortcutEditor(adding) { self.adding = nil }
                        }
                    }
            }
        }
    }

    private func emptyDetail(_ kind: ShortcutKind) -> String {
        switch kind {
        case .directory: "Click the folder chip above the input and choose Add Shortcut, or choose a folder here."
        case .command: "Save a command you run often and type !shortcut to run it."
        case .file: "Choose a file and type #shortcut in any command to use its path."
        }
    }

    private func addTitle(_ kind: ShortcutKind) -> String {
        switch kind {
        case .directory: "Add a folder"
        case .command: "Add a command"
        case .file: "Add a file"
        }
    }

    private func describe(_ shortcut: Shortcut) -> String {
        shortcut.kind == .command ? shortcut.value : Block.abbreviate(shortcut.value)
    }

    private func isEditing(_ id: UUID) -> Binding<Bool> {
        Binding(get: { editing == id }, set: { if !$0, editing == id { editing = nil } })
    }

    private func isAdding(_ kind: ShortcutKind) -> Binding<Bool> {
        Binding(get: { adding?.kind == kind }, set: { if !$0, adding?.kind == kind { adding = nil } })
    }

    private func add(_ kind: ShortcutKind) {
        guard kind != .command else {
            adding = Shortcut(kind: .command, key: "", name: "", value: "")
            return
        }
        guard let path = ShortcutPicker.choose(kind) else { return }
        if kind == .directory, let existing = store.directory(at: path) {
            editing = existing.id
            return
        }
        let name = (path as NSString).lastPathComponent
        let base = kind == .file ? (name as NSString).deletingPathExtension : name
        adding = Shortcut(kind: kind, key: Shortcuts.sanitize(base).lowercased(), name: kind == .directory ? name : "", value: path)
    }

    private func change(_ shortcut: Shortcut) {
        guard let path = ShortcutPicker.choose(shortcut.kind) else { return }
        var updated = shortcut
        updated.value = path
        store.save(updated)
    }
}
