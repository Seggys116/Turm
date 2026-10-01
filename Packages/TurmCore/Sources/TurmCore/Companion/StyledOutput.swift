import Foundation

public nonisolated struct TextStyle: Equatable, Hashable, Sendable {
    public enum Color: Equatable, Hashable, Sendable {
        case standard
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    public var foreground: Color
    public var background: Color
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var blink: Bool
    public var inverse: Bool
    public var hidden: Bool
    public var strikethrough: Bool

    public static let plain = TextStyle()

    public init(
        foreground: Color = .standard, background: Color = .standard, bold: Bool = false, dim: Bool = false, italic: Bool = false,
        underline: Bool = false, blink: Bool = false, inverse: Bool = false, hidden: Bool = false, strikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.blink = blink
        self.inverse = inverse
        self.hidden = hidden
        self.strikethrough = strikethrough
    }

    var parameters: [String] {
        var result: [String] = []
        if bold { result.append("1") }
        if dim { result.append("2") }
        if italic { result.append("3") }
        if underline { result.append("4") }
        if blink { result.append("5") }
        if inverse { result.append("7") }
        if hidden { result.append("8") }
        if strikethrough { result.append("9") }
        result += Self.colorParameters(foreground, base: 30)
        result += Self.colorParameters(background, base: 40)
        return result
    }

    private static func colorParameters(_ color: Color, base: Int) -> [String] {
        switch color {
        case .standard: return []
        case .indexed(let code) where code < 8: return [String(base + Int(code))]
        case .indexed(let code) where code < 16: return [String(base + 60 + Int(code) - 8)]
        case .indexed(let code): return [String(base + 8), "5", String(code)]
        case .rgb(let red, let green, let blue): return [String(base + 8), "2", String(red), String(green), String(blue)]
        }
    }
}

public nonisolated struct StyledRun: Equatable, Sendable {
    public var text: String
    public var style: TextStyle

    public init(text: String, style: TextStyle) {
        self.text = text
        self.style = style
    }
}

/// One terminal row; a wrapped row continues the row before it.
public nonisolated struct StyledLine: Equatable, Sendable {
    public var runs: [StyledRun]
    public var wrapped: Bool

    public init(runs: [StyledRun], wrapped: Bool = false) {
        self.runs = runs
        self.wrapped = wrapped
    }
}

public nonisolated enum StyledOutput {
    /// Encodes rows as SGR-styled text with CRLF between rows, leaving every row in the default style.
    public static func encode(_ lines: [StyledLine]) -> Data {
        var text = ""
        for (index, line) in lines.enumerated() {
            if index > 0, !line.wrapped { text += "\r\n" }
            var current = TextStyle.plain
            for run in line.runs where !run.text.isEmpty {
                if run.style != current {
                    text += sequence(from: current, to: run.style)
                    current = run.style
                }
                text += run.text
            }
            if current != .plain { text += "\u{1B}[0m" }
        }
        return Data(text.utf8)
    }

    private static func sequence(from current: TextStyle, to style: TextStyle) -> String {
        guard style != .plain else { return "\u{1B}[0m" }
        let prefix = current == .plain ? [] : ["0"]
        return "\u{1B}[" + (prefix + style.parameters).joined(separator: ";") + "m"
    }
}
