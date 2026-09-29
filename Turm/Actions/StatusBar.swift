import AppKit
import SwiftUI

/// Project actions for the shell's working directory. The pane only shows it when a project or Turm.json was found.
struct StatusBar: View {
    let session: TerminalSession
    @State private var menuOpen = false

    private static let inlineLimit = 6

    private var canRun: Bool { session.phase == .ready }

    var body: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                left(titles: true, kinds: true)
                left(titles: false, kinds: true)
                left(titles: false, kinds: false)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Theme.statusBar.color)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
    }

    private func left(titles: Bool, kinds: Bool) -> some View {
        HStack(spacing: 4) {
            if kinds, !session.project.kinds.isEmpty {
                Text(session.project.kinds.joined(separator: "  "))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 4)
            }
            ForEach(session.project.featured.prefix(Self.inlineLimit)) { action in
                BarButton(
                    symbol: action.displaySymbol,
                    title: titles ? action.title : nil,
                    isEnabled: canRun,
                    help: session.project.commandLine(for: action, selection: session.variantChoices, from: session.directory)
                ) { session.run(action) }
            }
            ForEach(session.project.variants) { variant in
                VariantChip(variant: variant, index: session.variantChoices[variant.id]) { session.cycle(variant) }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var trailing: some View {
        if let notice = session.project.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.removed.color)
                .lineLimit(1)
                .help(notice)
        }
        if session.isRunning {
            if let command = session.current?.command {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240)
            }
            BarButton(symbol: "stop.fill", title: "Stop", tint: Theme.removed.color, isEnabled: true, help: "Interrupt the running command") {
                session.interrupt()
            }
        }
        BarButton(symbol: "ellipsis", title: nil, isActive: menuOpen, isEnabled: true, help: "All project actions") {
            menuOpen.toggle()
        }
        .anchoredMenu(isOpen: $menuOpen) {
            ProjectActionsMenu(session: session) { menuOpen = false }
        }
    }
}

private struct BarButton: View {
    let symbol: String
    var title: String?
    var tint: Color?
    var isActive = false
    let isEnabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                if let title {
                    Text(title).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(tint ?? Theme.text.color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isActive ? 0.22 : hovering && isEnabled ? 0.16 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct VariantChip: View {
    let variant: ProjectVariant
    let index: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let option = variant.option(at: index)
        Button(action: action) {
            HStack(spacing: 3) {
                Text(option.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.text.color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(hovering ? 0.7 : 0), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.chipStroke.color, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("\(variant.title): \(option.label). Click to switch.")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct ProjectActionsMenu: View {
    let session: TerminalSession
    let close: () -> Void

    private static let rowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 24
    private static let maxHeight: CGFloat = 360

    var body: some View {
        let project = session.project
        let groups = project.grouped()
        let rows = project.actions.count + project.variants.count + 1
        let height = CGFloat(rows) * Self.rowHeight + CGFloat(groups.count + (project.variants.isEmpty ? 0 : 1)) * Self.headerHeight
        MenuSurface(width: 300) {
            if let notice = project.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.removed.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MenuDivider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !project.variants.isEmpty {
                        header("Options")
                        ForEach(project.variants) { variant in
                            MenuRow(
                                title: variant.title,
                                symbol: "arrow.triangle.2.circlepath",
                                detail: variant.option(at: session.variantChoices[variant.id]).label
                            ) { session.cycle(variant) }
                        }
                    }
                    ForEach(groups, id: \.category) { group in
                        header(group.category.title)
                        ForEach(group.actions) { action in
                            MenuRow(title: action.title, symbol: action.displaySymbol) {
                                session.run(action)
                                close()
                            }
                            .disabled(session.phase != .ready)
                        }
                    }
                    manifestRow
                }
            }
            .frame(height: min(height, Self.maxHeight))
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.secondaryText.color)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
            .frame(height: Self.headerHeight, alignment: .bottomLeading)
    }

    @ViewBuilder
    private var manifestRow: some View {
        if let path = session.project.manifestPath {
            MenuRow(title: "Edit Turm.json", symbol: "doc.badge.gearshape") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                close()
            }
        } else {
            MenuRow(title: "Create Turm.json", symbol: "doc.badge.plus") {
                createManifest()
                close()
            }
        }
    }

    private func createManifest() {
        let root = session.project.roots.first ?? session.directory
        let url = URL(fileURLWithPath: root).appendingPathComponent(ProjectManifest.fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try ProjectManifest.template.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}
