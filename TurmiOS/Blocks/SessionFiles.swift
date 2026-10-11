import SwiftUI
import TurmCore
import UIKit
import UniformTypeIdentifiers

struct SessionFilesSheet<Session: BlockSession>: View {
    let session: Session
    let root: String
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var entries: [RemoteFileEntry]?
    @State private var failure: String?
    @State private var preview: Preview?
    @State private var importing = false
    @State private var sending = false

    init(session: Session, root: String) {
        self.session = session
        self.root = root
        _path = State(initialValue: root)
    }

    var body: some View {
        ChromeScroll {
            if let failure {
                Text(failure)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.failure)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sending {
                ProgressView("Sending…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            if let entries {
                if shown.isEmpty {
                    Text(entries.isEmpty ? "This folder is empty." : "Nothing matches.")
                        .font(Chrome.Typeface.caption)
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 6)
                } else {
                    ChromeSection(PathDisplay.abbreviate(path)) {
                        ForEach(shown, id: \.name) { entry in row(entry) }
                    }
                }
            } else if failure == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
        .chromeBar(ChromeTopBar(
            "Files",
            subtitle: (path as NSString).lastPathComponent,
            leading: { leading },
            trailing: { ChromeBarButton(title: "Upload", systemImage: "square.and.arrow.up") { importing = true } }
        ))
        .task(id: path) { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task { await upload(url) }
        }
        .sheet(item: $preview) { item in
            FilePreviewSheet(item: item)
        }
        .chromeSheet()
    }

    @ViewBuilder
    private var leading: some View {
        if path != root {
            ChromeBarButton(title: "Back", systemImage: "chevron.left") {
                path = (path as NSString).deletingLastPathComponent
            }
        } else {
            ChromeBarButton(title: "Done", systemImage: "checkmark") { dismiss() }
        }
    }

    private var shown: [RemoteFileEntry] {
        let visible = (entries ?? []).filter { !$0.name.hasPrefix(".") }
        let folders = visible.filter(\.isDirectory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let files = visible.filter { !$0.isDirectory }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders + files
    }

    private func row(_ entry: RemoteFileEntry) -> some View {
        Button {
            let child = (path as NSString).appendingPathComponent(entry.name)
            if entry.isDirectory {
                path = child
            } else {
                Task { await open(entry, at: child) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .foregroundStyle(Chrome.secondaryText)
                Text(entry.name)
                    .font(Chrome.Typeface.monoBody)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }

    private func load() async {
        failure = nil
        entries = nil
        do {
            entries = try await session.listFiles(in: path)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func open(_ entry: RemoteFileEntry, at child: String) async {
        do {
            let data = try await session.readFile(at: child)
            if let image = UIImage(data: data) {
                preview = Preview(name: entry.name, image: image, text: nil)
                return
            }
            if !data.contains(0), let text = String(data: data, encoding: .utf8) {
                preview = Preview(name: entry.name, image: nil, text: text)
                return
            }
            failure = "This file can’t be previewed."
        } catch {
            failure = error.localizedDescription
        }
    }

    private func upload(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        sending = true
        defer { sending = false }
        do {
            let data = try Data(contentsOf: url)
            try await session.upload(data: data, named: url.lastPathComponent, to: path)
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct Preview: Identifiable {
    let name: String
    let image: UIImage?
    let text: String?
    var id: String { name }
}

private struct FilePreviewSheet: View {
    let item: Preview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let image = item.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text = item.text {
                ScrollView {
                    Text(text)
                        .font(Chrome.Typeface.monoBody)
                        .foregroundStyle(Chrome.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .textSelection(.enabled)
                }
            }
        }
        .background(Chrome.terminalBackground.ignoresSafeArea())
        .chromeBar(ChromeTopBar(item.name, leading: { ChromeBarButton(title: "Done", systemImage: "checkmark") { dismiss() } }, trailing: { EmptyView() }))
        .chromeSheet()
    }
}
