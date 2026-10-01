import SwiftUI
import TurmCore
import UIKit

extension View {
    func chipStyle() -> some View {
        font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(Chrome.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Chrome.chipStroke, lineWidth: 1))
    }
}

struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if width.isFinite { size.width = min(size.width, width) }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), frames)
    }
}

struct FolderChip<Session: BlockSession>: View {
    let session: Session
    let path: String
    let label: String

    var body: some View {
        ChromeMenuTrigger(items: items) {
            HStack(spacing: 4) {
                Image(systemName: "folder").imageScale(.small)
                Text(label).lineLimit(1).truncationMode(.head)
            }
            .chipStyle()
            .contentShape(Rectangle().inset(by: -6))
        }
        .accessibilityLabel("Folder \(label)")
    }

    private func items() -> [ChromeMenuItem] {
        var items: [ChromeMenuItem] = []
        if session.supportsShortcuts {
            if let shortcut = session.directoryShortcut(at: path) {
                items.append(ChromeMenuItem(title: "Edit Shortcut", systemImage: "at") {
                    session.editor = ShortcutTarget(kind: .directory(path))
                })
                items.append(ChromeMenuItem(title: "Remove Shortcut", systemImage: "trash", role: .destructive) {
                    session.removeShortcut(shortcut)
                })
            } else {
                items.append(ChromeMenuItem(title: "Add Shortcut...", systemImage: "at") {
                    session.editor = ShortcutTarget(kind: .directory(path))
                })
            }
        }
        let changeDirectory = ChromeMenuItem(title: "cd Here", systemImage: "arrow.turn.down.right", isEnabled: session.phase == .ready) {
            session.changeDirectory(to: path)
        }
        items.append(items.isEmpty ? changeDirectory : changeDirectory.separatedFromPrevious())
        if let revealTitle = session.revealTitle {
            items.append(ChromeMenuItem(title: revealTitle, systemImage: "folder") { session.reveal(path) })
        }
        items.append(ChromeMenuItem(title: "Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path })
        items.append(ChromeMenuItem(title: "Copy Folder Name", systemImage: "textformat") {
            UIPasteboard.general.string = (path as NSString).lastPathComponent
        })
        return items
    }
}

struct BranchChip<Session: BlockSession>: View {
    let session: Session
    let branch: String

    @ViewBuilder
    var body: some View {
        if session.supportsBranches {
            label
                .chromeTap { session.showsBranches = true }
                .accessibilityLabel("Branch \(branch)")
        } else {
            label.accessibilityLabel("Branch \(branch)")
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").imageScale(.small)
            Text(branch).lineLimit(1).truncationMode(.middle)
        }
        .chipStyle()
    }
}

struct GitStatsChip: View {
    let git: CompanionGit

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc").imageScale(.small)
            Text("\(git.files)")
            Text("\u{2022}").foregroundStyle(Chrome.secondaryText)
            Text("+\(git.added)").foregroundStyle(Color(BlockTheme.added))
            Text("-\(git.removed)").foregroundStyle(Chrome.failure)
        }
        .chipStyle()
    }
}

struct HostChip: View {
    let host: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "network").imageScale(.small)
            Text(host).lineLimit(1)
        }
        .chipStyle()
    }
}
