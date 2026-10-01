import CoreGraphics
import Foundation
import SwiftUI

public nonisolated enum SVGPath {
    public static func path(from data: String) -> Path? {
        var parser = Parser(Array(data.utf8))
        return parser.run()
    }

    private nonisolated struct Parser {
        let bytes: [UInt8]
        var index = 0
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        var needsMove = false

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func run() -> Path? {
            var command: UInt8?
            var started = false
            while true {
                skipSeparators()
                guard index < bytes.count else { break }
                let byte = bytes[index]
                if Self.isCommand(byte) {
                    command = byte
                    index += 1
                } else if command == nil {
                    return nil
                }
                guard let active = command else { return nil }
                if !started, active != UInt8(ascii: "M"), active != UInt8(ascii: "m") { return nil }
                started = true
                guard let next = apply(active) else { return nil }
                command = next
            }
            return started ? path : nil
        }

        static func isCommand(_ byte: UInt8) -> Bool {
            "MmLlHhVvCcSsQqTtAaZz".utf8.contains(byte)
        }

        mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || (0x09...0x0D).contains(bytes[index]) {
                index += 1
            }
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = index
            var cursor = index
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "+") || bytes[cursor] == UInt8(ascii: "-") { cursor += 1 }
            var digits = 0
            while cursor < bytes.count, Self.isDigit(bytes[cursor]) {
                cursor += 1
                digits += 1
            }
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ".") {
                cursor += 1
                while cursor < bytes.count, Self.isDigit(bytes[cursor]) {
                    cursor += 1
                    digits += 1
                }
            }
            guard digits > 0 else { return nil }
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "e") || bytes[cursor] == UInt8(ascii: "E") {
                var exponent = cursor + 1
                if exponent < bytes.count, bytes[exponent] == UInt8(ascii: "+") || bytes[exponent] == UInt8(ascii: "-") { exponent += 1 }
                if exponent < bytes.count, Self.isDigit(bytes[exponent]) {
                    while exponent < bytes.count, Self.isDigit(bytes[exponent]) { exponent += 1 }
                    cursor = exponent
                }
            }
            guard let value = Double(String(decoding: bytes[begin..<cursor], as: UTF8.self)), value.isFinite else { return nil }
            index = cursor
            return value
        }

        static func isDigit(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte)
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            guard byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else { return nil }
            index += 1
            return byte == UInt8(ascii: "1")
        }

        mutating func numbers(_ count: Int) -> [Double]? {
            var values: [Double] = []
            for _ in 0..<count {
                guard let value = number() else { return nil }
                values.append(value)
            }
            return values
        }

        mutating func point(relative: Bool) -> CGPoint? {
            guard let values = numbers(2) else { return nil }
            return CGPoint(x: values[0] + (relative ? current.x : 0), y: values[1] + (relative ? current.y : 0))
        }

        mutating func beginDrawing() {
            if needsMove {
                path.move(to: current)
                needsMove = false
            }
        }

        mutating func apply(_ command: UInt8) -> UInt8?? {
            let relative = command >= UInt8(ascii: "a")
            let upper = relative ? command - 32 : command
            let previousCubic = lastCubic
            let previousQuad = lastQuad
            lastCubic = nil
            lastQuad = nil
            switch upper {
            case UInt8(ascii: "M"):
                guard let target = point(relative: relative) else { return nil }
                path.move(to: target)
                current = target
                start = target
                needsMove = false
                return .some(relative ? UInt8(ascii: "l") : UInt8(ascii: "L"))
            case UInt8(ascii: "L"):
                guard let target = point(relative: relative) else { return nil }
                beginDrawing()
                path.addLine(to: target)
                current = target
            case UInt8(ascii: "H"):
                guard let x = number() else { return nil }
                beginDrawing()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "V"):
                guard let y = number() else { return nil }
                beginDrawing()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "C"):
                guard let c1 = point(relative: relative), let c2 = point(relative: relative), let target = point(relative: relative) else { return nil }
                beginDrawing()
                path.addCurve(to: target, control1: c1, control2: c2)
                lastCubic = c2
                current = target
            case UInt8(ascii: "S"):
                guard let c2 = point(relative: relative), let target = point(relative: relative) else { return nil }
                beginDrawing()
                let c1 = previousCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: target, control1: c1, control2: c2)
                lastCubic = c2
                current = target
            case UInt8(ascii: "Q"):
                guard let control = point(relative: relative), let target = point(relative: relative) else { return nil }
                beginDrawing()
                path.addQuadCurve(to: target, control: control)
                lastQuad = control
                current = target
            case UInt8(ascii: "T"):
                guard let target = point(relative: relative) else { return nil }
                beginDrawing()
                let control = previousQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: target, control: control)
                lastQuad = control
                current = target
            case UInt8(ascii: "A"):
                guard let radii = numbers(3), let large = flag(), let sweep = flag(), let target = point(relative: relative) else { return nil }
                beginDrawing()
                addArc(radiusX: radii[0], radiusY: radii[1], rotation: radii[2], large: large, sweep: sweep, to: target)
                current = target
            default:
                path.closeSubpath()
                current = start
                needsMove = true
                return .some(nil)
            }
            return .some(command)
        }

        mutating func addArc(radiusX: Double, radiusY: Double, rotation: Double, large: Bool, sweep: Bool, to end: CGPoint) {
            var rx = abs(radiusX)
            var ry = abs(radiusY)
            if end == current { return }
            if rx == 0 || ry == 0 {
                path.addLine(to: end)
                return
            }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)
            let halfDX = (current.x - end.x) / 2
            let halfDY = (current.y - end.y) / 2
            let x1 = cosPhi * halfDX + sinPhi * halfDY
            let y1 = -sinPhi * halfDX + cosPhi * halfDY
            let scale = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if scale > 1 {
                rx *= scale.squareRoot()
                ry *= scale.squareRoot()
            }
            let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let sign: Double = large == sweep ? -1 : 1
            let coefficient = denominator == 0 ? 0 : sign * max(0, numerator / denominator).squareRoot()
            let cx1 = coefficient * rx * y1 / ry
            let cy1 = -coefficient * ry * x1 / rx
            let cx = cosPhi * cx1 - sinPhi * cy1 + (current.x + end.x) / 2
            let cy = sinPhi * cx1 + cosPhi * cy1 + (current.y + end.y) / 2
            let theta = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
            var delta = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - theta
            if !sweep, delta > 0 { delta -= 2 * .pi }
            if sweep, delta < 0 { delta += 2 * .pi }

            let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
            let step = delta / Double(segments)
            let handle = 4.0 / 3.0 * tan(step / 4)
            func map(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            for segment in 0..<segments {
                let a = theta + step * Double(segment)
                let b = a + step
                let target = segment == segments - 1 ? end : map(cos(b), sin(b))
                path.addCurve(
                    to: target,
                    control1: map(cos(a) - handle * sin(a), sin(a) + handle * cos(a)),
                    control2: map(cos(b) + handle * sin(b), sin(b) - handle * cos(b))
                )
            }
        }
    }
}
