import AppKit
import SwiftUI
import TurmCore

struct ShortcutEditor: View {
    let close: () -> Void
    var store = ShortcutStore.shared
    @State private var draft: Shortcut
    @FocusState private var focus: Field?

    private enum Field { case key, name, command }

    init(_ shortcut: Shortcut, close: @escaping () -> Void) {
        self.close = close
        _draft = State(initialValue: shortcut)
    }

    static func directory(at path: String, close: @escaping () -> Void) -> ShortcutEditor {
        let folder = (path as NSString).lastPathComponent
        let shortcut = ShortcutStore.shared.directory(at: path)
            ?? Shortcut(kind: .directory, key: Shortcuts.sanitize(folder).lowercased(), name: folder, value: path)
        return ShortcutEditor(shortcut, close: close)
    }

    private var isNew: Bool { !store.items.contains { $0.id == draft.id } }
    private var cleanKey: String { Shortcuts.sanitize(draft.key) }
    private var shownKey: String { cleanKey.isEmpty ? "shortcut" : cleanKey }
    private var conflict: Shortcut? { Shortcuts.conflict(for: cleanKey, kind: draft.kind, excluding: draft.id, in: store.items) }
    private var hasValue: Bool { !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSave: Bool { !cleanKey.isEmpty && conflict == nil && hasValue }

    private var usage: String {
        let token = String(draft.kind.sigil) + shownKey
        switch draft.kind {
        case .directory: return "Type \(token) to change here, or use it in a command for the path."
        case .command: return "Type \(token) to run this command, or use it inside a longer one."
        case .file: return "Type \(token) in a command to insert the file's path."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(isNew ? "Add" : "Edit") \(draft.kind.title) Shortcut")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            field("Shortcut", hint: usage) {
                HStack(spacing: 2) {
                    Text(String(draft.kind.sigil)).foregroundStyle(Theme.secondaryText.color)
                    TextField("shortcut", text: $draft.key)
                        .focused($focus, equals: .key)
                        .onChange(of: draft.key) { _, new in
                            let cleaned = Shortcuts.sanitize(new)
                            if cleaned != new { draft.key = cleaned }
                        }
                }
            }
            if draft.kind == .command {
                field("Command", hint: "Use {1}, {2} for the words typed after the shortcut, or {@} for all of them.") {
                    TextField("git checkout {1}", text: $draft.value, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focus, equals: .command)
                        .padding(.vertical, 5)
                }
            } else {
                field(draft.kind == .directory ? "Folder" : "File", hint: nil) {
                    Text(Block.abbreviate(draft.value))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            field("Display name", hint: draft.kind == .directory ? "Shown in place of the path. Leave empty to show \(shownKey)." : "Shown next to the shortcut in lists.") {
                TextField(shownKey, text: $draft.name)
                    .focused($focus, equals: .name)
            }
            if let conflict {
                Text("\(conflict.token) is already used by \(describe(conflict)).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !isNew {
                    Button("Remove") {
                        store.remove(draft.id)
                        close()
                    }
                }
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.inputBackground.color)
        .onAppear { focus = .key }
    }

    private func field<Content: View>(_ title: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText.color)
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chipStroke.color, lineWidth: 1))
            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func describe(_ shortcut: Shortcut) -> String {
        shortcut.kind == .command ? shortcut.value : Block.abbreviate(shortcut.value)
    }

    private func save() {
        guard canSave, store.save(draft) else { return }
        close()
    }
}

enum ShortcutPicker {
    static func choose(_ kind: ShortcutKind) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .directory
        panel.canChooseFiles = kind == .file
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }
}
