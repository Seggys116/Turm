import SwiftUI
import TurmCore
import UIKit
import UniformTypeIdentifiers

struct SSHKeysSection: View {
    private let store = SSHIdentityStore.shared
    @State private var importing = false
    @State private var draft: KeyDraft?
    @State private var failure: String?

    var body: some View {
        ChromeSection("SSH Keys", footer: "Private keys are stored in the Keychain. Choose a key for a host when you edit it.") {
            ForEach(store.identities) { identity in
                ChromeSwipeRow(actions: swipeActions(for: identity)) {
                    HStack(spacing: 12) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 14))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.name)
                                .font(Chrome.Typeface.body)
                                .foregroundStyle(Chrome.text)
                                .lineLimit(1)
                            Text(label(for: identity))
                                .font(Chrome.Typeface.caption)
                                .foregroundStyle(Chrome.secondaryText)
                        }
                        Spacer(minLength: 8)
                        ChromeMenuTrigger(items: { menuItems(for: identity) }) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15))
                                .foregroundStyle(Chrome.secondaryText)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Actions for \(identity.name)")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .chromeContextMenu { menuItems(for: identity) }
                }
            }
            ChromeActionRow("Import from Files", systemImage: "folder") { importing = true }
            ChromeActionRow("Paste a Key", systemImage: "doc.on.clipboard") { draft = KeyDraft() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .sheet(item: $draft) { draft in
            KeyImportSheet(draft: draft)
        }
        .chromeDialog(isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            .notice(title: "Could not import the key", message: failure)
        }
    }

    private func copyPublicKey(of identity: SSHIdentity) {
        UIPasteboard.general.string = identity.publicKey
        Haptics.confirm()
    }

    private func menuItems(for identity: SSHIdentity) -> [ChromeMenuItem] {
        var items: [ChromeMenuItem] = []
        if !identity.publicKey.isEmpty {
            items.append(ChromeMenuItem(title: "Copy Public Key", systemImage: "doc.on.doc") { copyPublicKey(of: identity) })
        }
        items.append(ChromeMenuItem(title: "Delete", systemImage: "trash", role: .destructive) { store.remove(identity.id) })
        return items
    }

    private func swipeActions(for identity: SSHIdentity) -> [ChromeSwipeAction] {
        var actions = [ChromeSwipeAction(title: "Delete", systemImage: "trash", role: .destructive) { store.remove(identity.id) }]
        if !identity.publicKey.isEmpty {
            actions.append(ChromeSwipeAction(title: "Copy", systemImage: "doc.on.doc") { copyPublicKey(of: identity) })
        }
        return actions
    }

    private func label(for identity: SSHIdentity) -> String {
        let kind = switch identity.algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case let other where other.hasPrefix("ecdsa-"): "ECDSA"
        default: identity.algorithm
        }
        return kind + "  " + identity.created.formatted(date: .abbreviated, time: .omitted)
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            draft = KeyDraft(name: url.lastPathComponent, text: text)
        } catch {
            failure = "The file is not a text key file."
        }
    }
}

struct KeyDraft: Identifiable {
    let id = UUID()
    var name = ""
    var text = ""
}

private struct KeyImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var text: String
    @State private var passphrase = ""
    @State private var failure: String?

    init(draft: KeyDraft) {
        _name = State(initialValue: draft.name)
        _text = State(initialValue: draft.text)
    }

    private var canImport: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && text.contains("PRIVATE KEY")
    }

    var body: some View {
        ChromeScroll {
            ChromeSection("Name") {
                ChromeFieldRow("Name") {
                    TextField("id_ed25519", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            ChromeSection("Private Key") {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Chrome.text)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .frame(minHeight: 180)
            }
            ChromeSection("Passphrase") {
                ChromeFieldRow("Passphrase") {
                    SecureField("If the key has one", text: $passphrase)
                }
            }
            if let failure {
                Text(failure)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.failure)
                    .padding(.horizontal, 6)
            }
        }
        .chromeBar(
            ChromeTopBar(
                "Import Key",
                leading: { ChromeBarButton(title: "Cancel", systemImage: "xmark") { dismiss() } },
                trailing: {
                    ChromeBarButton(title: "Import", systemImage: "square.and.arrow.down", kind: .prominent, action: importKey)
                        .disabled(!canImport)
                }
            )
        )
        .chromeSheet()
    }

    private func importKey() {
        do {
            _ = try SSHIdentityStore.shared.importKey(
                name: name.trimmingCharacters(in: .whitespaces),
                privateKey: text,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            Haptics.confirm()
            dismiss()
        } catch {
            Haptics.warn()
            failure = error.localizedDescription
        }
    }
}
