import Foundation
import SwiftTerm
import TurmCore
import UIKit

final class MacBlockEmulator: TerminalDelegate {
    static let scrollback = 20_000

    private(set) var terminal: Terminal!
    var onProgress: (Terminal.ProgressReport?) -> Void = { _ in }
    var onResponse: (([UInt8]) -> Void)?
    var macName: String?
    let engine = KittyEngine()
    private(set) lazy var graphicsHost = MacBlockGraphicsHost(emulator: self)
    private(set) var graphics = BlockGraphics.empty
    private var intake = KittyStreamIntake()
    private var graphicHold = GraphicHold()
    private var inlineGraphics = InlineGraphicsSession()
    private var pictures: [Picture] = []
    private var anchored: [(row: Int, rows: Int)] = []
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
        graphicsHost.noteBuffer()
    }

    var isAlternate: Bool {
        terminal.isCurrentBufferAlternate
    }

    func feed(_ chunk: [UInt8]) {
        guard let bytes = intake.take(chunk) else { return }
        guard bytes.contains(0x1B) else {
            feedTerminal(bytes)
            pruneScrolledOff()
            return
        }
        for piece in intake.split(bytes) {
            switch piece.kind {
            case .text:
                feedTerminal(piece.bytes.count == bytes.count ? bytes : Array(piece.bytes))
            case .clear(let scope):
                feedTerminal(Array(piece.bytes))
                clearGraphics(scope)
            case .graphics:
                engine.handle(piece.bytes, host: graphicsHost)
            }
        }
        pruneScrolledOff()
    }

    private func feedTerminal(_ bytes: [UInt8]) {
        guard let ready = graphicHold.intake(bytes) else { return }
        let split = TerminalGraphics.split(ready)
        for piece in split.pieces {
            switch piece {
            case .osc(let payload):
                showCommand(payload)
            case .sixel(let image):
                guard image.count <= TerminalGraphics.byteLimit, SixelPrescan.admits(image) else { continue }
                showSixel(image)
            case .query(let reply):
                if !reply.isEmpty { onResponse?(reply) }
            case .bytes(let raw):
                guard !raw.isEmpty else { continue }
                terminal.feed(buffer: raw)
            }
            advanceUnmovedImages()
        }
        graphicHold.hold(split.remainder)
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: max(cols, 2), rows: max(rows, 2))
        forgetSettled()
        pruneScrolledOff()
    }

    func render() -> NSAttributedString {
        guard !isAlternate else { return renderBehindProgram() }
        prunePictures()
        let placed = engine.placements(visible: terminal.buffer.totalLinesTrimmed..<Int.max, host: graphicsHost)
        if !pictures.isEmpty || !placed.isEmpty { return renderWithImages(placed) }
        graphics = .empty
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

    // SwiftTerm hides the main screen's lines while a program runs, so the last text stays and only its images are laid out again
    private func renderBehindProgram() -> NSAttributedString {
        let normal = engine.placements(visible: graphics.firstRow..<Int.max, host: graphicsHost, buffer: .normal)
        graphics = normal.isEmpty ? .empty : BlockGraphics(placements: normal, firstRow: graphics.firstRow, rowStarts: graphics.rowStarts)
        return latest
    }

    private func forgetSettled() {
        settled = NSMutableAttributedString()
        settledLengths = []
        settledBase = terminal.buffer.totalLinesTrimmed
    }

    private struct Picture {
        let row: Int
        let rows: Int
        let columns: Int
        let image: UIImage
    }

    private var fontSize: Double { TerminalPreferences.shared.fontSize }

    var displayScale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 2
    }

    var cursorRow: Int {
        let buffer = terminal.buffer
        return buffer.totalLinesTrimmed + buffer.yDisp + buffer.y
    }

    var cellPixels: (width: Int, height: Int) {
        let cell = BlockStyle.cellSize(fontSize: fontSize)
        let scale = displayScale
        return (max(Int((cell.width * scale).rounded()), 1), max(Int((cell.height * scale).rounded()), 1))
    }

    private func renderWithImages(_ placed: [GraphicsPlacement]) -> NSAttributedString {
        let buffer = terminal.buffer
        let trimmed = buffer.totalLinesTrimmed
        let last = trimmed + buffer.yDisp + terminal.rows
        let covered = placed.map { $0.origin.row + max($0.rowSpan, 1) }.max() ?? trimmed
        let result = NSMutableAttributedString()
        var starts: [Int] = []
        var kept = (length: 0, rows: 0)
        var row = trimmed
        var started = false
        while row < last {
            if let picture = pictures.first(where: { $0.row == row }) {
                if started { result.append(Self.newline) }
                let span = max(picture.rows, 1)
                starts.append(contentsOf: repeatElement(result.length, count: span))
                result.append(attachment(picture))
                kept = (result.length, starts.count)
                started = true
                row += span
                continue
            }
            guard let line = terminal.getScrollInvariantLine(row: row) else { break }
            if started, !line.isWrapped { result.append(Self.newline) }
            starts.append(result.length)
            let text = render(line)
            result.append(text)
            if text.length > 0 || line.isWrapped || row < covered { kept = (result.length, starts.count) }
            started = true
            row += 1
        }
        // blank rows below the last text and image are dropped, as the plain path does
        if kept.length < result.length { result.deleteCharacters(in: NSRange(location: kept.length, length: result.length - kept.length)) }
        starts.removeLast(starts.count - kept.rows)
        graphics = placed.isEmpty ? .empty : BlockGraphics(placements: placed, firstRow: trimmed, rowStarts: starts)
        latest = result
        return result
    }

    private func attachment(_ picture: Picture) -> NSAttributedString {
        let cell = BlockStyle.cellSize(fontSize: fontSize)
        let attachment = NSTextAttachment()
        attachment.image = picture.image
        attachment.bounds = CGRect(
            x: 0, y: 0,
            width: CGFloat(max(picture.columns, 1)) * cell.width,
            height: CGFloat(max(picture.rows, 1)) * cell.height
        )
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttribute(.blockFontStyle, value: 0, range: NSRange(location: 0, length: text.length))
        return text
    }

    private func showCommand(_ payload: ArraySlice<UInt8>) {
        let cell = BlockStyle.cellSize(fontSize: fontSize)
        let metrics = InlineGraphics.Cell(height: Double(cell.height), width: Double(cell.width), scale: Double(displayScale))
        guard let outcome = inlineGraphics.receive(payload, cell: metrics) else { return }
        switch outcome {
        case .reply(let bytes):
            onResponse?(bytes)
        case .image(let placement):
            guard let image = scaled(placement.data) else { return }
            place(
                image, width: request(placement.width), height: request(placement.height),
                preserveAspectRatio: placement.preserveAspectRatio, fromEngine: false, moveCursor: placement.moveCursor
            )
        }
    }

    private func showSixel(_ sequence: ArraySlice<UInt8>) {
        guard let sixel = SixelDecoder.decode(sequence: sequence), GraphicsBounds.admits(width: sixel.width, height: sixel.height),
              let cgImage = sixel.cgImage
        else { return }
        let image = UIImage(cgImage: cgImage, scale: displayScale, orientation: .up)
        place(image, width: .auto, height: .auto, preserveAspectRatio: true, fromEngine: true)
    }

    private func place(
        _ image: UIImage, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool, fromEngine: Bool,
        moveCursor: Bool = true
    ) {
        guard !terminal.isCurrentBufferAlternate else { return }
        let cell = BlockStyle.cellSize(fontSize: fontSize)
        let region = CGSize(width: cell.width * CGFloat(terminal.cols), height: cell.height * CGFloat(terminal.rows))
        var displayWidth = length(width, cell: cell.width, region: region.width, natural: image.size.width)
        var displayHeight = length(height, cell: cell.height, region: region.height, natural: image.size.height)
        if preserveAspectRatio, image.size.width > 0, image.size.height > 0 {
            switch (width, height) {
            case (.auto, .auto):
                break
            case (_, .auto):
                displayHeight = displayWidth * image.size.height / image.size.width
            case (.auto, _):
                displayWidth = displayHeight * image.size.width / image.size.height
            default:
                break
            }
        }
        let rows = max(1, min(10_000, Int(ceil(displayHeight / cell.height))))
        let columns = max(1, min(terminal.cols, Int(ceil(displayWidth / cell.width))))
        let row = cursorRow
        pictures.append(Picture(row: row, rows: rows, columns: columns, image: image))
        if fromEngine {
            anchored.append((row, rows))
        } else if moveCursor {
            terminal.feed(byteArray: Array(String(repeating: "\r\n", count: rows).utf8))
        }
    }

    private func advanceUnmovedImages() {
        let items = anchored
        anchored = []
        for item in items where cursorRow <= item.row {
            terminal.feed(byteArray: Array(String(repeating: "\r\n", count: item.rows).utf8))
        }
    }

    private func length(_ request: ImageSizeRequest, cell: CGFloat, region: CGFloat, natural: CGFloat) -> CGFloat {
        switch request {
        case .auto: return max(natural, 1)
        case .cells(let count): return cell * CGFloat(count)
        case .pixels(let count): return CGFloat(count)
        case .percent(let count): return region * CGFloat(count) / 100
        }
    }

    private func scaled(_ data: Data) -> UIImage? {
        guard GraphicsBounds.admits(imageData: data), let image = UIImage(data: data) else { return nil }
        guard let cgImage = image.cgImage else { return image }
        return UIImage(cgImage: cgImage, scale: displayScale, orientation: image.imageOrientation)
    }

    private func request(_ size: InlineGraphics.Size) -> ImageSizeRequest {
        switch size {
        case .auto: return .auto
        case .cells(let count): return .cells(count)
        case .pixels(let count): return .pixels(count)
        case .percent(let count): return .percent(count)
        }
    }

    private func prunePictures() {
        let trimmed = terminal.buffer.totalLinesTrimmed
        pictures.removeAll { $0.row + $0.rows <= trimmed }
    }

    private func pruneScrolledOff() {
        let trimmed = terminal.buffer.totalLinesTrimmed
        guard trimmed > 0 else { return }
        engine.pruneScrolledOff(trimmed: trimmed)
        prunePictures()
    }

    private func clearGraphics(_ scope: KittyGraphicsScanner.ClearScope) {
        if scope == .scrollback {
            if let push = terminal.scrollbackPush() { terminal.feed(byteArray: push) }
            terminal.feed(byteArray: Array("\u{1B}[2J".utf8))
        }
        engine.clear(scope, host: graphicsHost)
        guard scope == .reset || !terminal.isCurrentBufferAlternate else { return }
        switch scope {
        case .everything, .reset:
            pictures.removeAll()
        case .visible, .scrollback:
            let top = terminal.buffer.totalLinesTrimmed + terminal.buffer.yDisp
            pictures.removeAll { $0.row + $0.rows > top }
        }
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
            run.append(character == "\u{0}" || KittyPlaceholders.isPlaceholder(character) ? " " : character)
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

    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        cellPixels
    }

    func bufferActivated(source: Terminal) {
        graphicsHost.noteBuffer()
        engine.bufferSwitched(toAlternate: source.isCurrentBufferAlternate)
    }

    func createImage(
        source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool
    ) {
        guard data.count <= TerminalGraphics.byteLimit, let image = scaled(data) else { return }
        place(image, width: width, height: height, preserveAspectRatio: preserveAspectRatio, fromEngine: true)
    }

    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        guard GraphicsBounds.admits(width: width, height: height), bytes.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return }
        let image = UIImage(cgImage: cgImage, scale: displayScale, orientation: .up)
        place(image, width: .auto, height: .auto, preserveAspectRatio: true, fromEngine: true)
    }

    func clipboardCopy(source: Terminal, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        let name = macName ?? "the connected Mac"
        DispatchQueue.main.async { Self.confirmCopy(text, from: name) }
    }

    private static func confirmCopy(_ text: String, from name: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.keyWindow?.rootViewController
        else { return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIAlertController) else { return }
        let alert = UIAlertController(
            title: "Allow \(name) to change your clipboard?",
            message: "A program running on \(name) asked to copy text to the clipboard on this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Deny", style: .cancel))
        alert.addAction(UIAlertAction(title: "Allow Once", style: .default) { _ in UIPasteboard.general.string = text })
        presenter.present(alert, animated: true)
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
