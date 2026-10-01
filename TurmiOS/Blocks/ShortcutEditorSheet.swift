import SwiftUI
import TurmCore

struct ShortcutEditorSheet<Session: BlockSession>: View {
    let session: Session
    let target: ShortcutTarget
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Shortcut?
    @State private var existing: Shortcut?
    @State private var failure: String?
    @State private var working = false
    @FocusState private var keyFocused: Bool

    private var cleanKey: String { Shortcuts.sanitize(draft?.key ?? "") }
    private var shownKey: String { cleanKey.isEmpty ? "shortcut" : cleanKey }
    private var hasValue: Bool { !(draft?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
    private var canSave: Bool { draft != nil && !cleanKey.isEmpty && conflict == nil && hasValue && !working }

    private var conflict: Shortcut? {
        guard let draft else { return nil }
        return Shortcuts.conflict(for: cleanKey, kind: draft.kind, excluding: draft.id, in: session.shortcuts)
    }

    private var title: String {
        guard let draft else { return "Shortcut" }
        return "\(existing == nil ? "Add" : "Edit") \(draft.kind.title) Shortcut"
    }

    var body: some View {
        ChromeScroll {
            if let binding = Binding($draft) {
                editor(binding)
            } else if failure == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            }
            if let failure { note(failure, failure: true) }
        }
        .chromeBar(
            ChromeTopBar(
                title,
                leading: { ChromeBarButton(title: "Cancel", systemImage: "xmark") { dismiss() } },
                trailing: { ChromeBarButton(title: "Save", systemImage: "checkmark", kind: .prominent, action: save).disabled(!canSave) }
            )
        )
        .task { await load() }
        .chromeSheet()
    }

    private func editor(_ draft: Binding<Shortcut>) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                ChromeSection("Shortcut") {
                    ChromeFieldRow("Shortcut") {
                        HStack(spacing: 2) {
                            Text(String(draft.wrappedValue.kind.sigil)).foregroundStyle(Chrome.secondaryText)
                            TextField("shortcut", text: draft.key)
                                .focused($keyFocused)
                                .onChange(of: draft.wrappedValue.key) { _, new in
                                    let cleaned = Shortcuts.sanitize(new)
                                    if cleaned != new { draft.wrappedValue.key = cleaned }
                                }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
                if let conflict {
                    note("\(conflict.token) is already used by \(conflict.value).", failure: true)
                } else {
                    note(usage(draft.wrappedValue), failure: false)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ChromeSection(draft.wrappedValue.kind == .command ? "Command" : "Folder") {
                    if draft.wrappedValue.kind == .command {
                        ChromeFieldRow("Command") {
                            TextField("git checkout {1}", text: draft.value, axis: .vertical)
                                .lineLimit(1...4)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.vertical, 10)
                        }
                    } else {
                        ChromeFieldRow("Folder") {
                            Text(draft.wrappedValue.value).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if draft.wrappedValue.kind == .command {
                    note("Use {1}, {2} for the words typed after the shortcut, or {@} for all of them.", failure: false)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ChromeSection("Display name") {
                    ChromeFieldRow("Name") {
                        TextField(shownKey, text: draft.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                note(
                    draft.wrappedValue.kind == .directory
                        ? "Shown in place of the path. Leave empty to show \(shownKey)." : "Shown next to the shortcut in lists.",
                    failure: false
                )
            }
            if let existing {
                ChromeSection("Shortcut") {
                    ChromeActionRow("Remove Shortcut", systemImage: "trash", role: .destructive) { remove(existing) }
                }
            }
        }
    }

    private func note(_ text: String, failure: Bool) -> some View {
        Text(text)
            .font(Chrome.Typeface.caption)
            .foregroundStyle(failure ? Chrome.failure : Chrome.secondaryText)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func usage(_ shortcut: Shortcut) -> String {
        let token = String(shortcut.kind.sigil) + shownKey
        switch shortcut.kind {
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
            keyFocused = true
        } catch {
            failure = (error as? MacRequestError)?.text ?? error.localizedDescription
        }
    }

    private func save() {
        guard var entry = draft, canSave else { return }
        entry.key = cleanKey
        working = true
        failure = nil
        Task {
            do {
                try await session.save(entry)
                Haptics.confirm()
                dismiss()
            } catch {
                failure = (error as? MacRequestError)?.text ?? error.localizedDescription
                working = false
            }
        }
    }

    private func remove(_ shortcut: Shortcut) {
        working = true
        failure = nil
        Task {
            do {
                try await session.remove(shortcut)
                dismiss()
            } catch {
                failure = (error as? MacRequestError)?.text ?? error.localizedDescription
                working = false
            }
        }
    }
}
