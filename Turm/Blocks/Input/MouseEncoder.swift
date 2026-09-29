import CoreGraphics
import Foundation
import SwiftTerm

enum MouseTracking: Equatable {
    case off
    case x10
    case normal
    case button
    case any

    init(_ mode: Terminal.MouseMode) {
        switch mode {
        case .off: self = .off
        case .x10: self = .x10
        case .vt200: self = .normal
        case .buttonEventTracking: self = .button
        case .anyEvent: self = .any
        }
    }
}

enum MouseEncoding: Equatable {
    case x10
    case utf8
    case sgr
    case urxvt
    case sgrPixels

    init?(privateMode: Int) {
        switch privateMode {
        case 1005: self = .utf8
        case 1006: self = .sgr
        case 1015: self = .urxvt
        case 1016: self = .sgrPixels
        default: return nil
        }
    }

    var reportsReleaseButton: Bool {
        self == .sgr || self == .sgrPixels
    }
}

enum MouseButton: Int {
    case left = 0
    case middle = 1
    case right = 2
    case wheelUp = 64
    case wheelDown = 65
    case wheelLeft = 66
    case wheelRight = 67

    var isWheel: Bool {
        rawValue >= 64
    }
}

enum MouseAction {
    case press
    case release
    case motion
}

struct MouseModifiers: OptionSet {
    let rawValue: Int

    static let shift = MouseModifiers(rawValue: 4)
    static let alt = MouseModifiers(rawValue: 8)
    static let control = MouseModifiers(rawValue: 16)
}

struct MouseEvent {
    var action: MouseAction
    var button: MouseButton?
    var modifiers: MouseModifiers = []
    var x: CGFloat
    var y: CGFloat
}

struct MouseGrid: Equatable {
    var cols: Int
    var rows: Int
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var scale: CGFloat = 1

    func cell(x: CGFloat, y: CGFloat) -> (col: Int, row: Int) {
        (Self.clamp(x / cellWidth, to: cols), Self.clamp(y / cellHeight, to: rows))
    }

    func pixel(x: CGFloat, y: CGFloat) -> (x: Int, y: Int) {
        (
            Self.clamp(x * scale, to: Int((CGFloat(cols) * cellWidth * scale).rounded())),
            Self.clamp(y * scale, to: Int((CGFloat(rows) * cellHeight * scale).rounded()))
        )
    }

    private static func clamp(_ value: CGFloat, to count: Int) -> Int {
        guard value.isFinite else { return 0 }
        let index = Int(max(value, 0).rounded(.down))
        return min(index, max(count - 1, 0))
    }
}

enum MouseEncoder {
    static func encode(_ event: MouseEvent, tracking: MouseTracking, encoding: MouseEncoding, grid: MouseGrid) -> [UInt8]? {
        guard tracking != .off, let code = buttonCode(for: event, tracking: tracking, encoding: encoding) else { return nil }
        let cell = grid.cell(x: event.x, y: event.y)
        let released = event.action == .release
        switch encoding {
        case .x10:
            guard cell.col + 1 <= 223, cell.row + 1 <= 223 else { return nil }
            return [0x1B, 0x5B, 0x4D, UInt8(code + 32), UInt8(cell.col + 33), UInt8(cell.row + 33)]
        case .utf8:
            guard let button = utf8Value(code + 32), let col = utf8Value(cell.col + 33), let row = utf8Value(cell.row + 33) else { return nil }
            return [0x1B, 0x5B, 0x4D] + button + col + row
        case .urxvt:
            return Array("\u{1B}[\(code + 32);\(cell.col + 1);\(cell.row + 1)M".utf8)
        case .sgr:
            return Array("\u{1B}[<\(code);\(cell.col + 1);\(cell.row + 1)\(released ? "m" : "M")".utf8)
        case .sgrPixels:
            let pixel = grid.pixel(x: event.x, y: event.y)
            return Array("\u{1B}[<\(code);\(pixel.x);\(pixel.y)\(released ? "m" : "M")".utf8)
        }
    }

    private static func buttonCode(for event: MouseEvent, tracking: MouseTracking, encoding: MouseEncoding) -> Int? {
        var code: Int
        switch event.action {
        case .press:
            guard let button = event.button else { return nil }
            code = button.rawValue
        case .release:
            guard tracking != .x10, let button = event.button, !button.isWheel else { return nil }
            code = encoding.reportsReleaseButton ? button.rawValue : 3
        case .motion:
            guard tracking == .button || tracking == .any else { return nil }
            if let button = event.button {
                guard !button.isWheel else { return nil }
                code = button.rawValue | 32
            } else {
                guard tracking == .any else { return nil }
                code = 3 | 32
            }
        }
        if tracking != .x10 {
            code |= event.modifiers.rawValue
        }
        return code
    }

    private static func utf8Value(_ value: Int) -> [UInt8]? {
        switch value {
        case 0..<128:
            return [UInt8(value)]
        case 128..<2048:
            return [UInt8(0xC0 | (value >> 6)), UInt8(0x80 | (value & 0x3F))]
        default:
            return nil
        }
    }
}

struct WheelAccumulator {
    private var remainder: CGFloat = 0

    mutating func steps(delta: CGFloat, unit: CGFloat) -> Int {
        guard delta.isFinite, unit > 0 else { return 0 }
        if remainder != 0, (remainder < 0) != (delta < 0) {
            remainder = 0
        }
        remainder += delta
        let whole = Int((remainder / unit).rounded(.towardZero))
        remainder -= CGFloat(whole) * unit
        return whole
    }

    mutating func reset() {
        remainder = 0
    }
}
