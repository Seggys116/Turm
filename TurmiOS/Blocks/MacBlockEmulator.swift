import Foundation
import SwiftTerm
import UIKit

final class MacBlockEmulator: TerminalDelegate {
    static let scrollback = 20_000

    private(set) var terminal: Terminal!
    var onProgress: (Terminal.ProgressReport?) -> Void = { _ in }
    var onResponse: (([UInt8]) -> Void)?
    private var styles: [Attribute: [NSAttributedString.Key: Any]] = [:]
    private var settled = NSMutableAttributedString()
    private var settledLengths: [Int] = []
    private var settledBase = 0
    private var cachedBuffer: ObjectIdentifier?
    private var latest = NSAttributedString()
    private static let newline = NSAttributedString(string: "\n")

    init(cols: Int, rows: Int) {
        var options = TerminalOptions.default
        options.cols = max(cols, 2)
        options.rows = max(rows, 2)
        options.scrollback = Self.scrollback
        options.termName = "xterm-256color"
        terminal = Terminal(delegate: self, options: options)
    }

    var isAlternate: Bool {
        terminal.isCurrentBufferAlternate
    }

    func feed(_ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes)
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: max(cols, 2), rows: max(rows, 2))
        forgetSettled()
    }

    func render() -> NSAttributedString {
        guard !isAlternate else { return latest }
        let buffer = terminal.buffer
        let trimmed = buffer.totalLinesTrimmed
        let settledEnd = trimmed + buffer.yDisp
        if cachedBuffer != ObjectIdentifier(buffer) || trimmed < settledBase || settledEnd < settledBase + settledLengths.count {
            cachedBuffer = ObjectIdentifier(buffer)
            forgetSettled()
        }
        if trimmed > settledBase {
            let dropped = min(trimmed - settledBase, settledLengths.count)
            settled.deleteCharacters(in: NSRange(location: 0, length: settledLengths.prefix(dropped).reduce(0, +)))
            settledLengths.removeFirst(dropped)
            settledBase = trimmed
        }

        var row = settledBase + settledLengths.count
        while row < settledEnd, let line = terminal.getScrollInvariantLine(row: row) {
            let piece = NSMutableAttributedString(attributedString: render(line))
            if terminal.getScrollInvariantLine(row: row + 1)?.isWrapped != true { piece.append(Self.newline) }
            settled.append(piece)
            settledLengths.append(piece.length)
            row += 1
        }

        var live: [(text: NSAttributedString, wrapped: Bool)] = []
        for row in settledEnd..<(trimmed + buffer.yDisp + terminal.rows) {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            live.append((render(line), line.isWrapped))
        }
        while let last = live.last, last.text.length == 0, !last.wrapped {
            live.removeLast()
        }

        let result = NSMutableAttributedString(attributedString: settled)
        if live.isEmpty, result.length > 0, (result.string as NSString).character(at: result.length - 1) == 10 {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        for (index, line) in live.enumerated() {
            if index > 0, !line.wrapped { result.append(Self.newline) }
            result.append(line.text)
        }
        latest = result
        return result
    }

    private func forgetSettled() {
        settled = NSMutableAttributedString()
        settledLengths = []
        settledBase = terminal.buffer.totalLinesTrimmed
    }

    private func render(_ line: BufferLine) -> NSAttributedString {
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

        let result = NSMutableAttributedString()
        var run = ""
        var runAttribute = Attribute.empty
        var started = false
        func flush() {
            guard started, !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: attributes(runAttribute)))
            run = ""
        }
        for column in 0..<end {
            let cell = line[column]
            if cell.width == 0 { continue }
            if !started || cell.attribute != runAttribute {
                flush()
                runAttribute = cell.attribute
                started = true
            }
            let character = terminal.getCharacter(for: cell)
            run.append(character == "\u{0}" ? " " : character)
        }
        flush()
        return result
    }

    private func attributes(_ attribute: Attribute) -> [NSAttributedString.Key: Any] {
        if let cached = styles[attribute] { return cached }
        if styles.count > 4096 { styles.removeAll() }
        let built = BlockStyle.attributes(attribute)
        styles[attribute] = built
        return built
    }

    func clipboardCopy(source: Terminal, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
    }

    func clipboardRead(source: Terminal) -> Data? {
        nil
    }

    func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        onProgress(report.state == .remove ? nil : report)
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        onResponse?(Array(data))
    }
}
