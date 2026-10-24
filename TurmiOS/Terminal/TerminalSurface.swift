import SwiftTerm
import TurmCore
import UIKit

final class TerminalSurface: NSObject, TerminalViewDelegate {
    let view: TurmTerminalView
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
    var replays = false
    private static let resizeSettle = Duration.milliseconds(120)

    init(preferences: TerminalPreferences = .shared, capturesKeyboard: Bool = false) {
        self.preferences = preferences
        view = TurmTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        super.init()
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
        guard let ready = graphicHold.intake(Array(bytes)) else { return }
        let split = TerminalGraphics.split(ready)
        for piece in split.pieces {
            switch piece {
            case .bytes(let raw):
                view.feed(byteArray: raw)
            case .sixel(let image):
                guard image.count <= TerminalGraphics.byteLimit else { continue }
                view.feed(byteArray: image)
            case .osc(let payload):
                switch inlineGraphics.receive(payload, cell: cell) {
                case .reply(let reply):
                    guard !replays else { continue }
                    onInput?(ArraySlice(reply))
                case .image(let placement):
                    guard placement.data.count <= TerminalGraphics.byteLimit else { continue }
                    view.feed(byteArray: Self.inlineImage(placement)[...])
                case nil:
                    break
                }
            }
        }
        graphicHold.hold(split.remainder)
    }

    private var cell: InlineGraphics.Cell {
        let font = view.font
        let width = max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        let scale = view.window?.windowScene?.screen.scale ?? 2
        return InlineGraphics.Cell(height: Double(font.lineHeight), width: Double(width), scale: Double(scale))
    }

    func feed(text: String) {
        view.feed(text: text)
    }

    func apply(fontSize: Double) {
        guard fontSize != appliedSize else { return }
        appliedSize = fontSize
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
        let background = color(TerminalPalette.background)
        // The cell fill and the view fill are separate. The view is what shows in the margin
        // before the first frame, and beside the grid when the page is wider than the columns.
        view.nativeBackgroundColor = background
        view.backgroundColor = background
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
