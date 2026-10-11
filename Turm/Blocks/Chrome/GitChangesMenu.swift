import SwiftUI
import TurmCore

enum GitPanel: Identifiable {
    case diff(staged: Bool)
    case commit(push: Bool)

    var id: String {
        switch self {
        case .diff(let staged): staged ? "staged" : "diff"
        case .commit(let push): push ? "commit-push" : "commit"
        }
    }
}

struct GitChangesMenu: View {
    let session: TerminalSession
    let close: () -> Void
    let open: (GitPanel) -> Void
    var onOpenInPane: () -> Void = {}

    private var shellReady: Bool { session.phase == .ready }

    var body: some View {
        MenuSurface(width: 220) {
            MenuRow(title: "View Diff", symbol: "plus.forwardslash.minus") {
                open(.diff(staged: false))
            }
            MenuRow(title: "View Staged Diff", symbol: "checklist") {
                open(.diff(staged: true))
            }
            MenuRow(title: "Open in Pane", symbol: "rectangle.split.2x1") {
                close()
                onOpenInPane()
            }
            MenuDivider()
            MenuRow(title: "Commit...", symbol: "checkmark") {
                open(.commit(push: false))
            }
            .disabled(!shellReady)
            MenuRow(title: "Commit & Push...", symbol: "arrow.up.circle") {
                open(.commit(push: true))
            }
            .disabled(!shellReady)
            MenuDivider()
            MenuRow(title: "Push", symbol: "arrow.up") {
                close()
                session.pushChanges()
            }
            .disabled(!shellReady)
            MenuRow(title: "Pull", symbol: "arrow.down") {
                close()
                session.pullChanges()
            }
            .disabled(!shellReady)
        }
    }
}

struct CommitPanel: View {
    let pushes: Bool
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var message = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pushes ? "Commit & Push" : "Commit")
                .font(.system(size: 13, weight: .medium))
            Text("Stages every change in this repository, then commits\(pushes ? " and pushes" : "").")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Message", text: $message)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)
                .onSubmit { confirm() }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SettingsButtonStyle())
                Button(pushes ? "Commit & Push" : "Commit", action: confirm)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.inputBackground.color)
        .onAppear { focused = true }
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        commit(trimmed)
    }
}

struct GitDiffPanel: View {
    let session: TerminalSession
    let staged: Bool
    var embedded = false
    var onOpenInPane: (() -> Void)?
    @State private var document: GitDiffDocument?
    @State private var failed = false
    @State private var openFiles: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !embedded {
                HStack {
                    Text(staged ? "Staged diff" : "Diff")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if let onOpenInPane {
                        Button("Open in Pane", action: onOpenInPane)
                            .buttonStyle(SettingsButtonStyle())
                    }
                }
            }
            Group {
                if let document {
                    if document.files.isEmpty {
                        Text("No changes")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText.color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(document.files) { file in
                                    fileView(file)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .squareScrollbar()
                    }
                } else if failed {
                    Text("Could not read the diff")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.removed.color)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: embedded ? nil : 560, height: embedded ? nil : 420)
        .background(Theme.inputBackground.color)
        .task { await load() }
    }

    private func fileView(_ file: GitDiffFile) -> some View {
        let open = openFiles.contains(file.id)
        let counts = changeCounts(file)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { openFiles.remove(file.id) } else { openFiles.insert(file.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText.color)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(file.path)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if file.status == .binary {
                        Text("Binary")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondaryText.color)
                    } else {
                        HStack(spacing: 6) {
                            Text("+\(counts.added)")
                                .foregroundStyle(Theme.added.color)
                            Text("-\(counts.removed)")
                                .foregroundStyle(Theme.removed.color)
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Rectangle().fill(Theme.chipStroke.color).frame(height: 1)
                if file.status == .binary {
                    Text("Binary file changed")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText.color)
                        .padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { hunk in
                            hunkView(hunk)
                        }
                        if file.truncated {
                            Text("Showing the first part of this file")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText.color)
                                .padding(10)
                        }
                    }
                    .padding(.vertical, 2)
                    .background(Theme.terminalBackground.color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chipFill.color)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chipStroke.color, lineWidth: 1))
    }

    private func hunkView(_ hunk: GitHunk) -> some View {
        let marks = GitDiffParser.inlineChanges(for: hunk.lines)
        return VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText.color)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(Theme.chipFill.color)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 0) {
                    Text(prefix(line.kind))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                        .frame(width: 28)
                    Text(lineText(line, emphasis: marks[index]))
                        .foregroundStyle(Theme.text.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 18)
                .background(color(line.kind).opacity(line.kind == .context ? 0 : 0.16))
            }
        }
    }

    private func changeCounts(_ file: GitDiffFile) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for hunk in file.hunks {
            for line in hunk.lines {
                if line.kind == .added { added += 1 }
                if line.kind == .removed { removed += 1 }
            }
        }
        return (added, removed)
    }

    private func lineText(_ line: GitDiffLine, emphasis: [Range<String.Index>]) -> AttributedString {
        let regular = AttributeContainer.font(.system(size: 11, design: .monospaced))
        var strong = AttributeContainer.font(.system(size: 11, weight: .bold, design: .monospaced))
        if line.kind != .context {
            strong.backgroundColor = color(line.kind).opacity(0.34)
        }
        var result = AttributedString()
        var cursor = line.text.startIndex
        for range in emphasis where range.lowerBound >= cursor && range.upperBound <= line.text.endIndex {
            if cursor < range.lowerBound {
                result.append(AttributedString(String(line.text[cursor..<range.lowerBound]), attributes: regular))
            }
            result.append(AttributedString(String(line.text[range]), attributes: strong))
            cursor = range.upperBound
        }
        if cursor < line.text.endIndex {
            result.append(AttributedString(String(line.text[cursor..<line.text.endIndex]), attributes: regular))
        }
        return result
    }

    private func prefix(_ kind: GitDiffLineKind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context: ""
        }
    }

    private func color(_ kind: GitDiffLineKind) -> Color {
        switch kind {
        case .added: Theme.added.color
        case .removed: Theme.removed.color
        case .context: Theme.text.color
        }
    }

    private func load() async {
        let text = await session.unifiedDiff(staged: staged)
        if text.isEmpty, session.git == nil {
            failed = true
            return
        }
        document = GitDiffParser.parse(text)
    }
}
