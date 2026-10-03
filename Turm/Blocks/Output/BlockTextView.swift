import AppKit
import SwiftUI

struct BlockTextView: NSViewRepresentable {
    let chunk: TextChunk
    var highlights = SegmentHighlights(ranges: [], active: nil)
    var piece: PieceRef?
    var selection: NSRange?
    var cursor: OutputCursor?
    var cursorFocused = false

    func makeNSView(context: Context) -> BlockTextNSView {
        BlockTextNSView()
    }

    func updateNSView(_ view: BlockTextNSView, context: Context) {
        view.setChunk(chunk)
        view.setHighlights(highlights)
        view.setSelection(selection)
        view.setCursor(cursor, focused: cursorFocused)
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
    private var chunk: TextChunk?
    private var isMaterialized = false
    private var blinkTimer: Timer?
    private var blinkStart = Date()
    private var cachedFit: (width: CGFloat, size: CGSize)?
    private var boundPiece: PieceRef?
    private var cursor: OutputCursor?
    private var cursorFocused = false
    private var cursorLit = true
    private var cursorTimer: Timer?
    private var invertedRange: NSRange?

    init() {
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        let manager = UnderlineLayoutManager()
        manager.allowsNonContiguousLayout = true
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

    var textLength: Int {
        chunk?.length ?? 0
    }

    func setChunk(_ next: TextChunk) {
        if let chunk, chunk.matches(next) {
            self.chunk = next
            return
        }
        chunk = next
        cachedFit = nil
        isMaterialized = false
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func materialize() {
        guard !isMaterialized, let storage = textStorage else { return }
        isMaterialized = true
        clearCursorGlyph()
        storage.setAttributedString(chunk.map { Self.display($0.text) } ?? NSAttributedString())
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
        refreshCursorGlyph()
        needsDisplay = true
    }

    private static let wrapping: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        return style
    }()

    // wraps at the cell like a terminal; spaces become no-break spaces so they cannot hang past the edge
    static func display(_ text: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: NSAttributedString.terminalText(text))
        let whole = NSRange(location: 0, length: result.length)
        result.beginEditing()
        result.mutableString.replaceOccurrences(of: " ", with: "\u{00A0}", options: .literal, range: whole)
        result.addAttribute(.paragraphStyle, value: wrapping, range: whole)
        result.endEditing()
        return result
    }

    override func viewWillDraw() {
        materialize()
        super.viewWillDraw()
    }

    // non-contiguous layout only covers the visible rect NSTextView tracks, which goes stale inside a SwiftUI scroll view
    override func draw(_ dirtyRect: NSRect) {
        materialize()
        if let container = textContainer { layout.ensureLayout(for: container) }
        let frame = cursor.flatMap(cursorRect)
        if let frame, let cursor, cursor.shape == .block, cursorLit, isCursorSolid, invertedRange == nil {
            Theme.text.dynamicNS.setFill()
            frame.fill()
        }
        super.draw(dirtyRect)
        if let frame, let cursor { drawCursorMark(cursor, in: frame) }
    }

    func setCursor(_ next: OutputCursor?, focused: Bool) {
        guard next != cursor || focused != cursorFocused else { return }
        cursor = next
        cursorFocused = focused
        cursorLit = true
        cursorTimer?.invalidate()
        cursorTimer = nil
        updateCursorTimer()
        refreshCursorGlyph()
        needsDisplay = true
    }

    private var isCursorSolid: Bool {
        cursorFocused && window?.isKeyWindow == true
    }

    private func lineStart(_ line: Int, in chunk: TextChunk) -> Int {
        chunk.lineLengths.prefix(line).reduce(0, +) + line
    }

    private func cursorCharacterRange(_ cursor: OutputCursor) -> NSRange? {
        guard let chunk, let storage = textStorage, let offset = cursor.offset, cursor.line < chunk.lineLengths.count,
              offset < chunk.lineLengths[cursor.line]
        else { return nil }
        let index = lineStart(cursor.line, in: chunk) + offset
        guard index < storage.length else { return nil }
        return (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
    }

    private func cursorRect(_ cursor: OutputCursor) -> NSRect? {
        guard let chunk, let container = textContainer, let storage = textStorage, cursor.line < chunk.lineLengths.count
        else { return nil }
        let cellWidth = TerminalMetrics.cellWidth
        if let range = cursorCharacterRange(cursor) {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            let fragment = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let glyph = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return NSRect(x: glyph.minX, y: fragment.minY, width: max(glyph.width, cellWidth), height: fragment.height)
        }
        let start = lineStart(cursor.line, in: chunk)
        var anchor = start < storage.length
            ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            : layout.extraLineFragmentRect
        if anchor.height <= 0 {
            anchor = NSRect(x: 0, y: start == 0 ? 0 : layout.usedRect(for: container).maxY, width: 0, height: TerminalMetrics.lineHeight)
        }
        let columns = max(Int((bounds.width + 0.001) / cellWidth), 1)
        return NSRect(
            x: CGFloat(cursor.cell % columns) * cellWidth, y: anchor.minY + CGFloat(cursor.cell / columns) * anchor.height,
            width: cellWidth, height: anchor.height
        )
    }

    private func drawCursorMark(_ cursor: OutputCursor, in frame: NSRect) {
        Theme.text.dynamicNS.set()
        guard isCursorSolid else {
            let outline = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            return
        }
        guard cursorLit else { return }
        switch cursor.shape {
        case .block: break
        case .bar: NSRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height).fill()
        case .underline: NSRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2).fill()
        }
    }

    // a solid block shows the character beneath it in the background colour, like a terminal
    private func refreshCursorGlyph() {
        guard isMaterialized else { return }
        clearCursorGlyph()
        guard let cursor, cursor.shape == .block, cursorLit, isCursorSolid, let range = cursorCharacterRange(cursor) else { return }
        layout.addTemporaryAttributes(
            [.foregroundColor: Theme.terminalBackground.dynamicNS, .backgroundColor: Theme.text.dynamicNS], forCharacterRange: range
        )
        invertedRange = range
    }

    private func clearCursorGlyph() {
        guard let range = invertedRange else { return }
        invertedRange = nil
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage?.length ?? 0))
        guard clamped.length > 0 else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clamped)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
    }

    private func updateCursorTimer() {
        let active = cursor?.blinks == true && isCursorSolid && (window?.occlusionState.contains(.visible) ?? false)
        guard active else {
            cursorTimer?.invalidate()
            cursorTimer = nil
            if !cursorLit {
                cursorLit = true
                refreshCursorGlyph()
                needsDisplay = true
            }
            return
        }
        guard cursorTimer == nil else { return }
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.cursorLit.toggle()
                self.refreshCursorGlyph()
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    override func accessibilityValue() -> String? {
        materialize()
        return super.accessibilityValue()
    }

    func setHighlights(_ highlights: SegmentHighlights) {
        guard layout.matches != highlights.ranges || layout.activeMatch != highlights.active else { return }
        layout.matches = highlights.ranges
        layout.activeMatch = highlights.active
        needsDisplay = true
    }

    func setSelection(_ range: NSRange?) {
        let clamped = range.map { NSIntersectionRange($0, NSRange(location: 0, length: textLength)) }
        let value = clamped?.length == 0 ? nil : clamped
        guard layout.selection != value else { return }
        layout.selection = value
        needsDisplay = true
    }

    func bind(_ piece: PieceRef?) {
        if let boundPiece, boundPiece.id != piece?.id || boundPiece.slot != piece?.slot {
            boundPiece.host.unregister(boundPiece, view: self)
        }
        boundPiece = piece
        if let piece { piece.host.register(piece, view: self) }
    }

    func insertionOffset(at point: NSPoint) -> Int {
        materialize()
        return characterIndexForInsertion(at: point)
    }

    func characterOffset(at point: NSPoint) -> Int {
        materialize()
        guard let container = textContainer, layout.numberOfGlyphs > 0 else { return 0 }
        let glyph = layout.glyphIndex(for: point, in: container)
        return layout.characterIndexForGlyph(at: glyph)
    }

    func link(at point: NSPoint) -> URL? {
        materialize()
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
        let width = width.flatMap { $0.isFinite ? $0 : nil }
        let proposed = width.map { max($0, 1) } ?? 100_000
        if let cachedFit, cachedFit.width == proposed { return cachedFit.size }
        if width != nil, let height = chunk?.fixedHeight(width: proposed) {
            let size = CGSize(width: proposed, height: height)
            cachedFit = (proposed, size)
            return size
        }
        let size = measuredSize(width: width)
        cachedFit = (proposed, size)
        return size
    }

    func measuredSize(width: CGFloat?) -> CGSize {
        let proposed = width.map { max($0, 1) } ?? 100_000
        materialize()
        guard let container = textContainer else { return .zero }
        container.containerSize = NSSize(width: proposed, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        var height = used.height - (chunk?.hangs == true ? layout.extraLineFragmentRect.height : 0)
        if chunk?.length == 0 { height = max(height, TerminalMetrics.lineHeight) }
        return CGSize(width: width == nil ? ceil(used.width) : proposed, height: ceil(height))
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // AppKit scrolls a text view's enclosing scroll view while it lays out; here that is the block list, so it must never move
    override func scrollRangeToVisible(_ range: NSRange) {}

    override func scroll(_ point: NSPoint) {}

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        false
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
        updateCursorTimer()
    }

    @objc private func windowStateChanged() {
        updateBlinkTimer()
        guard cursor != nil else { return }
        updateCursorTimer()
        refreshCursorGlyph()
        needsDisplay = true
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
