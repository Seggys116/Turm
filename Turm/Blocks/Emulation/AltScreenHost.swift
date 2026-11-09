import AppKit
import SwiftTerm
import TurmCore

final class AltScreenHost: NSObject, TerminalViewDelegate {
    let view: FullScreenTerminalView
    let engine = KittyEngine()
    let painter = GraphicsLayerPainter()
    var graphicsOverlay: GraphicsLayerView { view.graphicsOverlay }
    private(set) lazy var graphicsHost = AltScreenGraphicsHost(host: self)
    var onFiles: ([URL]) -> Void = { _ in } {
        didSet { view.onFiles = onFiles }
    }
    var onDragTarget: (Bool) -> Void = { _ in } {
        didSet { view.onDragTarget = onDragTarget }
    }
    var onInput: ([UInt8]) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }
    var onResize: (Int, Int) -> Void = { _, _ in }
    var onWindow: () -> Void = {}
    var reportsPixels = false
    private var isReplaying = false
    private var graphicHold = GraphicHold()
    private var inlineGraphics = InlineGraphicsSession()
    private var intake = KittyStreamIntake()
    private var painted = false

    let remoteName: String?

    init(cols: Int, rows: Int, remoteName: String? = nil) {
        self.remoteName = remoteName
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        view = FullScreenTerminalView(frame: .zero, font: nil, options: options, underlay: painter.underlay, overlay: painter.overlay)
        super.init()
        view.terminalDelegate = self
        view.notifyUpdateChanges = true
        view.onWindow = { [weak self] in self?.onWindow() }
        view.onGeometry = { [weak self] in self?.refreshGraphics() }
        graphicsHost.noteBuffer()
        view.onBufferSwitch = { [weak self] alternate in
            guard let self else { return }
            graphicsHost.noteBuffer()
            engine.bufferSwitched(toAlternate: alternate)
            refreshGraphics()
        }
    }

    @discardableResult
    func feed(_ bytes: [UInt8]) -> [UInt8] {
        process(bytes, live: true)
    }

    func replay(_ bytes: [UInt8]) {
        isReplaying = true
        process(bytes, live: false)
        isReplaying = false
    }

    @discardableResult
    private func process(_ bytes: [UInt8], live: Bool) -> [UInt8] {
        guard let incoming = intake.take(bytes) else { return [] }
        guard incoming.contains(0x1B) else {
            feedText(incoming[...], answering: live)
            afterFeed()
            return incoming
        }
        var kept: [UInt8] = []
        kept.reserveCapacity(incoming.count)
        for piece in intake.split(incoming) {
            switch piece.kind {
            case .text:
                feedText(piece.bytes, answering: live)
                kept.append(contentsOf: piece.bytes)
            case .clear(let scope):
                feedText(piece.bytes, answering: live)
                kept.append(contentsOf: piece.bytes)
                if scope == .scrollback { kept.append(contentsOf: Array("\u{1B}[22J".utf8)) }
                clearGraphics(scope)
            case .graphics:
                guard live || view.getTerminal().isCurrentBufferAlternate else { continue }
                engine.handle(piece.bytes, host: graphicsHost)
            }
        }
        afterFeed()
        return kept
    }

    private func feedText(_ bytes: ArraySlice<UInt8>, answering: Bool) {
        let cell = InlineGraphics.Cell(
            height: Double(TerminalMetrics.lineHeight), width: Double(TerminalMetrics.cellWidth), scale: Double(BlockEmulator.backingScale)
        )
        guard !bytes.isEmpty, let ready = graphicHold.intake(Array(bytes)) else { return }
        let split = TerminalGraphics.split(ready)
        for piece in split.pieces {
            switch piece {
            case .bytes(let raw):
                view.feed(byteArray: raw)
            case .sixel(let image):
                guard image.count <= TerminalGraphics.byteLimit, SixelPrescan.admits(image) else { continue }
                drawSixel(image)
            case .query(let reply):
                if answering, !reply.isEmpty { onInput(reply) }
            case .osc(let payload):
                let isFile = String(decoding: payload.prefix(5), as: UTF8.self).lowercased() == "file="
                switch inlineGraphics.receive(payload, cell: cell) {
                case .reply(let reply):
                    if answering { onInput(reply) }
                case .image(let placement):
                    guard isFile, GraphicsBounds.admits(imageData: placement.data) else { break }
                    var sequence = Array("\u{1B}]1337;".utf8)
                    sequence.append(contentsOf: payload)
                    sequence.append(contentsOf: [0x1B, 0x5C])
                    view.feed(byteArray: sequence[...])
                case nil:
                    break
                }
            }
        }
        graphicHold.hold(split.remainder)
    }

    private func drawSixel(_ sequence: ArraySlice<UInt8>) {
        guard let sixel = SixelDecoder.decode(sequence: sequence), GraphicsBounds.admits(width: sixel.width, height: sixel.height) else { return }
        var pixels = sixel.premultipliedRGBA
        view.createImageFromBitmap(source: view.getTerminal(), bytes: &pixels, width: sixel.width, height: sixel.height)
    }

    private func clearGraphics(_ scope: KittyGraphicsScanner.ClearScope) {
        if scope == .scrollback {
            if let push = view.getTerminal().scrollbackPush() { view.feed(byteArray: push[...]) }
            view.feed(byteArray: Array("\u{1B}[2J".utf8)[...])
        }
        engine.clear(scope, host: graphicsHost)
    }

    private func afterFeed() {
        engine.pruneScrolledOff(trimmed: view.getTerminal().buffer.totalLinesTrimmed)
        if engine.revision != shownRevision { refreshGraphics() }
    }

    private var shownRevision: UInt64 = .max

    func refreshGraphics() {
        let terminal = view.getTerminal()
        guard !terminal.synchronizedOutputActive else { return }
        engine.bufferSwitched(toAlternate: terminal.isCurrentBufferAlternate)
        shownRevision = engine.revision
        let store = engine.activeStore
        guard !store.images.isEmpty || !store.virtualPlacements.isEmpty else {
            if painted {
                painter.removeAll()
                painted = false
            }
            return
        }
        let buffer = terminal.buffer
        let top = buffer.yDisp + buffer.totalLinesTrimmed
        let cell = cellPoints
        let geometry = GraphicsLayerPainter.Geometry(
            top: top, cellWidth: cell.width, cellHeight: cell.height, scale: view.window?.backingScaleFactor ?? screenScale
        )
        painter.update(placements: engine.placements(visible: top..<(top + terminal.rows), host: graphicsHost), geometry: geometry)
        painted = true
    }

    func graphicsReply(_ bytes: [UInt8]) {
        guard !isReplaying else { return }
        onInput(bytes)
    }

    func apply(dark: Bool) {
        view.nativeBackgroundColor = Theme.terminalBackground.resolved(dark: dark)
        view.nativeForegroundColor = Theme.text.resolved(dark: dark)
        view.installColors(TerminalPalette.engineColors(dark: dark))
    }

    func focus() {
        guard let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    func setPointer(_ name: String?) {
        view.pointerName = name
    }

    var grid: (cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    func repaint() {
        view.getTerminal().updateFullScreen()
        view.needsDisplay = true
        refreshGraphics()
    }

    var screenScale: CGFloat {
        view.window?.screen?.backingScaleFactor
            ?? view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    var cellPoints: (width: CGFloat, height: CGFloat) {
        let measured = view.cellSizeInPixels(source: view.getTerminal()) ?? (width: 1, height: 1)
        let drawnScale = view.window?.backingScaleFactor ?? 1
        return (max(CGFloat(measured.width) / drawnScale, 1), max(CGFloat(measured.height) / drawnScale, 1))
    }

    var cellPixels: (width: Int, height: Int) {
        let measured = view.cellSizeInPixels(source: view.getTerminal()) ?? (width: 1, height: 1)
        let screenScale = screenScale
        let drawnScale = view.window?.backingScaleFactor ?? 1
        guard drawnScale > 0, abs(drawnScale - screenScale) > 0.01 else {
            return (max(measured.width, 1), max(measured.height, 1))
        }
        let factor = screenScale / drawnScale
        return (
            max(1, Int((CGFloat(measured.width) * factor).rounded())),
            max(1, Int((CGFloat(measured.height) * factor).rounded()))
        )
    }

    var panePixels: CGSize {
        let size = view.bounds.size
        return CGSize(width: size.width * screenScale, height: size.height * screenScale)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize(newCols, newRows)
        refreshGraphics()
    }

    func setTerminalTitle(source: TerminalView, title: String) { onTitle(title) }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !isReplaying else { return }
        onInput(PixelMouse.scale(data, reportingPixels: reportsPixels, view: view.bounds.size, frame: panePixels))
    }

    func scrolled(source: TerminalView, position: Double) {
        refreshGraphics()
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), LinkPolicy.allows(url, remote: remoteName != nil) else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        Bell.ring()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let remoteName, !ClipboardPermission.allowWrite(from: remoteName) { return }
        NSPasteboard.general.clearContents()
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func clipboardRead(source: TerminalView) -> Data? {
        ClipboardPermission.readClipboard(from: remoteName)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        let cell = InlineGraphics.Cell(
            height: Double(TerminalMetrics.lineHeight), width: Double(TerminalMetrics.cellWidth), scale: Double(BlockEmulator.backingScale)
        )
        guard case .reply(let bytes) = inlineGraphics.receive(content, cell: cell) else { return }
        onInput(bytes)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        let store = engine.activeStore
        guard painted || !store.virtualPlacements.isEmpty || engine.revision != shownRevision else { return }
        refreshGraphics()
    }
}

final class FullScreenTerminalView: TerminalView {
    var onFiles: ([URL]) -> Void = { _ in }
    var onDragTarget: (Bool) -> Void = { _ in }
    var onMouseDown: () -> Void = {}
    var onWindow: () -> Void = {}
    var onGeometry: () -> Void = {}
    var onBufferSwitch: (Bool) -> Void = { _ in }
    let graphicsBackdrop: GraphicsLayerView
    let graphicsOverlay: GraphicsLayerView
    var pointerName: String? {
        didSet {
            guard oldValue != pointerName else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(frame: CGRect, font: NSFont?, options: TerminalOptions, underlay: CALayer, overlay: CALayer) {
        graphicsBackdrop = GraphicsLayerView(content: underlay)
        graphicsOverlay = GraphicsLayerView(content: overlay)
        super.init(frame: frame, font: font, options: options)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FullScreenTerminalView is created in code only")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = ForwardedBackgroundLayer()
        layer.onBackground = { [weak self] color in self?.graphicsBackdrop.fill = color }
        return layer
    }

    private static let installPointerCursor: Void = {
        let replacement = #selector(FullScreenTerminalView.installPointerCursorRects)
        guard let method = class_getInstanceMethod(FullScreenTerminalView.self, replacement) else { return }
        _ = class_addMethod(
            FullScreenTerminalView.self, #selector(NSView.resetCursorRects),
            method_getImplementation(method), method_getTypeEncoding(method)
        )
    }()

    @objc private func installPointerCursorRects() {
        addCursorRect(bounds, cursor: PointerCursor.cursor(named: pointerName))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else {
            graphicsBackdrop.removeFromSuperview()
            graphicsOverlay.removeFromSuperview()
            return
        }
        superview.addSubview(graphicsBackdrop, positioned: .below, relativeTo: self)
        if graphicsOverlay.superview !== superview { superview.addSubview(graphicsOverlay, positioned: .above, relativeTo: self) }
        alignGraphics()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        alignGraphics()
        onGeometry()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        alignGraphics()
    }

    private func alignGraphics() {
        for layerView in [graphicsBackdrop, graphicsOverlay] where layerView.superview === superview {
            layerView.frame = frame
        }
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onBufferSwitch(source.isCurrentBufferAlternate)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(AttachmentStore.dragTypes)
        _ = Self.installPointerCursor
        window?.invalidateCursorRects(for: self)
        if window != nil { onWindow() }
        onGeometry()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard AttachmentStore.canAccept(sender.draggingPasteboard) else { return [] }
        onDragTarget(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        AttachmentStore.canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTarget(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        AttachmentStore.canAccept(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragTarget(false)
        let urls = AttachmentStore.urls(from: sender.draggingPasteboard, imageOverridesText: true)
        guard !urls.isEmpty else { return false }
        onFiles(urls)
        return true
    }

    override func paste(_ sender: Any) {
        let urls = AttachmentStore.urls(from: .general, imageOverridesText: false)
        if urls.isEmpty {
            super.paste(sender)
        } else {
            onFiles(urls)
        }
    }
}

enum PointerCursor {
    static func cursor(named name: String?) -> NSCursor {
        switch name {
        case "text", "vertical-text":
            return .iBeam
        case "crosshair", "cell":
            return .crosshair
        case "pointer":
            return .pointingHand
        case "grab", "move":
            return .openHand
        case "grabbing":
            return .closedHand
        case "e-resize", "w-resize", "ew-resize", "nwse-resize", "nw-resize", "se-resize":
            return .resizeLeftRight
        case "n-resize", "s-resize", "ns-resize", "nesw-resize", "ne-resize", "sw-resize":
            return .resizeUpDown
        case "not-allowed", "no-drop":
            return .operationNotAllowed
        case "alias":
            return .dragLink
        case "copy":
            return .dragCopy
        case nil:
            return .iBeam
        default:
            return .arrow
        }
    }
}
