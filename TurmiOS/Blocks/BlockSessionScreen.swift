import SwiftUI
import TurmCore

struct BlockSessionScreen<Session: BlockSession>: View {
    @Bindable var session: Session
    private let preferences = TerminalPreferences.shared

    var body: some View {
        content
            .background(Chrome.terminalBackground.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .sheet(item: $session.editor) { target in
                ShortcutEditorSheet(session: session, target: target)
            }
            .sheet(isPresented: $session.showsBranches) {
                BranchSheet(session: session)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let surface = session.fullScreen {
            TerminalRepresentable(surface: surface, fontSize: preferences.fontSize)
        } else {
            MacBlockList(session: session, fontSize: preferences.fontSize)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if session.acceptsInput {
            MacInputBar(session: session, fontSize: preferences.fontSize)
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch session.banner {
        case .progress(let text):
            note(text, progress: true)
        case .problem(let text, let systemImage):
            note(text, systemImage: systemImage)
        case .notice(let text):
            Button(action: session.dismissNotice) {
                note(text, systemImage: "exclamationmark.circle")
            }
            .buttonStyle(.plain)
        case nil:
            EmptyView()
        }
    }

    private func note(_ text: String, systemImage: String? = nil, progress: Bool = false) -> some View {
        HStack(spacing: 8) {
            if progress { ProgressView().controlSize(.small) }
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(Chrome.text)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Chrome.statusBar.ignoresSafeArea(edges: .horizontal))
        .overlay(alignment: .bottom) { Chrome.divider.frame(height: 1) }
    }
}
