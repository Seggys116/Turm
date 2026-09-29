import AppKit
import SwiftUI

struct ShortcutTag: View {
    let replacement: ShortcutReplacement
    let isMissing: Bool
    let select: () -> Void
    let expand: () -> Void
    @State private var hovering = false

    static let maxWidth: CGFloat = 320

    private var shortcut: Shortcut { replacement.match.shortcut }

    private var text: String {
        if shortcut.kind == .command { return replacement.text.replacingOccurrences(of: "\n", with: " ") }
        return Block.abbreviate(replacement.match.target)
    }

    private var tint: Color { isMissing ? Theme.failure.color : Theme.secondaryText.color }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) { expand() } else { select() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isMissing ? "exclamationmark.triangle" : shortcut.kind.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isMissing {
                    Text("missing").foregroundStyle(tint)
                } else if shortcut.isProject {
                    Text("project").foregroundStyle(Theme.secondaryText.color)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.text.color)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .frame(maxWidth: Self.maxWidth)
            .background(Theme.inputBackground.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var border: Color {
        if isMissing { return Theme.failure.color }
        return hovering ? Color.accentColor : Theme.chipStroke.color
    }

    private var help: String {
        let full = shortcut.kind == .command ? replacement.text : replacement.match.target
        let state = isMissing ? "\nThis path no longer exists." : ""
        return full + state + "\nClick to select. Option-click to replace it with this text."
    }
}

@MainActor
final class ShortcutTagLayer {
    private var hosts: [NSHostingView<ShortcutTag>] = []

    func update(
        in view: NSTextView,
        shortcuts: [Shortcut],
        quote: (String) -> String,
        visible: Bool,
        select: @escaping (NSRange) -> Void,
        expand: @escaping (NSRange, String) -> Void
    ) {
        let text = view.string
        let replacements = visible ? Shortcuts.replacements(in: text, shortcuts: shortcuts, quote: quote) : []
        guard !replacements.isEmpty, let window = view.window, let content = window.contentView,
              let layout = view.layoutManager, let container = view.textContainer, let scroll = view.enclosingScrollView
        else {
            clear()
            return
        }
        let visibleRect = content.convert(scroll.contentView.bounds, from: scroll.contentView)
        let origin = view.textContainerOrigin
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        var placed: [NSRect] = []
        var used = 0
        for replacement in replacements {
            let token = NSRange(replacement.match.range, in: text)
            let whole = NSRange(replacement.range, in: text)
            let glyphs = layout.glyphRange(forCharacterRange: token, actualCharacterRange: nil)
            var local = layout.boundingRect(forGlyphRange: glyphs, in: container)
            local.origin.x += origin.x
            local.origin.y += origin.y
            let anchor = content.convert(local, from: view)
            guard anchor.intersects(visibleRect) else { continue }
            let tag = ShortcutTag(
                replacement: replacement,
                isMissing: replacement.match.shortcut.isMissing(exists),
                select: { select(whole) },
                expand: { expand(whole, replacement.text) }
            )
            let host: NSHostingView<ShortcutTag>
            if used < hosts.count {
                host = hosts[used]
                host.rootView = tag
            } else {
                host = NSHostingView(rootView: tag)
                hosts.append(host)
            }
            used += 1
            let size = host.fittingSize
            var x = min(max(anchor.midX - size.width / 2, 4), content.bounds.width - size.width - 4)
            let y = content.isFlipped ? anchor.minY - size.height - 3 : anchor.maxY + 3
            if let last = placed.last, abs(last.minY - y) < 1, x < last.maxX + 4 { x = last.maxX + 4 }
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            placed.append(frame)
            host.frame = frame
            if host.superview !== content { content.addSubview(host, positioned: .above, relativeTo: nil) }
        }
        for host in hosts[used...] { host.removeFromSuperview() }
        hosts.removeSubrange(used...)
    }

    func clear() {
        hosts.forEach { $0.removeFromSuperview() }
        hosts = []
    }
}
