import Foundation

public nonisolated struct WheelScroll: Sendable {
    public static let wheelUp = 64
    public static let wheelDown = 65

    private var remainder = 0.0

    public init() {}

    public mutating func reset() {
        remainder = 0
    }

    public mutating func lines(translation: Double, cellHeight: Double) -> Int {
        guard cellHeight > 0 else { return 0 }
        remainder += translation / cellHeight
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return Int(whole)
    }

    public static func wheelButton(lines: Int) -> Int {
        lines > 0 ? wheelUp : wheelDown
    }

    /// The cursor keys that stand in for the wheel on an alternate screen that reports no mouse.
    public static func arrowKeys(lines: Int, applicationCursor: Bool) -> [UInt8] {
        let final: UInt8 = lines > 0 ? 0x41 : 0x42
        let sequence: [UInt8] = [0x1B, applicationCursor ? 0x4F : 0x5B, final]
        return Array((0..<abs(lines)).map { _ in sequence }.joined())
    }
}
