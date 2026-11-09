import AppKit
import SwiftTerm
import TurmCore

final class AltScreenGraphicsHost: GraphicsHost {
    unowned let host: AltScreenHost
    private let screens = ScreenBuffers<Buffer>()

    init(host: AltScreenHost) {
        self.host = host
    }

    private var terminal: Terminal {
        host.view.getTerminal()
    }

    var cursor: GridPoint {
        let buffer = terminal.buffer
        return GridPoint(row: buffer.yDisp + buffer.y + buffer.totalLinesTrimmed, column: buffer.x)
    }

    var screen: GraphicsScreen {
        let buffer = terminal.buffer
        let cell = host.cellPixels
        return GraphicsScreen(
            columns: terminal.cols, rows: terminal.rows, top: buffer.yDisp + buffer.totalLinesTrimmed,
            alternate: terminal.isCurrentBufferAlternate, cellWidth: cell.width, cellHeight: cell.height,
            scale: Double(host.screenScale)
        )
    }

    var allowsLocalMedia: Bool {
        host.remoteName == nil
    }

    func feedTerminal(_ bytes: ArraySlice<UInt8>) {
        host.view.feed(byteArray: bytes)
    }

    func reply(_ bytes: [UInt8]) {
        host.graphicsReply(bytes)
    }

    func placeholderCells(rows: Range<Int>, buffer: GraphicsBuffer) -> [GraphicsCell] {
        terminal.placeholderCells(rows: rows, of: buffer, screens: screens)
    }

    func noteBuffer() {
        screens.note(terminal)
    }
}

final class GraphicsLayerView: NSView {
    private let content: CALayer

    init(content: CALayer) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        content.isGeometryFlipped = true
        layer?.addSublayer(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GraphicsLayerView is created in code only")
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.masksToBounds = true
        return layer
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = CGRect(origin: .zero, size: newSize)
        CATransaction.commit()
    }

    var fill: CGColor? {
        get { layer?.backgroundColor }
        set { layer?.backgroundColor = newValue }
    }
}

final class ForwardedBackgroundLayer: CALayer {
    var onBackground: (CGColor?) -> Void = { _ in }

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ForwardedBackgroundLayer is created in code only")
    }

    override var backgroundColor: CGColor? {
        get { super.backgroundColor }
        set {
            onBackground(newValue)
            super.backgroundColor = nil
        }
    }
}
