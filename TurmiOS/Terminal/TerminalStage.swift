import SwiftTerm
import UIKit

final class TerminalStage: UIView {
    let terminal: TurmTerminalView
    let underlay = CALayer()
    private(set) var background = UIColor.black
    private var seeThrough = false
    private var reversed = false
    private var reverseFill: UIColor?

    init(terminal: TurmTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        clipsToBounds = true
        underlay.masksToBounds = true
        layer.insertSublayer(underlay, at: 0)
        adopt()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func adopt() {
        guard terminal.superview !== self else { return }
        terminal.frame = bounds
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(terminal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underlay.frame = terminal.superview === self ? terminal.frame : bounds
        CATransaction.commit()
    }

    func paint(background color: UIColor) {
        background = color
        backgroundColor = color
        if seeThrough, !reversed {
            terminal.backgroundColor = color.withAlphaComponent(0)
            terminal.clearedBackground = color
        } else {
            terminal.nativeBackgroundColor = color
            terminal.backgroundColor = color
        }
    }

    func showUnderlay(_ shown: Bool) {
        guard shown != seeThrough else { return }
        seeThrough = shown
        reversed = false
        reverseFill = nil
        if shown {
            terminal.nativeBackgroundColor = .clear
            terminal.backgroundColor = background.withAlphaComponent(0)
            terminal.clearedBackground = background
        } else {
            terminal.nativeBackgroundColor = background
            terminal.backgroundColor = background
            terminal.clearedBackground = nil
        }
    }

    func reconcile() {
        let native = terminal.nativeBackgroundColor
        guard seeThrough else {
            if Self.alpha(native) > 0, !Self.same(native, background) {
                background = native
                backgroundColor = native
            }
            return
        }
        let fill = terminal.layer.backgroundColor.map { UIColor(cgColor: $0) }
        if reversed {
            if Self.alpha(native) > 0, !Self.same(native, background) {
                background = native
                backgroundColor = native
            }
            guard let fill, let reverseFill, !Self.same(fill, reverseFill) || Self.alpha(fill) == 0 else { return }
            reversed = false
            self.reverseFill = nil
            terminal.nativeBackgroundColor = .clear
            terminal.backgroundColor = background.withAlphaComponent(0)
            terminal.clearedBackground = background
            return
        }
        if Self.alpha(native) > 0 {
            background = native
            backgroundColor = native
            terminal.nativeBackgroundColor = .clear
            terminal.backgroundColor = native.withAlphaComponent(0)
            terminal.clearedBackground = native
            return
        }
        guard let fill, Self.alpha(fill) > 0 else { return }
        if Self.same(fill, background) {
            terminal.backgroundColor = background.withAlphaComponent(0)
            return
        }
        reversed = true
        reverseFill = fill
        terminal.nativeBackgroundColor = background
        terminal.clearedBackground = nil
    }

    private static func alpha(_ color: UIColor) -> CGFloat {
        color.cgColor.alpha
    }

    private static func same(_ first: UIColor, _ second: UIColor) -> Bool {
        var a = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var b = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        guard first.getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3), second.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3) else {
            return false
        }
        let tolerance: CGFloat = 1 / 512
        return abs(a.0 - b.0) < tolerance && abs(a.1 - b.1) < tolerance && abs(a.2 - b.2) < tolerance
    }
}
