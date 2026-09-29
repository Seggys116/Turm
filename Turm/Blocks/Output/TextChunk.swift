import AppKit
import CoreText
import Foundation

final class TextChunk: Identifiable {
    let id: Int
    let text: AttributedString
    let string: String
    let length: Int
    let hangs: Bool
    let lineLengths: [Int]
    let isGridAligned: Bool

    init(_ text: AttributedString, id: Int = 0, hangs: Bool = false) {
        self.id = id
        self.text = text
        self.hangs = hangs
        let string = String(text.characters)
        self.string = string
        var length = 0
        var lengths: [Int] = []
        var current = 0
        var plain = true
        var irregular = false
        for unit in string.utf16 {
            length += 1
            if unit == 10 {
                lengths.append(current)
                current = 0
                continue
            }
            current += 1
            if unit < 0x20 || unit == 0x7F {
                irregular = true
            } else if unit >= 0x80 {
                plain = false
            }
        }
        if !hangs { lengths.append(current) }
        self.length = length
        lineLengths = lengths
        isGridAligned = length > 0 && !irregular && (plain || Self.singleCell(text, string))
    }

    func fixedHeight(width: CGFloat) -> CGFloat? {
        let columns = Int((width + 0.001) / TerminalMetrics.cellWidth)
        guard isGridAligned, columns > 0 else { return nil }
        let rows = lineLengths.reduce(0) { $0 + max(1, ($1 + columns - 1) / columns) }
        return ceil(CGFloat(rows) * TerminalMetrics.lineHeight)
    }

    func matches(_ other: TextChunk) -> Bool {
        other === self || (other.hangs == hangs && other.length == length && other.string == string && other.text == text)
    }

    private static let zeroWidth: Set<Unicode.GeneralCategory> = [
        .nonspacingMark, .enclosingMark, .format, .control, .lineSeparator, .paragraphSeparator,
        .surrogate, .privateUse, .unassigned,
    ]

    private static func singleCell(_ text: AttributedString, _ string: String) -> Bool {
        for scalar in string.unicodeScalars where scalar.value >= 0x80 {
            if scalar.value > 0xFFFF || zeroWidth.contains(scalar.properties.generalCategory) { return false }
        }
        // a glyph missing from its run's font falls back to another font with its own metrics
        for (style, range) in text.runs[FontStyleKey.self] {
            var units = Array(Set(text[range].characters.lazy.flatMap(\.utf16).filter { $0 >= 0x80 }))
            guard !units.isEmpty else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let font = style.map { TerminalFonts.font(for: $0) } ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return false }
        }
        return true
    }
}

struct OutputText {
    let chunks: [TextChunk]
    let starts: [Int]
    let length: Int

    init(_ chunks: [TextChunk]) {
        self.chunks = chunks
        var starts: [Int] = []
        var offset = 0
        for chunk in chunks {
            starts.append(offset)
            offset += chunk.length
        }
        self.starts = starts
        length = offset
    }

    init(_ text: AttributedString) {
        self.init([TextChunk(text)])
    }

    var string: String {
        chunks.count == 1 ? chunks[0].string : chunks.map(\.string).joined()
    }

    var attributed: AttributedString {
        guard chunks.count != 1 else { return chunks[0].text }
        var joined = AttributedString()
        for chunk in chunks { joined.append(chunk.text) }
        return joined
    }

    var isEmpty: Bool {
        length == 0
    }
}
