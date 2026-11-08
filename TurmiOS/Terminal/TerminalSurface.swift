import SwiftTerm
import TurmCore
import UIKit

final class TerminalSurface: NSObject, TerminalViewDelegate {
    let view: TurmTerminalView
    let stage: TerminalStage
    let engine = KittyEngine()
    let keyBar = TerminalKeyBarView()
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?

    private let preferences: TerminalPreferences
    private var pinchBase = 0.0
    private var appliedDark: Bool?
    private var appliedSize = 0.0
    private var resizeTask: Task<Void, Never>?
    private var graphicHold = GraphicHold()
    private var inlineGraphics = InlineGraphicsSession()
    private(set) lazy var graphicsHost = SurfaceGraphicsHost(surface: self)
    private let painter = GraphicsLayerPainter()
    private var held: [UInt8] = []
    private var skippingGraphics = false
    private var skipCarry: [UInt8] = []
    private var graphicsQueued = false
    private var paintedRows: Range<Int>?
    var replays = false
    private static let resizeSettle = Duration.milliseconds(120)
    private static let heldLimit = 128 * 1024 * 1024

    init(preferences: TerminalPreferences = .shared, capturesKeyboard: Bool = false) {
        self.preferences = preferences
        view = TurmTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        stage = TerminalStage(terminal: view)
        super.init()
        view.layer.insertSublayer(painter.overlay, at: 0)
        stage.underlay.addSublayer(painter.underlay)
        view.onScroll = { [weak self] in self?.followScroll() }
        view.onLayout = { [weak self] in self?.setNeedsGraphics() }
        view.terminalDelegate = self
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.optionAsMetaKey = true
        view.contentInsetAdjustmentBehavior = .never
        keyBar.onBytes = { [weak self] data in self?.onInput?(ArraySlice(data)) }
        keyBar.onPaste = { [weak self] in self?.view.paste(nil) }
        keyBar.cursorMode = { [weak self] in self?.view.getTerminal().applicationCursor ?? false }
        keyBar.kittyFlags = { [weak self] in self?.view.getTerminal().keyboardEnhancementFlags.rawValue ?? 0 }
        view.inputAccessoryView = keyBar
        view.capturesKeyboard = capturesKeyboard
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        view.addGestureRecognizer(pinch)
        apply(fontSize: preferences.fontSize)
    }

    var size: (cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    func width(forColumns columns: Int) -> CGFloat {
        let current = view.getTerminal().cols
        guard current > 0 else { return 0 }
        return view.getOptimalFrameSize().width / CGFloat(current) * CGFloat(columns)
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        var incoming = Array(bytes)
        if skippingGraphics {
            guard let rest = skipGraphics(incoming) else { return }
            incoming = rest
        }
        var chunk = incoming
        if !held.isEmpty {
            let scanned = held.count
            held.append(contentsOf: incoming)
            let opensGraphics = held.count >= 3 && held[0] == 0x1B && held[1] == 0x5F && held[2] == 0x47
            if opensGraphics, KittyGraphicsScanner.terminator(in: held, from: max(3, scanned - 1)) == nil {
                guard held.count > Self.heldLimit else { return }
                skipCarry = held.last == 0x1B ? [0x1B] : []
                skippingGraphics = true
                held = []
                return
            }
            chunk = held
            held = []
        }
        if chunk.contains(0x1B) {
            let split = KittyGraphicsScanner.split(chunk)
            held = Array(split.remainder)
            for piece in split.pieces {
                switch piece.kind {
                case .text:
                    feedTerminal(piece.bytes)
                case .clear(let scope):
                    feedTerminal(piece.bytes)
                    clearGraphics(scope)
                case .graphics:
                    engine.handle(piece.bytes, host: graphicsHost)
                }
            }
        } else {
            feedTerminal(chunk[...])
        }
        settle()
    }

    private func feedTerminal(_ bytes: ArraySlice<UInt8>) {
        guard let ready = graphicHold.intake(Array(bytes)) else { return }
        let split = TerminalGraphics.split(ready)
        for piece in split.pieces {
            switch piece {
            case .bytes(let raw):
                view.feed(byteArray: raw)
            case .sixel(let image):
                guard image.count <= TerminalGraphics.byteLimit, SixelPrescan.admits(image) else { continue }
                drawSixel(image)
            case .query(let reply):
                if !replays, !reply.isEmpty { onInput?(ArraySlice(reply)) }
            case .osc(let payload):
                switch inlineGraphics.receive(payload, cell: cell) {
                case .reply(let reply):
                    guard !replays else { continue }
                    onInput?(ArraySlice(reply))
                case .image(let placement):
                    guard placement.data.count <= TerminalGraphics.byteLimit, GraphicsBounds.admits(imageData: placement.data) else { continue }
                    view.feed(byteArray: Self.inlineImage(placement)[...])
                case nil:
                    break
                }
            }
        }
        graphicHold.hold(split.remainder)
    }

    /// Drops the rest of a graphics command that outgrew the hold, up to its terminator.
    private func skipGraphics(_ bytes: [UInt8]) -> [UInt8]? {
        let bytes = skipCarry + bytes
        skipCarry = []
        guard let end = KittyGraphicsScanner.terminator(in: bytes, from: 0) else {
            if bytes.last == 0x1B { skipCarry = [0x1B] }
            return nil
        }
        skippingGraphics = false
        return Array(bytes[(bytes[end] == 0x1B ? end + 2 : end + 1)...])
    }

    private func clearGraphics(_ scope: KittyGraphicsScanner.ClearScope) {
        if scope == .scrollback {
            pushScreenIntoScrollback()
            view.feed(byteArray: Array("\u{1B}[2J".utf8)[...])
        }
        engine.clear(scope, host: graphicsHost)
    }

    private func pushScreenIntoScrollback() {
        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        let top = graphicsHost.screenTop
        func blank(_ row: Int) -> Bool {
            guard let line = terminal.getScrollInvariantLine(row: top + row) else { return true }
            for column in 0..<line.count {
                let character = terminal.getCharacter(for: line[column])
                if character != " " && character != "\u{0}" { return false }
            }
            return true
        }
        var count = terminal.rows
        while count > 0, blank(count - 1) { count -= 1 }
        guard count > 0 else { return }
        let sequence = "\u{1B}7\u{1B}[\(terminal.rows);1H" + String(repeating: "\n", count: count) + "\u{1B}8"
        view.feed(byteArray: Array(sequence.utf8)[...])
    }

    private func settle() {
        let terminal = view.getTerminal()
        engine.bufferSwitched(toAlternate: terminal.isCurrentBufferAlternate)
        engine.pruneScrolledOff(trimmed: terminal.buffer.totalLinesTrimmed)
        stage.reconcile()
        setNeedsGraphics()
    }

    var displayScale: CGFloat {
        let scale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    var cellPoints: CGSize {
        let terminal = view.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return .zero }
        let size = view.getOptimalFrameSize().size
        return CGSize(width: size.width / CGFloat(terminal.cols), height: size.height / CGFloat(terminal.rows))
    }

    private var hasGraphics: Bool {
        [engine.store, engine.alternateStore].contains { !$0.images.isEmpty || !$0.virtualPlacements.isEmpty }
    }

    private func setNeedsGraphics() {
        guard !graphicsQueued else { return }
        graphicsQueued = true
        DispatchQueue.main.async { [weak self] in self?.paintGraphics() }
    }

    // painting stays out of feed, since the engine is not reentrant and feeding the view scrolls it
    private func paintGraphics() {
        graphicsQueued = false
        let cell = cellPoints
        guard hasGraphics, cell.width > 0, cell.height > 0 else {
            if paintedRows != nil {
                painter.removeAll()
                paintedRows = nil
            }
            stage.showUnderlay(false)
            return
        }
        let terminal = view.getTerminal()
        engine.bufferSwitched(toAlternate: terminal.isCurrentBufferAlternate)
        let visible = visibleRows(cell: cell)
        let span = visible.count
        let rows = (visible.lowerBound - span)..<(visible.upperBound + span)
        let placed = engine.placements(visible: rows, host: graphicsHost)
        let geometry = GraphicsLayerPainter.Geometry(
            top: terminal.buffer.totalLinesTrimmed, cellWidth: cell.width, cellHeight: cell.height, scale: displayScale
        )
        painter.update(placements: placed, geometry: geometry)
        paintedRows = rows
        stage.showUnderlay(placed.contains { $0.zIndex < 0 })
        placeUnderlay()
    }

    private func visibleRows(cell: CGSize) -> Range<Int> {
        let terminal = view.getTerminal()
        let first = terminal.buffer.totalLinesTrimmed + max(Int((view.contentOffset.y / cell.height).rounded(.down)), 0)
        let count = max(Int((view.bounds.height / cell.height).rounded(.up)) + 1, terminal.rows)
        return first..<(first + count)
    }

    private func followScroll() {
        placeUnderlay()
        guard let paintedRows else { return }
        let cell = cellPoints
        guard cell.height > 0 else { return }
        let visible = visibleRows(cell: cell)
        if visible.lowerBound < paintedRows.lowerBound || visible.upperBound > paintedRows.upperBound { setNeedsGraphics() }
    }

    // the underlay sits behind the scroll view, so it is shifted by hand to match the scrolled text
    private func placeUnderlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let offset = view.contentOffset
        painter.underlay.frame = CGRect(x: -offset.x, y: -offset.y, width: 0, height: 0)
        CATransaction.commit()
    }

    private func drawSixel(_ sequence: ArraySlice<UInt8>) {
        guard let sixel = SixelDecoder.decode(sequence: sequence), GraphicsBounds.admits(width: sixel.width, height: sixel.height) else { return }
        var pixels = sixel.premultipliedRGBA
        view.createImageFromBitmap(source: view.getTerminal(), bytes: &pixels, width: sixel.width, height: sixel.height)
    }

    private var cell: InlineGraphics.Cell {
        let font = view.font
        let width = max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        let scale = view.window?.windowScene?.screen.scale ?? 2
        return InlineGraphics.Cell(height: Double(font.lineHeight), width: Double(width), scale: Double(scale))
    }

    func feed(text: String) {
        view.feed(text: text)
        settle()
    }

    func apply(fontSize: Double) {
        guard fontSize != appliedSize else { return }
        appliedSize = fontSize
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        setNeedsGraphics()
    }

    func apply(dark: Bool) {
        guard appliedDark != dark else { return }
        appliedDark = dark
        func color(_ entry: PaletteColor) -> UIColor {
            let c = entry.components(dark: dark)
            return UIColor(red: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
        }
        let ansi = TerminalPalette.ansi.map { entry in
            let c = entry.components(dark: dark)
            return Color(red: UInt16(c.red) * 257, green: UInt16(c.green) * 257, blue: UInt16(c.blue) * 257)
        }
        view.installColors(ansi)
        stage.paint(background: color(TerminalPalette.background))
        view.nativeForegroundColor = color(TerminalPalette.foreground)
        view.caretColor = color(TerminalPalette.cursor)
        view.selectedTextBackgroundColor = color(TerminalPalette.selection)
        view.keyboardAppearance = dark ? .dark : .light
        view.syncCapturedKeyboardAppearance()
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBase = preferences.fontSize
        case .changed:
            preferences.fontSize = pinchBase * Double(gesture.scale)
        default:
            break
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        setNeedsGraphics()
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeSettle)
            guard !Task.isCancelled else { return }
            self?.onResize?(newCols, newRows)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !replays else { return }
        onInput?(keyBar.transform(typed: data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(data: content, encoding: .utf8)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        guard !replays, case .reply(let bytes) = inlineGraphics.receive(content, cell: cell) else { return }
        onInput?(ArraySlice(bytes))
    }

    private static func inlineImage(_ placement: InlineGraphics.Placement) -> [UInt8] {
        var keys = "File=inline=1"
        keys += argument("width", placement.width)
        keys += argument("height", placement.height)
        if !placement.preserveAspectRatio { keys += ";preserveAspectRatio=0" }
        if !placement.moveCursor { keys += ";doNotMoveCursor=1" }
        let encoded = placement.data.base64EncodedString()
        return Array("\u{1B}]1337;\(keys):\(encoded)\u{1B}\\".utf8)
    }

    private static func argument(_ name: String, _ size: InlineGraphics.Size) -> String {
        switch size {
        case .auto: return ""
        case .cells(let count): return ";\(name)=\(count)"
        case .pixels(let count): return ";\(name)=\(count)px"
        case .percent(let count): return ";\(name)=\(count)%"
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
