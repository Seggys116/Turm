import SwiftUI
import TurmCore
import UIKit

final class TerminalKeyBarView: UIInputView {
    static let height: CGFloat = 46
    private static let doubleTapWindow: TimeInterval = 0.4
    private static let padStepX: CGFloat = 16
    private static let padStepY: CGFloat = 24
    private static let functionPageKey = TerminalKey(id: "fn", kind: .functionPage, name: "Function keys", label: "fn")
    private static let mainPageKey = TerminalKey(id: "abc", kind: .functionPage, name: "Main keys", label: "abc")
    private static let hideKey = TerminalKey(id: "hide", kind: .hideKeyboard, name: "Hide keyboard", symbol: "keyboard.chevron.compact.down")

    var onBytes: ((Data) -> Void)?
    var onPaste: (() -> Void)?
    var onHide: (() -> Void)?
    var applicationCursor = false
    var cursorMode: (() -> Bool)?

    private enum Sticky {
        case off
        case once
        case locked

        var buttonMode: KeyBarButton.Mode {
            switch self {
            case .off: .idle
            case .once: .armed
            case .locked: .locked
            }
        }
    }

    private enum Page {
        case main
        case functions
    }

    private let layout: KeyBarLayout
    private let scroll = UIScrollView()
    private let keysStack = UIStackView()
    private let pinned = UIStackView()
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private var buttons: [KeyBarButton] = []
    private var ctrl = Sticky.off
    private var alt = Sticky.off
    private var page = Page.main
    private var lastModifierTap: (kind: KeyKind, time: TimeInterval)?
    private var padOrigin = CGPoint.zero
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(layout: KeyBarLayout = .shared) {
        self.layout = layout
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        clipsToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)
        build()
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: KeyBarLayout.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    var activeModifiers: KeyModifiers {
        var modifiers: KeyModifiers = []
        if ctrl != .off { modifiers.insert(.ctrl) }
        if alt != .off { modifiers.insert(.alt) }
        return modifiers
    }

    /// Rewrites one typed character with the armed modifiers and releases the one-shot ones.
    func transform(typed data: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard let modified = KeyBarEncoder.modify(typed: data, modifiers: activeModifiers) else { return data }
        _ = takeModifiers()
        return ArraySlice(modified)
    }

    // the keyboard below has rounded top corners, so the bar's colour runs on underneath them
    private static let backdropOverhang: CGFloat = 48

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + Self.backdropOverhang)).cgPath
    }

    private func build() {
        let backdrop = UIView()
        backdrop.backgroundColor = Chrome.UI.topBar
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Self.backdropOverhang),
        ])
        let hairline = UIView()
        hairline.backgroundColor = Chrome.UI.divider
        let separator = UIView()
        separator.backgroundColor = Chrome.UI.divider
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        keysStack.axis = .horizontal
        keysStack.spacing = 6
        keysStack.alignment = .center
        pinned.axis = .horizontal
        pinned.spacing = 6
        pinned.alignment = .center
        for view in [hairline, separator, scroll, pinned, keysStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(scroll)
        addSubview(separator)
        addSubview(pinned)
        addSubview(hairline)
        scroll.addSubview(keysStack)
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            pinned.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            pinned.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.trailingAnchor.constraint(equalTo: pinned.leadingAnchor, constant: -8),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 22),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            keysStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            keysStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            keysStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            keysStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            keysStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    private func rebuild() {
        for view in keysStack.arrangedSubviews + pinned.arrangedSubviews { view.removeFromSuperview() }
        let keys: [TerminalKey] = switch page {
        case .main: layout.keys
        case .functions: TerminalKey.catalog.filter(\.isModifier) + TerminalKey.functionKeys
        }
        buttons = keys.map(makeButton)
        for button in buttons { keysStack.addArrangedSubview(button) }
        let pageButton = makeButton(page == .main ? Self.functionPageKey : Self.mainPageKey)
        pinned.addArrangedSubview(pageButton)
        pinned.addArrangedSubview(makeButton(Self.hideKey))
        refreshModifiers()
    }

    private func makeButton(_ key: TerminalKey) -> KeyBarButton {
        let button = KeyBarButton(key: key)
        button.onActivate = { [weak self] key in self?.activate(key) }
        switch key.kind {
        case .arrow, .navigation, .tab:
            button.repeats = true
        case .pad:
            let drag = UILongPressGestureRecognizer(target: self, action: #selector(padMoved(_:)))
            drag.minimumPressDuration = 0.1
            drag.allowableMovement = .greatestFiniteMagnitude
            button.addGestureRecognizer(drag)
        default:
            break
        }
        return button
    }

    private func activate(_ key: TerminalKey) {
        switch key.kind {
        case .control:
            tapModifier(.control, \.ctrl)
        case .alt:
            tapModifier(.alt, \.alt)
        case .paste:
            feedback()
            onPaste?()
        case .pad:
            break
        case .functionPage:
            feedback()
            page = page == .main ? .functions : .main
            UIView.transition(with: self, duration: 0.18, options: .transitionCrossDissolve) { self.rebuild() }
        case .hideKeyboard:
            feedback()
            if let onHide {
                onHide()
            } else {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        default:
            feedback()
            emit(key.kind)
        }
    }

    private func tapModifier(_ kind: KeyKind, _ state: ReferenceWritableKeyPath<TerminalKeyBarView, Sticky>) {
        let now = ProcessInfo.processInfo.systemUptime
        let doubled = lastModifierTap.map { $0.kind == kind && now - $0.time < Self.doubleTapWindow } ?? false
        lastModifierTap = (kind, now)
        switch (self[keyPath: state], doubled) {
        case (.off, _):
            self[keyPath: state] = .once
            feedback()
        case (.once, true):
            self[keyPath: state] = .locked
            if layout.haptics { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        case (.once, false), (.locked, _):
            self[keyPath: state] = .off
            feedback()
        }
        refreshModifiers()
    }

    private func takeModifiers() -> KeyModifiers {
        let modifiers = activeModifiers
        if ctrl == .once { ctrl = .off }
        if alt == .once { alt = .off }
        if !modifiers.isEmpty { refreshModifiers() }
        return modifiers
    }

    private func refreshModifiers() {
        for button in buttons {
            switch button.key.kind {
            case .control: button.mode = ctrl.buttonMode
            case .alt: button.mode = alt.buttonMode
            default: break
            }
        }
    }

    private func emit(_ kind: KeyKind) {
        let modifiers = takeModifiers()
        let cursor = cursorMode?() ?? applicationCursor
        guard let bytes = KeyBarEncoder.bytes(for: kind, modifiers: modifiers, applicationCursor: cursor) else { return }
        onBytes?(Data(bytes))
    }

    private func feedback() {
        if layout.haptics { impact.impactOccurred() }
    }

    @objc private func padMoved(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            padOrigin = gesture.location(in: self)
            scroll.isScrollEnabled = false
            selection.prepare()
            feedback()
        case .changed:
            let point = gesture.location(in: self)
            stepPad(&padOrigin.x, to: point.x, size: Self.padStepX, negative: .left, positive: .right)
            stepPad(&padOrigin.y, to: point.y, size: Self.padStepY, negative: .up, positive: .down)
        case .ended, .cancelled, .failed:
            scroll.isScrollEnabled = true
        default:
            break
        }
    }

    private func stepPad(_ origin: inout CGFloat, to value: CGFloat, size: CGFloat, negative: Arrow, positive: Arrow) {
        while abs(value - origin) >= size {
            let forward = value > origin
            origin += forward ? size : -size
            emit(.arrow(forward ? positive : negative))
            if layout.haptics { selection.selectionChanged() }
        }
    }
}

struct TerminalKeyBar: UIViewRepresentable {
    var onBytes: ((Data) -> Void)?
    var onPaste: (() -> Void)?
    var applicationCursor = false

    func makeUIView(context: Context) -> TerminalKeyBarView {
        let view = TerminalKeyBarView()
        configure(view)
        return view
    }

    func updateUIView(_ view: TerminalKeyBarView, context: Context) {
        configure(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TerminalKeyBarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: TerminalKeyBarView.height)
    }

    private func configure(_ view: TerminalKeyBarView) {
        view.onBytes = onBytes
        view.onPaste = onPaste
        view.applicationCursor = applicationCursor
    }
}
