import AppKit
import SwiftTerm
import TurmCore

final class AltScreenHost: NSObject, TerminalViewDelegate {
    let view: FullScreenTerminalView
    var onFiles: ([URL]) -> Void = { _ in } {
        didSet { view.onFiles = onFiles }
    }
    var onDragTarget: (Bool) -> Void = { _ in } {
        didSet { view.onDragTarget = onDragTarget }
    }
    var onInput: ([UInt8]) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }
    var onResize: (Int, Int) -> Void = { _, _ in }
    private var isReplaying = false
    private var graphicHold = GraphicHold()
    private var inlineGraphics = InlineGraphicsSession()

    init(cols: Int, rows: Int) {
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        view = FullScreenTerminalView(frame: .zero, font: nil, options: options)
        super.init()
        view.terminalDelegate = self
    }

    func feed(_ bytes: [UInt8]) {
        let cell = InlineGraphics.Cell(
            height: Double(TerminalMetrics.lineHeight), width: Double(TerminalMetrics.cellWidth), scale: Double(BlockEmulator.backingScale)
        )
        guard let ready = graphicHold.intake(bytes) else { return }
        let split = TerminalGraphics.split(ready)
        for piece in split.pieces {
            switch piece {
            case .bytes(let raw):
                view.feed(byteArray: raw)
            case .sixel(let image):
                guard image.count <= TerminalGraphics.byteLimit else { continue }
                view.feed(byteArray: image)
            case .osc(let payload):
                let text = String(decoding: payload, as: UTF8.self)
                if text.lowercased().hasPrefix("file=") {
                    var sequence = Array("\u{1B}]1337;".utf8)
                    sequence.append(contentsOf: payload)
                    sequence.append(contentsOf: [0x1B, 0x5C])
                    view.feed(byteArray: sequence[...])
                } else if case .reply(let reply) = inlineGraphics.receive(payload, cell: cell) {
                    onInput(reply)
                }
            }
        }
        graphicHold.hold(split.remainder)
    }

    func replay(_ bytes: [UInt8]) {
        isReplaying = true
        view.feed(byteArray: bytes[...])
        isReplaying = false
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

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) { onTitle(title) }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !isReplaying else { return }
        onInput(Array(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) {
        Bell.ring()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func clipboardRead(source: TerminalView) -> Data? {
        ClipboardPermission.readClipboard()
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        let cell = InlineGraphics.Cell(
            height: Double(TerminalMetrics.lineHeight), width: Double(TerminalMetrics.cellWidth), scale: Double(BlockEmulator.backingScale)
        )
        guard case .reply(let bytes) = inlineGraphics.receive(content, cell: cell) else { return }
        onInput(bytes)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class FullScreenTerminalView: TerminalView {
    var onFiles: ([URL]) -> Void = { _ in }
    var onDragTarget: (Bool) -> Void = { _ in }
    var onMouseDown: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(AttachmentStore.dragTypes)
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
