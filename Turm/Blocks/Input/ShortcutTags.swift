import AppKit
import SwiftUI

struct ShortcutTag: View {
    enum Content {
        case shortcut(ShortcutReplacement, isMissing: Bool)
        case unknown(String)
    }

    let content: Content
    let primary: () -> Void
    let alternate: () -> Void
    @State private var hovering = false

    static let maxWidth: CGFloat = 320

    private var isMissing: Bool {
        if case .shortcut(_, true) = content { return true }
        return false
    }

    private var symbol: String {
        switch content {
        case let .shortcut(replacement, isMissing): isMissing ? "exclamationmark.triangle" : replacement.match.shortcut.kind.symbol
        case .unknown: hovering ? "plus" : "questionmark.folder"
        }
    }

    private var text: String {
        switch content {
        case let .shortcut(replacement, _):
            if replacement.match.shortcut.kind == .command { return replacement.text.replacingOccurrences(of: "\n", with: " ") }
            return Block.abbreviate(replacement.match.target)
        case .unknown:
            return "no shortcut"
        }
    }

    private var note: String? {
        switch content {
        case let .shortcut(replacement, isMissing): isMissing ? "missing" : replacement.match.shortcut.isProject ? "project" : nil
        case .unknown: nil
        }
    }

    private var tint: Color { isMissing ? Theme.failure.color : Theme.secondaryText.color }

    private var isUnknown: Bool {
        if case .unknown = content { return true }
        return false
    }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) { alternate() } else { primary() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text(text)
                    .foregroundStyle(isUnknown && !hovering ? Theme.secondaryText.color : Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note).foregroundStyle(tint)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .frame(maxWidth: Self.maxWidth)
            .background(isUnknown ? Color.clear : Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(border, style: StrokeStyle(lineWidth: 1, dash: isUnknown && !hovering ? [3, 2] : []))
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
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
        switch content {
        case let .shortcut(replacement, isMissing):
            let full = replacement.match.shortcut.kind == .command ? replacement.text : replacement.match.target
            let state = isMissing ? "\nThis path no longer exists." : ""
            return full + state + "\nClick to select. Option-click to replace it with this text."
        case let .unknown(key):
            return "No shortcut is named @\(key).\nClick to save one."
        }
    }
}

@MainActor
final class ShortcutTagLayer {
    private var hosts: [NSHostingView<ShortcutTag>] = []

    @discardableResult
    func update(
        in view: NSTextView,
        shortcuts: [Shortcut],
        quote: (String) -> String,
        visible: Bool,
        caret: Int?,
        select: @escaping (NSRange) -> Void,
        expand: @escaping (NSRange, String) -> Void,
        save: @escaping (String, NSRange) -> Void
    ) -> Bool {
        let text = view.string
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        var entries: [(token: Range<String.Index>, tag: ShortcutTag)] = []
        if visible {
            for replacement in Shortcuts.replacements(in: text, shortcuts: shortcuts, quote: quote) {
                let whole = NSRange(replacement.range, in: text)
                entries.append((replacement.match.range, ShortcutTag(
                    content: .shortcut(replacement, isMissing: replacement.match.shortcut.isMissing(exists)),
                    primary: { select(whole) },
                    alternate: { expand(whole, replacement.text) }
                )))
            }
            for (key, range) in Shortcuts.unknown(text, in: shortcuts) {
                let token = NSRange(range, in: text)
                // a key still being typed is not missing yet
                if NSMaxRange(token) == caret { continue }
                entries.append((range, ShortcutTag(content: .unknown(key), primary: { save(key, token) }, alternate: { save(key, token) })))
            }
            entries.sort { $0.token.lowerBound < $1.token.lowerBound }
        }
        guard !entries.isEmpty, let window = view.window, let content = window.contentView,
              let layout = view.layoutManager, let container = view.textContainer, let scroll = view.enclosingScrollView
        else {
            clear()
            return false
        }
        let visibleRect = content.convert(scroll.contentView.bounds, from: scroll.contentView)
        let origin = view.textContainerOrigin
        var placed: [NSRect] = []
        var used = 0
        for entry in entries {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(entry.token, in: text), actualCharacterRange: nil)
            var local = layout.boundingRect(forGlyphRange: glyphs, in: container)
            local.origin.x += origin.x
            local.origin.y += origin.y
            let anchor = content.convert(local, from: view)
            guard anchor.intersects(visibleRect) else { continue }
            let host: NSHostingView<ShortcutTag>
            if used < hosts.count {
                host = hosts[used]
                host.rootView = entry.tag
            } else {
                host = NSHostingView(rootView: entry.tag)
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
            if host.superview !== content {
                content.addSubview(host, positioned: .above, relativeTo: nil)
                host.animateEntrance(duration: 0.15, scale: 0.95)
            }
        }
        for host in hosts[used...] { host.removeFromSuperview() }
        hosts.removeSubrange(used...)
        return used > 0
    }

    func clear() {
        hosts.forEach { $0.removeFromSuperview() }
        hosts = []
    }
}

extension NSView {
    func animateEntrance(duration: CFTimeInterval, scale: CGFloat) {
        wantsLayer = true
        guard let layer else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if !still {
            let mid = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            var start = CATransform3DMakeTranslation(mid.x, mid.y, 0)
            start = CATransform3DScale(start, scale, scale, 1)
            start = CATransform3DTranslate(start, -mid.x, -mid.y, 0)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = start
            grow.toValue = CATransform3DIdentity
            animations.append(grow)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "entrance")
    }
}
