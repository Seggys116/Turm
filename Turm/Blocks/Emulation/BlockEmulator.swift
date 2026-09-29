import AppKit
import CoreGraphics
import Foundation
import SwiftTerm
import SwiftUI

final class BlockEmulator: TerminalDelegate {
    static let scrollback = 20_000

    private(set) var terminal: Terminal!
    let normalStore = KittyStore()
    let altStore = KittyStore()
    var storeOverride: KittyStore?
    var nextEngineID: UInt32 = 1
    var pendingBufferSwitch = false
    var activeJob: KittyJob?
    var chunked: KittyJob?
    var settled: (row: Int, rows: Int)?
    var replyFilter = KittyReplyFilter()
    private var held: [UInt8] = []
    private var sgrRewriter = SGRRewriter()

    var store: KittyStore {
        storeOverride ?? (terminal.isCurrentBufferAlternate ? altStore : normalStore)
    }

    var images: [InlineImage] {
        get { store.images }
        _modify { yield &store.images }
    }

    var virtualPlacements: [InlineImage] {
        get { store.virtualPlacements }
        _modify { yield &store.virtualPlacements }
    }

    var sources: [UInt32: KittyAnimation] {
        get { store.sources }
        _modify { yield &store.sources }
    }

    var imageNumbers: [UInt32: UInt32] {
        get { store.imageNumbers }
        _modify { yield &store.imageNumbers }
    }

    var nextImageID: UInt32 {
        get { store.nextImageID }
        set { store.nextImageID = newValue }
    }

    var nextInternalID: UInt32 {
        get { store.nextInternalID }
        set { store.nextInternalID = newValue }
    }

    var unloaded: Set<UInt32> {
        get { store.unloaded }
        _modify { yield &store.unloaded }
    }

    var accessClock: UInt64 {
        get { store.accessClock }
        set { store.accessClock = newValue }
    }

    var storageLimit: Int {
        get { store.storageLimit }
        set { store.storageLimit = newValue }
    }

    private static let heldLimit = 128 * 1024 * 1024
    var onBufferSwitch: () -> Void = {}
    var onResponse: (ArraySlice<UInt8>) -> Void = { _ in }
    var onProgress: (Terminal.ProgressReport?) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }

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

    func feed(_ chunk: [UInt8]) {
        let incoming = sgrRewriter.rewrite(chunk)
        var bytes = incoming
        if !held.isEmpty {
            let scanned = held.count
            held.append(contentsOf: incoming)
            let opensGraphics = held.count >= 3 && held[0] == 0x1B && held[1] == 0x5F && held[2] == 0x47
            if opensGraphics, KittyGraphicsScanner.terminator(in: held, from: max(3, scanned - 1)) == nil {
                guard held.count > Self.heldLimit else { return }
                terminal.feed(byteArray: held)
                held = []
                return
            }
            bytes = held
            held = []
        }
        guard bytes.contains(0x1B) else {
            terminal.feed(byteArray: bytes)
            return
        }
        let split = KittyGraphicsScanner.split(bytes)
        held = Array(split.remainder)
        for piece in split.pieces {
            switch piece.kind {
            case .text:
                terminal.feed(byteArray: Array(piece.bytes))
                settleBufferSwitch()
            case .clear(let scope):
                terminal.feed(byteArray: Array(piece.bytes))
                settleBufferSwitch()
                clearPlacements(scope)
            case .graphics(let command):
                feedGraphics(piece.bytes, command)
            }
        }
        pruneScrolledOff()
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: max(cols, 2), rows: max(rows, 2))
    }

    func render() -> AttributedString {
        var result = AttributedString()
        var first = true
        func append(_ text: AttributedString) {
            if !first { result.append(AttributedString("\n")) }
            result.append(text)
            first = false
        }
        for segment in renderSegments() {
            switch segment {
            case .text(let text): append(text)
            case .stack(let stack): stack.lines.forEach(append)
            case .image: break
            }
        }
        return result
    }

    func origin(of image: InlineImage) -> (row: Int, column: Int)? {
        normalStore.images.origin(of: image, virtual: placeholderLayout().origins)
    }

    func renderSegments() -> [OutputSegment] {
        let lines = collectLines()
        let trimmed = terminal.buffer.totalLinesTrimmed
        let holders = placeholderLayout()
        let placements = normalStore.images.compactMap { image -> InlineImage? in
            guard image.fromKitty, image.rowSpan > 0, let origin = normalStore.images.origin(of: image, virtual: holders.origins)
            else { return nil }
            var placed = image
            placed.anchor = origin.row
            placed.column = origin.column
            return placed
        } + holders.tiles
        let tileRows = Set(holders.tiles.map(\.anchor))
        let bands = Self.bands(of: placements)
        let legacy = normalStore.images.filter { !($0.fromKitty && $0.rowSpan > 0) }
        var byRow: [Int: (text: AttributedString, wrapped: Bool)] = [:]
        for line in lines {
            byRow[line.row] = (tileRows.contains(line.row) ? line.text.maskingPlaceholders() : line.text, line.wrapped)
        }
        let lastRow = max(lines.last?.row ?? trimmed - 1, (bands.last?.range.upperBound ?? 0) - 1)

        var segments: [OutputSegment] = []
        var text = AttributedString()
        var hasText = false
        var nextLegacy = 0

        func flushText() {
            if hasText {
                segments.append(.text(text))
                text = AttributedString()
                hasText = false
            }
        }
        func placeLegacy(upTo row: Int?) {
            while nextLegacy < legacy.count, row == nil || legacy[nextLegacy].anchor <= row! {
                flushText()
                segments.append(.image(legacy[nextLegacy]))
                nextLegacy += 1
            }
        }

        var row = trimmed
        while row <= lastRow {
            placeLegacy(upTo: row)
            if let band = bands.first(where: { $0.range.contains(row) }) {
                flushText()
                let contents = band.range.map { byRow[$0]?.text ?? AttributedString() }
                let ordered = band.images.enumerated().sorted {
                    ($0.element.zIndex, $0.element.kittyID ?? 0, $0.offset) < ($1.element.zIndex, $1.element.kittyID ?? 0, $1.offset)
                }.map(\.element)
                let blank = contents.allSatisfy { $0.characters.allSatisfy(\.isWhitespace) }
                if ordered.count == 1, blank {
                    segments.append(.image(ordered[0]))
                } else {
                    segments.append(.stack(ImageStack(
                        start: band.range.lowerBound, rows: band.range.count, lines: blank ? [] : contents, images: ordered
                    )))
                }
                row = band.range.upperBound
                continue
            }
            let line = byRow[row]
            if hasText, !(line?.wrapped ?? false) {
                text.append(AttributedString("\n"))
            }
            text.append(line?.text ?? AttributedString())
            hasText = true
            row += 1
        }
        placeLegacy(upTo: nil)
        flushText()
        return segments
    }

    private static func bands(of placements: [InlineImage]) -> [(range: Range<Int>, images: [InlineImage])] {
        var bands: [(range: Range<Int>, images: [InlineImage])] = []
        for image in placements.sorted(by: { $0.anchor < $1.anchor }) {
            let end = image.anchor + image.rowSpan
            if let last = bands.last, image.anchor < last.range.upperBound {
                bands[bands.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, end), last.images + [image])
            } else {
                bands.append((image.anchor..<end, [image]))
            }
        }
        return bands
    }

    private func collectLines() -> [(row: Int, text: AttributedString, wrapped: Bool)] {
        let trimmed = terminal.buffer.totalLinesTrimmed
        let lineCount = terminal.buffer.yDisp + terminal.rows
        var lines: [(row: Int, text: AttributedString, wrapped: Bool)] = []
        lines.reserveCapacity(lineCount)
        for index in 0..<lineCount {
            guard let line = terminal.getScrollInvariantLine(row: index + trimmed) else { continue }
            lines.append((index + trimmed, renderLine(line), line.isWrapped))
        }
        while let last = lines.last, last.text.characters.isEmpty, !last.wrapped {
            lines.removeLast()
        }
        return lines
    }

    private func renderLine(_ line: BufferLine) -> AttributedString {
        var cells: [(Character, Attribute, URL?)] = []
        cells.reserveCapacity(line.count)
        for column in 0..<line.count {
            let cell = line[column]
            if cell.width == 0 { continue }
            let character = terminal.getCharacter(for: cell)
            cells.append((character == "\u{0}" ? " " : character, cell.attribute, Self.link(of: cell)))
        }
        while let last = cells.last, last.0 == " ", last.1.bg == .defaultInvertedColor || last.1.bg == .defaultColor {
            cells.removeLast()
        }

        var result = AttributedString()
        var run = ""
        var runAttribute: Attribute?
        var runLink: URL?
        func flush() {
            guard let attribute = runAttribute, !run.isEmpty else { return }
            result.append(AttributedString(run, attributes: TerminalPalette.attributes(attribute, link: runLink)))
            run = ""
        }
        for (character, attribute, link) in cells {
            if attribute != runAttribute || link != runLink {
                flush()
                runAttribute = attribute
                runLink = link
            }
            run.append(character)
        }
        flush()
        return result
    }

    private static func link(of cell: CharData) -> URL? {
        guard let payload = cell.getPayload() as? String,
              let separator = payload.firstIndex(of: ";")
        else { return nil }
        let target = payload[payload.index(after: separator)...]
        guard let url = URL(string: String(target)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "file", "ssh"].contains(scheme)
        else { return nil }
        return url
    }

    func apply(dark: Bool) {
        terminal.installPalette(colors: TerminalPalette.engineColors(dark: dark))
        terminal.foregroundColor = TerminalPalette.engineColor(Theme.text.resolved(dark: dark))
        terminal.backgroundColor = TerminalPalette.engineColor(Theme.terminalBackground.resolved(dark: dark))
    }

    func clipboardCopy(source: Terminal, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: Terminal) -> Data? {
        ClipboardPermission.readClipboard()
    }

    func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        onProgress(report.state == .remove ? nil : report)
    }

    static var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    var cellPixels: (width: Int, height: Int) {
        (Int(TerminalMetrics.cellWidth * Self.backingScale), Int(TerminalMetrics.lineHeight * Self.backingScale))
    }

    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        cellPixels
    }

    func createImage(
        source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool
    ) {
        guard let image = NSImage(data: data) else { return }
        if !landKitty(image, pixels: Self.pixelSize(of: image)) {
            record(image, width: width, height: height)
        }
    }

    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, bytes.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        if !landKitty(image, pixels: CGSize(width: width, height: height)) {
            record(image, width: .auto, height: .auto)
        }
    }

    private static func pixelSize(of image: NSImage) -> CGSize {
        for representation in image.representations where representation.pixelsWide > 0 && representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }

    private func record(_ image: NSImage, width: ImageSizeRequest, height: ImageSizeRequest) {
        // full-screen programs draw on the alternate screen, and that content vanishes when they exit
        guard !terminal.isCurrentBufferAlternate else { return }
        let buffer = terminal.buffer
        var row = buffer.yDisp + buffer.y + buffer.totalLinesTrimmed
        if let line = terminal.getLine(row: buffer.y), !renderLine(line).characters.isEmpty {
            row += 1
        }
        images.append(InlineImage(image: image, width: width, height: height, anchor: row))
    }

    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) { onTitle(title) }
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) { deliver(data) }
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {
        if terminal?.isCurrentBufferAlternate == true { pendingBufferSwitch = true }
        onBufferSwitch()
    }
    func bell(source: Terminal) { Bell.ring() }
    func selectionChanged(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { true }
    func mouseModeChanged(source: Terminal) {}
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
}

enum TerminalPalette {
    static func engineColor(_ color: NSColor) -> SwiftTerm.Color {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> UInt16 {
            UInt16((max(0, min(1, value)) * 65535).rounded())
        }
        return SwiftTerm.Color(red: channel(rgb.redComponent), green: channel(rgb.greenComponent), blue: channel(rgb.blueComponent))
    }

    static func engineColors(dark: Bool) -> [SwiftTerm.Color] {
        Theme.ansi.map { engineColor($0.resolved(dark: dark)) }
    }

    static let foreground = Theme.text.color

    static let textColor = Theme.text.dynamicNS
    static let fontSize: CGFloat = 13

    private static let ansiColors = Theme.ansi.map(\.dynamicNS)
    private static let terminalBackgroundColor = Theme.terminalBackground.dynamicNS

    static func attributes(_ attribute: Attribute, link: URL? = nil) -> AttributeContainer {
        var foreground = color(attribute.fg)
        var background = color(attribute.bg)
        if attribute.style.contains(.inverse) {
            let swappedForeground = background ?? terminalBackgroundColor
            background = foreground ?? textColor
            foreground = swappedForeground
        }
        var container = AttributeContainer()
        var ink = foreground ?? textColor
        if attribute.style.contains(.dim) { ink = ink.withAlphaComponent(0.6) }
        if attribute.style.contains(.invisible) { ink = .clear }
        container.appKit.foregroundColor = ink
        if let background { container.appKit.backgroundColor = background }
        let fontIndex = (attribute.style.contains(.bold) ? 1 : 0) | (attribute.style.contains(.italic) ? 2 : 0)
        container[FontStyleKey.self] = fontIndex

        var underline = attribute.underlineStyle
        if underline == .none, attribute.style.contains(.underline) || link != nil { underline = .single }
        switch underline {
        case .none: break
        case .single: container.appKit.underlineStyle = .single
        case .double: container.appKit.underlineStyle = .double
        case .curly:
            container.appKit.underlineStyle = .single
            container[CurlyUnderlineKey.self] = true
        case .dotted: container.appKit.underlineStyle = [.single, .patternDot]
        case .dashed: container.appKit.underlineStyle = [.single, .patternDash]
        }
        if underline != .none, let underlineColor = attribute.underlineColor.flatMap({ color($0) }) {
            container.appKit.underlineColor = underlineColor
        }
        if attribute.style.contains(.crossedOut) { container.appKit.strikethroughStyle = .single }
        if attribute.style.contains(.blink) { container[BlinkKey.self] = true }
        if let link { container.link = link }
        return container
    }

    private static func color(_ value: Attribute.Color) -> NSColor? {
        switch value {
        case .defaultColor, .defaultInvertedColor:
            return nil
        case .trueColor(let red, let green, let blue):
            return rgb(red, green, blue)
        case .ansi256(let code):
            return indexed(Int(code))
        }
    }

    private static func indexed(_ code: Int) -> NSColor {
        if code < 16 {
            return ansiColors[code]
        }
        if code < 232 {
            let index = code - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return rgb(levels[index / 36], levels[(index / 6) % 6], levels[index % 6])
        }
        let level = UInt8(8 + (code - 232) * 10)
        return rgb(level, level, level)
    }

    private static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
