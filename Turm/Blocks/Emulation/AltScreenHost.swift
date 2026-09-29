import AppKit
import SwiftTerm

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

    init(cols: Int, rows: Int) {
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        view = FullScreenTerminalView(frame: .zero, font: nil, options: options)
        super.init()
        view.terminalDelegate = self
    }

    func feed(_ bytes: [UInt8]) {
        view.feed(byteArray: bytes[...])
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

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class FullScreenTerminalView: TerminalView {
    var onFiles: ([URL]) -> Void = { _ in }
    var onDragTarget: (Bool) -> Void = { _ in }

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
