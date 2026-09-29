import AppKit
import SwiftUI

struct BlockTextView: NSViewRepresentable {
    let text: AttributedString
    var highlights = SegmentHighlights(ranges: [], active: nil)
    var piece: PieceRef?
    var selection: NSRange?

    func makeNSView(context: Context) -> BlockTextNSView {
        BlockTextNSView()
    }

    func updateNSView(_ view: BlockTextNSView, context: Context) {
        view.setText(text)
        view.setHighlights(highlights)
        view.setSelection(selection)
        view.bind(piece)
    }

    static func dismantleNSView(_ view: BlockTextNSView, coordinator: ()) {
        view.bind(nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: BlockTextNSView, context: Context) -> CGSize? {
        view.fittingSize(width: proposal.width)
    }
}

final class BlockTextNSView: NSTextView {
    private let layout: UnderlineLayoutManager
    private var source: AttributedString?
    private var blinkTimer: Timer?
    private var blinkStart = Date()
    private var cachedFit: (width: CGFloat, size: CGSize)?
    private var boundPiece: PieceRef?

    init() {
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        let manager = UnderlineLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        layout = manager
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isRichText = true
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [:]
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setText(_ text: AttributedString) {
        guard source != text, let storage = textStorage else { return }
        source = text
        cachedFit = nil
        storage.setAttributedString(NSAttributedString.terminalText(text))
        var blinks = false
        storage.enumerateAttribute(.blink, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if (value as? NSNumber)?.boolValue == true {
                blinks = true
                stop.pointee = true
            }
        }
        layout.hasBlink = blinks
        layout.blinkAlpha = 1
        updateBlinkTimer()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func setHighlights(_ highlights: SegmentHighlights) {
        guard layout.matches != highlights.ranges || layout.activeMatch != highlights.active else { return }
        layout.matches = highlights.ranges
        layout.activeMatch = highlights.active
        needsDisplay = true
    }

    func setSelection(_ range: NSRange?) {
        let clamped = range.map { NSIntersectionRange($0, NSRange(location: 0, length: textStorage?.length ?? 0)) }
        let value = clamped?.length == 0 ? nil : clamped
        guard layout.selection != value else { return }
        layout.selection = value
        needsDisplay = true
    }

    func bind(_ piece: PieceRef?) {
        if let boundPiece, boundPiece.id != piece?.id {
            boundPiece.host.unregister(boundPiece.id, view: self)
        }
        boundPiece = piece
        if let piece { piece.host.register(piece.id, view: self) }
    }

    func insertionOffset(at point: NSPoint) -> Int {
        characterIndexForInsertion(at: point)
    }

    func characterOffset(at point: NSPoint) -> Int {
        guard let container = textContainer, layout.numberOfGlyphs > 0 else { return 0 }
        let glyph = layout.glyphIndex(for: point, in: container)
        return layout.characterIndexForGlyph(at: glyph)
    }

    func link(at point: NSPoint) -> URL? {
        guard let container = textContainer, let storage = textStorage, layout.numberOfGlyphs > 0 else { return nil }
        let glyph = layout.glyphIndex(for: point, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func fittingSize(width: CGFloat?) -> CGSize {
        let proposed = width.map { max($0, 1) } ?? 100_000
        if let cachedFit, cachedFit.width == proposed { return cachedFit.size }
        guard let container = textContainer else { return .zero }
        container.containerSize = NSSize(width: proposed, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = CGSize(width: width == nil ? ceil(used.width) : proposed, height: ceil(used.height))
        cachedFit = (proposed, size)
        return size
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                center.addObserver(self, selector: #selector(windowStateChanged), name: name, object: window)
            }
        }
        updateBlinkTimer()
    }

    @objc private func windowStateChanged() {
        updateBlinkTimer()
    }

    private func updateBlinkTimer() {
        let active = layout.hasBlink && (window?.isKeyWindow ?? false) && (window?.occlusionState.contains(.visible) ?? false)
        if active {
            guard blinkTimer == nil else { return }
            blinkStart = Date()
            let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    self.tickBlink()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            if layout.blinkAlpha != 1 {
                layout.blinkAlpha = 1
                needsDisplay = true
            }
        }
    }

    private func tickBlink() {
        let phase = Date().timeIntervalSince(blinkStart) / 1.6
        layout.blinkAlpha = CGFloat(0.575 + 0.425 * cos(phase * 2 * .pi))
        setNeedsDisplay(visibleRect)
    }
}
