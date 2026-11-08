import AppKit
import SwiftTerm
import TurmCore

final class AltScreenGraphicsHost: GraphicsHost {
    unowned let host: AltScreenHost

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

    func placeholderCells(rows: Range<Int>) -> [GraphicsCell] {
        let terminal = terminal
        let buffer = terminal.buffer
        let trimmed = buffer.totalLinesTrimmed
        let lower = max(rows.lowerBound, trimmed)
        let upper = min(rows.upperBound, trimmed + buffer.yDisp + terminal.rows)
        guard lower < upper else { return [] }
        var cells: [GraphicsCell] = []
        for row in lower..<upper {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            for column in 0..<line.count {
                let data = line[column]
                if data.width == 0 { continue }
                let character = terminal.getCharacter(for: data)
                guard KittyPlaceholders.isPlaceholder(character) else { continue }
                let attribute = data.attribute
                cells.append(GraphicsCell(
                    point: GridPoint(row: row, column: column), character: character,
                    foreground: BlockGraphicsHost.color(attribute.fg),
                    underline: attribute.underlineColor.map(BlockGraphicsHost.color) ?? .none,
                    background: BlockGraphicsHost.color(attribute.style.contains(.inverse) ? attribute.fg : attribute.bg)
                ))
            }
        }
        return cells
    }
}

/// Holds one painter layer over the whole terminal, y running down from the top row.
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

/// SwiftTerm paints the default background through its layer colour; this hands that colour to the
/// view behind the text instead, so images under the text show wherever no cell background is drawn.
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
