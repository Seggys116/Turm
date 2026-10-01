import TurmCore
import UIKit

final class KeyBarButton: UIControl {
    enum Mode {
        case idle
        case armed
        case locked
    }

    static let height: CGFloat = 36
    private static let holdDelay: TimeInterval = 0.4
    private static let repeatInterval: TimeInterval = 0.055

    let key: TerminalKey
    var onActivate: ((TerminalKey) -> Void)?
    var repeats = false

    var mode = Mode.idle {
        didSet { if mode != oldValue { restyle() } }
    }

    override var isHighlighted: Bool {
        didSet { restyle() }
    }

    private let content = UIStackView()
    private var holdTimer: Timer?
    private var repeatTimer: Timer?
    private var didRepeat = false

    init(key: TerminalKey) {
        self.key = key
        super.init(frame: .zero)
        layer.cornerRadius = Chrome.Radius.chip
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = key.name
        buildContent()
        addTarget(self, action: #selector(touchedDown), for: .touchDown)
        addTarget(self, action: #selector(touchedUp), for: .touchUpInside)
        addTarget(self, action: #selector(touchEnded), for: [.touchUpOutside, .touchCancel])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.restyle() }
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    private func buildContent() {
        content.isUserInteractionEnabled = false
        content.alignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        if let symbol = key.symbol {
            let image = UIImageView(image: UIImage(systemName: symbol))
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            image.contentMode = .scaleAspectFit
            content.addArrangedSubview(image)
        } else {
            let text = UILabel()
            text.text = key.label
            text.font = Self.font(for: key.label)
            content.addArrangedSubview(text)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            trailingAnchor.constraint(greaterThanOrEqualTo: content.trailingAnchor, constant: 10),
        ])
    }

    private static func font(for label: String) -> UIFont {
        if label.count == 1 {
            return .monospacedSystemFont(ofSize: 16, weight: .medium)
        }
        let base = UIFont.systemFont(ofSize: 13, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 13) } ?? base
    }

    private func restyle() {
        let fill: UIColor
        let stroke: UIColor
        let foreground: UIColor
        switch mode {
        case .idle:
            fill = isHighlighted ? Chrome.UI.chipFillPressed : Chrome.UI.chipFill
            stroke = Chrome.UI.chipStroke
            foreground = Chrome.UI.text
        case .armed:
            fill = Chrome.UI.accent.withAlphaComponent(isHighlighted ? 0.32 : 0.2)
            stroke = Chrome.UI.accent.withAlphaComponent(0.7)
            foreground = Chrome.UI.accent
        case .locked:
            fill = Chrome.UI.accent
            stroke = Chrome.UI.accent
            foreground = Chrome.UI.onAccent
        }
        backgroundColor = fill.resolvedColor(with: traitCollection)
        layer.borderColor = stroke.resolvedColor(with: traitCollection).cgColor
        for case let label as UILabel in content.arrangedSubviews { label.textColor = foreground }
        for case let image as UIImageView in content.arrangedSubviews { image.tintColor = foreground }
        accessibilityValue = switch mode {
        case .idle: nil
        case .armed: "Armed"
        case .locked: "Locked"
        }
    }

    @objc private func touchedDown() {
        guard repeats else { return }
        let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginRepeating() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    @objc private func touchedUp() {
        let wasRepeating = didRepeat
        stopTimers()
        if !wasRepeating { onActivate?(key) }
    }

    @objc private func touchEnded() {
        stopTimers()
    }

    private func beginRepeating() {
        didRepeat = true
        onActivate?(key)
        let timer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.onActivate?(self.key)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopTimers() {
        holdTimer?.invalidate()
        holdTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        didRepeat = false
    }

    override func accessibilityActivate() -> Bool {
        onActivate?(key)
        return true
    }
}
