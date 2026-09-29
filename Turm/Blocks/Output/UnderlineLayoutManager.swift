import AppKit

final class UnderlineLayoutManager: NSLayoutManager {
    var blinkAlpha: CGFloat = 1
    var hasBlink = false
    var matches: [NSRange] = []
    var activeMatch: NSRange?
    var selection: NSRange?

    private static let matchFill = ThemeColor(
        light: NSColor(hex: 0xFFD60A, alpha: 0.45), dark: NSColor(hex: 0xD9B300, alpha: 0.42)
    ).dynamicNS
    private static let activeFill = ThemeColor(
        light: NSColor(hex: 0xFF9500, alpha: 0.75), dark: NSColor(hex: 0xFF9F0A, alpha: 0.7)
    ).dynamicNS

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !matches.isEmpty || activeMatch != nil || selection != nil, let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        if let selection, NSIntersectionRange(selection, visible).length > 0 {
            fill(selection, color: .selectedTextBackgroundColor, container: container, origin: origin)
        }
        for range in matches where NSIntersectionRange(range, visible).length > 0 && range != activeMatch {
            fill(range, color: Self.matchFill, container: container, origin: origin)
        }
        if let activeMatch, NSIntersectionRange(activeMatch, visible).length > 0 {
            fill(activeMatch, color: Self.activeFill, container: container, origin: origin)
        }
    }

    private func fill(_ range: NSRange, color: NSColor, container: NSTextContainer, origin: NSPoint) {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        color.setFill()
        enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard hasBlink, blinkAlpha < 1, let storage = textStorage,
              let context = NSGraphicsContext.current?.cgContext
        else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.blink, in: characters) { value, range, _ in
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            context.saveGState()
            if (value as? NSNumber)?.boolValue == true { context.setAlpha(blinkAlpha) }
            super.drawGlyphs(forGlyphRange: glyphs, at: origin)
            context.restoreGState()
        }
    }

    override func drawUnderline(
        forGlyphRange glyphRange: NSRange,
        underlineType underlineVal: NSUnderlineStyle,
        baselineOffset: CGFloat,
        lineFragmentRect lineRect: NSRect,
        lineFragmentGlyphRange lineGlyphRange: NSRange,
        containerOrigin: NSPoint
    ) {
        let index = characterIndexForGlyph(at: glyphRange.location)
        guard let storage = textStorage, index < storage.length,
              storage.attribute(.curlyUnderline, at: index, effectiveRange: nil) as? NSNumber != nil,
              let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil)
        else {
            super.drawUnderline(
                forGlyphRange: glyphRange, underlineType: underlineVal, baselineOffset: baselineOffset,
                lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin
            )
            return
        }
        let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
        let baseline = lineRect.origin.y + location(forGlyphAt: glyphRange.location).y + containerOrigin.y + 2
        let color = storage.attribute(.underlineColor, at: index, effectiveRange: nil) as? NSColor
            ?? storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            ?? NSColor.textColor
        let startX = bounds.minX + containerOrigin.x
        let endX = bounds.maxX + containerOrigin.x
        let period: CGFloat = 4
        let amplitude: CGFloat = 1
        let path = NSBezierPath()
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var x = startX
        path.move(to: NSPoint(x: x, y: baseline + sin(x / period * 2 * .pi) * amplitude))
        while x < endX {
            x = min(x + 0.5, endX)
            path.line(to: NSPoint(x: x, y: baseline + sin(x / period * 2 * .pi) * amplitude))
        }
        color.setStroke()
        path.stroke()
    }
}
