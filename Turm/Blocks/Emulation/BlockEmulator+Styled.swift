import Foundation
import SwiftTerm
import TurmCore

extension BlockEmulator {
    /// The block's rows with their cell styles, newest rows first kept until about maxBytes of text is collected.
    func styledLines(maxBytes: Int) -> [StyledLine] {
        let buffer = terminal.buffer
        let trimmed = buffer.totalLinesTrimmed
        var row = trimmed + buffer.yDisp + terminal.rows - 1
        var lines: [StyledLine] = []
        var bytes = 0
        var seenContent = false
        while row >= trimmed, bytes < maxBytes {
            defer { row -= 1 }
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            let styled = styledLine(line)
            if !seenContent {
                guard !styled.runs.isEmpty || styled.wrapped else { continue }
                seenContent = true
            }
            bytes += styled.runs.reduce(2) { $0 + $1.text.utf8.count }
            lines.append(styled)
        }
        return lines.reversed()
    }

    private func styledLine(_ line: BufferLine) -> StyledLine {
        var end = line.count
        while end > 0 {
            let cell = line[end - 1]
            if cell.width != 0 {
                let character = terminal.getCharacter(for: cell)
                let background = cell.attribute.bg
                guard character == " " || character == "\u{0}",
                      background == .defaultInvertedColor || background == .defaultColor
                else { break }
            }
            end -= 1
        }

        var runs: [StyledRun] = []
        var runAttribute = Attribute.empty
        for column in 0..<end {
            let cell = line[column]
            if cell.width == 0 { continue }
            let character = terminal.getCharacter(for: cell)
            let text = String(character == "\u{0}" ? " " : character)
            if !runs.isEmpty, cell.attribute == runAttribute {
                runs[runs.count - 1].text += text
            } else {
                runAttribute = cell.attribute
                runs.append(StyledRun(text: text, style: Self.style(of: cell.attribute)))
            }
        }
        return StyledLine(runs: runs, wrapped: line.isWrapped)
    }

    private static func style(of attribute: Attribute) -> TextStyle {
        TextStyle(
            foreground: color(attribute.fg), background: color(attribute.bg),
            bold: attribute.style.contains(.bold), dim: attribute.style.contains(.dim), italic: attribute.style.contains(.italic),
            underline: attribute.style.contains(.underline) || attribute.underlineStyle != .none,
            blink: attribute.style.contains(.blink), inverse: attribute.style.contains(.inverse),
            hidden: attribute.style.contains(.invisible), strikethrough: attribute.style.contains(.crossedOut)
        )
    }

    private static func color(_ value: Attribute.Color) -> TextStyle.Color {
        switch value {
        case .defaultColor, .defaultInvertedColor: .standard
        case .ansi256(let code): .indexed(code)
        case .trueColor(let red, let green, let blue): .rgb(red, green, blue)
        }
    }
}
