import SwiftTerm
import TurmCore
import UIKit

final class TerminalSurface: NSObject, TerminalViewDelegate {
    let view: TerminalView
    let keyBar = TerminalKeyBarView()
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?

    private let preferences: TerminalPreferences
    private var pinchBase = 0.0
    private var appliedDark: Bool?
    private var appliedSize = 0.0
    private var resizeTask: Task<Void, Never>?
    private static let resizeSettle = Duration.milliseconds(120)

    init(preferences: TerminalPreferences = .shared) {
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
        view.feed(byteArray: bytes)
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
        view.nativeBackgroundColor = color(TerminalPalette.background)
        view.nativeForegroundColor = color(TerminalPalette.foreground)
        view.caretColor = color(TerminalPalette.cursor)
        view.selectedTextBackgroundColor = color(TerminalPalette.selection)
        view.keyboardAppearance = dark ? .dark : .light
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

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
