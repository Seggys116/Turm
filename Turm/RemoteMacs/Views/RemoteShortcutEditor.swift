import SwiftUI
import TurmCore

struct RemoteShortcutEditor: View {
    let session: RemoteMacSession
    let connection: RemoteMacConnection
    let target: RemoteShortcutTarget
    @State private var draft: Shortcut?
    @State private var existing: Shortcut?
    @State private var working = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case key, name, command }

    private var cleanKey: String { Shortcuts.sanitize(draft?.key ?? "") }
    private var shownKey: String { cleanKey.isEmpty ? "shortcut" : cleanKey }

    private var conflict: Shortcut? {
        guard let draft else { return nil }
        return Shortcuts.conflict(for: cleanKey, kind: draft.kind, excluding: draft.id, in: session.shortcuts)
    }

    private var hasValue: Bool { !(draft?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
    private var canSave: Bool { !cleanKey.isEmpty && conflict == nil && hasValue && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current = Binding($draft) {
                editor(current)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.inputBackground.color)
        .task { await load() }
    }

    private func editor(_ draft: Binding<Shortcut>) -> some View {
        let kind = draft.wrappedValue.kind
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(existing == nil ? "Add" : "Edit") \(kind.title) Shortcut on \(session.macName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            field("Shortcut", hint: usage(kind)) {
                HStack(spacing: 2) {
                    Text(String(kind.sigil)).foregroundStyle(Theme.secondaryText.color)
                    TextField("shortcut", text: draft.key)
                        .focused($focus, equals: .key)
                        .onChange(of: draft.wrappedValue.key) { _, new in
                            let cleaned = Shortcuts.sanitize(new)
                            if cleaned != new { draft.wrappedValue.key = cleaned }
                        }
                }
            }
            if kind == .command {
                field("Command", hint: "Use {1}, {2} for the words typed after the shortcut, or {@} for all of them.") {
                    TextField("git checkout {1}", text: draft.value, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focus, equals: .command)
                        .padding(.vertical, 5)
                }
            } else {
                field(kind == .directory ? "Folder" : "File", hint: nil) {
                    Text(draft.wrappedValue.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            field("Display name", hint: kind == .directory ? "Shown in place of the path. Leave empty to show \(shownKey)." : "Shown next to the shortcut in lists.") {
                TextField(shownKey, text: draft.name)
                    .focused($focus, equals: .name)
            }
            if let conflict {
                Text("\(conflict.token) is already used by \(conflict.value).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let existing {
                    Button("Remove") { remove(existing) }
                        .disabled(working)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .buttonStyle(SettingsButtonStyle())
        }
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

    private func usage(_ kind: ShortcutKind) -> String {
        let token = String(kind.sigil) + shownKey
        switch kind {
        case .directory: return "Type \(token) to change here, or use it in a command for the path."
        case .command: return "Type \(token) to run this command, or use it inside a longer one."
        case .file: return "Type \(token) in a command to insert the file's path."
        }
    }

    private func load() async {
        do {
            let info = try await session.shortcutInfo(for: target)
            draft = info.draft
            existing = info.existing
            focus = .key
        } catch {
            fail(error)
            dismiss()
        }
    }

    private func save() {
        guard var entry = draft, canSave else { return }
        entry.key = cleanKey
        working = true
        Task {
            do {
                try await session.save(entry)
                dismiss()
            } catch {
                fail(error)
                working = false
            }
        }
    }

    private func remove(_ shortcut: Shortcut) {
        working = true
        Task {
            do {
                try await session.remove(shortcut)
                dismiss()
            } catch {
                fail(error)
                working = false
            }
        }
    }

    private func fail(_ error: Error) {
        connection.report((error as? RemoteMacRequestError)?.text ?? error.localizedDescription)
    }
}
