import AppKit
import Darwin
import SwiftTerm
import TurmCore

@_silgen_name("shm_open")
private func frameSharedMemoryOpen(_ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32

final class FrameOverlay: NSView {
    var cgImage: CGImage? {
        didSet {
            guard oldValue !== cgImage else { return }
            wantsLayer = true
            layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            layer?.contentsGravity = .resize
            layer?.contents = cgImage
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resize
        return layer
    }
}

final class AltScreenHost: NSObject, TerminalViewDelegate {
    let view: FullScreenTerminalView
    let frameOverlay = FrameOverlay()
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
    private var framePixels = CGSize.zero
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
        view.onWindow = { [weak self] in self?.onWindow() }
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

    func setPointer(_ name: String?) {
        view.pointerName = name
    }

    func showFrame(_ image: NSImage?) {
        guard let image else {
            frameOverlay.cgImage = nil
            framePixels = .zero
            return
        }
        var pixels = image.size
        for representation in image.representations where representation.pixelsWide > 0 && representation.pixelsHigh > 0 {
            pixels = CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
            break
        }
        framePixels = pixels
        frameOverlay.cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Draws a shared-memory frame, leaving every other graphics command to the image decoder.
    func present(_ command: KittyCommand, apc: [UInt8]) -> Bool {
        let payload = KittyGraphicsScanner.payload(of: apc[...])
        switch command.action {
        case "q":
            guard (command.medium ?? "d") == "s" else { return false }
            let opened = FramePixels.openShared(command, payload: payload)
            reply(command, opened ? "OK" : "ENOENT:No such file")
            return true
        case "d":
            if command.deletesAll {
                frameOverlay.cgImage = nil
                framePixels = .zero
            }
            return true
        case "T":
            guard !command.more, command.compression == nil, (command.medium ?? "d") == "s" else { return false }
            guard let made = FramePixels.sharedImage(command, payload: payload) else {
                reply(command, "EBADF:Failed to read image file")
                return true
            }
            framePixels = made.pixels
            frameOverlay.cgImage = made.image
            reply(command, "OK")
            return true
        default:
            return false
        }
    }

    private func reply(_ command: KittyCommand, _ message: String) {
        guard command.quiet == 0 || (command.quiet == 1 && message != "OK") else { return }
        var control = ""
        if let id = command.imageID { control = "i=\(id)" }
        if let placement = command.placementID { control += control.isEmpty ? "p=\(placement)" : ",p=\(placement)" }
        onInput(Array("\u{1B}_G\(control);\(message)\u{1B}\\".utf8))
    }

    var cellPixels: (width: Int, height: Int) {
        let measured = view.cellSizeInPixels(source: view.getTerminal()) ?? (width: 1, height: 1)
        let screenScale = view.window?.screen?.backingScaleFactor
            ?? view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
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

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) { onTitle(title) }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !isReplaying else { return }
        onInput(PixelMouse.scale(data, reportingPixels: reportsPixels, view: view.bounds.size, frame: framePixels))
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
    var onWindow: () -> Void = {}
    var pointerName: String? {
        didSet {
            guard oldValue != pointerName else { return }
            window?.invalidateCursorRects(for: self)
        }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(AttachmentStore.dragTypes)
        _ = Self.installPointerCursor
        window?.invalidateCursorRects(for: self)
        if window != nil { onWindow() }
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

enum FramePixels {
    static func openShared(_ command: KittyCommand, payload: ArraySlice<UInt8>) -> Bool {
        guard let opened = map(command, payload: payload, minimum: 1) else { return false }
        munmap(opened.base, opened.length)
        return true
    }

    static func sharedImage(_ command: KittyCommand, payload: ArraySlice<UInt8>) -> (image: CGImage, pixels: CGSize)? {
        let width = command.stateValue ?? 0
        let height = command.loopValue ?? 0
        let channels = (command.format ?? 32) == 24 ? 3 : 4
        guard width > 0, height > 0, channels == 4 || channels == 3 else { return nil }
        let count = width * height * channels
        guard let opened = map(command, payload: payload, minimum: count) else { return nil }
        defer { munmap(opened.base, opened.length) }
        let rgba = channels == 4 ? Data(bytes: opened.start, count: count) : expand(opened.start, count: count)
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return (image, CGSize(width: width, height: height))
    }

    private static func map(
        _ command: KittyCommand, payload: ArraySlice<UInt8>, minimum: Int
    ) -> (base: UnsafeMutableRawPointer, length: Int, start: UnsafeMutableRawPointer)? {
        guard let encoded = Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters),
              let name = String(data: encoded, encoding: .utf8), name.hasPrefix("/")
        else { return nil }
        let descriptor = name.withCString { frameSharedMemoryOpen($0, O_RDONLY, 0) }
        guard descriptor >= 0 else { return nil }
        defer {
            close(descriptor)
            name.withCString { shm_unlink($0) }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        let length = Int(info.st_size)
        let offset = command.dataOffset
        guard length > offset, length - offset >= minimum else { return nil }
        guard let base = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0), base != MAP_FAILED else { return nil }
        return (base, length, base.advanced(by: offset))
    }

    private static func expand(_ bytes: UnsafeMutableRawPointer, count: Int) -> Data {
        var rgba = Data(count: count / 3 * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let destination = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let source = bytes.assumingMemoryBound(to: UInt8.self)
            var read = 0
            var write = 0
            while read + 2 < count {
                destination[write] = source[read]
                destination[write + 1] = source[read + 1]
                destination[write + 2] = source[read + 2]
                destination[write + 3] = 255
                read += 3
                write += 4
            }
        }
        return rgba
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
