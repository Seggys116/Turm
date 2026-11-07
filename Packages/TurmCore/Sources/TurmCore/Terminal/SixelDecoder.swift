import Foundation

public struct SixelImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var premultipliedRGBA: [UInt8] {
        var out = rgba
        var index = 0
        while index + 3 < out.count {
            let alpha = Int(out[index + 3])
            if alpha != 255 {
                for channel in 0..<3 { out[index + channel] = UInt8((Int(out[index + channel]) * alpha + 127) / 255) }
            }
            index += 4
        }
        return out
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

extension SixelImage {
    public var cgImage: CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
#endif

public struct SixelLimits: Equatable, Sendable {
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxBytes: Int

    public init(maxWidth: Int = 10_000, maxHeight: Int = 10_000, maxBytes: Int = 64 << 20) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxBytes = maxBytes
    }
}

public enum SixelDecoder {
    /// `bytes` is the DCS body after the final `q`, up to but excluding ST. `params` are the DCS P1;P2;P3 values.
    public static func decode(_ bytes: some Collection<UInt8>, params: [Int] = [], limits: SixelLimits = SixelLimits()) -> SixelImage? {
        var state = SixelState(params: params, limits: limits)
        do {
            try state.run(Array(bytes))
            return try state.finish()
        } catch {
            return nil
        }
    }

    /// `sequence` is a whole `ESC P P1;P2;P3 q body ST` as produced by `TerminalGraphics.split`.
    public static func decode(sequence: ArraySlice<UInt8>, limits: SixelLimits = SixelLimits()) -> SixelImage? {
        var index = sequence.startIndex
        guard index + 1 < sequence.endIndex, sequence[index] == 0x1B, sequence[index + 1] == 0x50 else { return nil }
        index += 2
        var params: [Int] = []
        var value = 0
        while index < sequence.endIndex, sequence[index] != 0x71 {
            let byte = sequence[index]
            if byte >= 0x30, byte <= 0x39 {
                value = min(value * 10 + Int(byte - 0x30), 1 << 20)
            } else if byte == 0x3B {
                params.append(value)
                value = 0
            } else if byte < 0x20 || byte > 0x3F {
                return nil
            }
            index += 1
        }
        guard index < sequence.endIndex else { return nil }
        params.append(value)
        index += 1
        let body = sequence[index...].prefix { $0 != 0x1B && $0 != 0x9C }
        return decode(body, params: params, limits: limits)
    }

    static func defaultPalette() -> [UInt32] {
        let percents: [(Int, Int, Int)] = [
            (0, 0, 0), (20, 20, 80), (80, 13, 13), (20, 80, 20),
            (80, 20, 80), (20, 80, 80), (80, 80, 20), (53, 53, 53),
            (26, 26, 26), (33, 33, 60), (60, 26, 26), (33, 60, 33),
            (60, 33, 60), (33, 60, 60), (60, 60, 33), (80, 80, 80),
        ]
        var palette = [UInt32](repeating: pack(0, 0, 0), count: 256)
        for (index, p) in percents.enumerated() {
            palette[index] = pack(scale(p.0), scale(p.1), scale(p.2))
        }
        return palette
    }

    static func scale(_ percent: Int) -> UInt8 {
        UInt8((min(max(percent, 0), 100) * 255 + 50) / 100)
    }

    static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }

    static func hls(hue: Int, lightness: Int, saturation: Int) -> UInt32 {
        let h = Double((hue % 360 + 240) % 360) / 360
        let l = Double(min(max(lightness, 0), 100)) / 100
        let s = Double(min(max(saturation, 0), 100)) / 100
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ value: Double) -> UInt8 {
            var t = value
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let v: Double
            if s == 0 {
                v = l
            } else if t < 1.0 / 6 {
                v = p + (q - p) * 6 * t
            } else if t < 0.5 {
                v = q
            } else if t < 2.0 / 3 {
                v = p + (q - p) * (2.0 / 3 - t) * 6
            } else {
                v = p
            }
            return UInt8(min(max((v * 255).rounded(), 0), 255))
        }
        return pack(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }
}

private struct SixelFailure: Error {}

private struct SixelState {
    let limits: SixelLimits
    var palette = SixelDecoder.defaultPalette()
    var current = 0
    var verticalRepeat: Int
    let fillsBackground: Bool

    var pixels: [UInt32] = []
    var stride = 0
    var x = 0
    var bandTop = 0
    var maxX = 0
    var usedRows = 0
    var declaredWidth = 0
    var declaredHeight = 0
    var repeatCount = 1

    init(params: [Int], limits: SixelLimits) {
        self.limits = limits
        switch params.first ?? 0 {
        case 2: verticalRepeat = 5
        case 3, 4: verticalRepeat = 3
        case 5, 6: verticalRepeat = 2
        default: verticalRepeat = 1
        }
        fillsBackground = (params.count > 1 ? params[1] : 0) != 1
    }

    mutating func run(_ b: [UInt8]) throws {
        var i = 0
        while i < b.count {
            let c = b[i]
            i += 1
            switch c {
            case 0x3F...0x7E:
                try put(bits: c - 0x3F, count: repeatCount)
                repeatCount = 1
            case 0x21:
                repeatCount = max(1, numbers(b, &i).first ?? 1)
            case 0x24:
                x = 0
                repeatCount = 1
            case 0x2D:
                x = 0
                bandTop += 6
                repeatCount = 1
            case 0x23:
                repeatCount = 1
                selectOrDefine(numbers(b, &i))
            case 0x22:
                repeatCount = 1
                try raster(numbers(b, &i))
            default:
                break
            }
        }
    }

    func numbers(_ b: [UInt8], _ i: inout Int) -> [Int] {
        var out: [Int] = []
        var value = 0
        var seen = false
        while i < b.count {
            let c = b[i]
            if c >= 0x30 && c <= 0x39 {
                value = min(value * 10 + Int(c - 0x30), 1 << 30)
                seen = true
            } else if c == 0x3B {
                if out.count < 8 { out.append(value) }
                value = 0
                seen = true
            } else if c > 0x20 && c != 0x7F {
                break
            }
            i += 1
        }
        if seen && out.count < 8 { out.append(value) }
        return out
    }

    mutating func selectOrDefine(_ n: [Int]) {
        guard let register = n.first else { return }
        let index = register % 256
        if n.count >= 5 {
            switch n[1] {
            case 1: palette[index] = SixelDecoder.hls(hue: n[2], lightness: n[3], saturation: n[4])
            case 2: palette[index] = SixelDecoder.pack(SixelDecoder.scale(n[2]), SixelDecoder.scale(n[3]), SixelDecoder.scale(n[4]))
            default: break
            }
        }
        current = index
    }

    mutating func raster(_ n: [Int]) throws {
        if n.count >= 2, n[0] > 0, n[1] > 0 {
            let ratio = Double(n[0]) / Double(n[1])
            verticalRepeat = min(max(Int(ratio.rounded()), 1), 1_000)
        }
        if n.count >= 4, n[2] > 0, n[3] > 0 {
            declaredWidth = n[2]
            declaredHeight = n[3]
        }
        try check(width: max(maxX, declaredWidth), rows: max(usedRows, declaredHeight))
    }

    func check(width: Int, rows: Int) throws {
        let (height, o1) = rows.multipliedReportingOverflow(by: verticalRepeat)
        let (area, o2) = width.multipliedReportingOverflow(by: height)
        let (bytes, o3) = area.multipliedReportingOverflow(by: 4)
        if o1 || o2 || o3 || width > limits.maxWidth || height > limits.maxHeight || bytes > limits.maxBytes {
            throw SixelFailure()
        }
    }

    mutating func reserve(width: Int, rows: Int) throws {
        let needWidth = max(maxX, width)
        let needRows = max(usedRows, rows)
        try check(width: needWidth, rows: needRows)
        let capRows = stride == 0 ? 0 : pixels.count / stride
        if width <= stride && rows <= capRows { return }

        var newStride = stride
        var newRows = capRows
        if width > stride {
            newStride = min(max(width, stride * 2), limits.maxWidth)
        }
        if rows > capRows {
            newRows = min(max(rows, capRows * 2), limits.maxHeight / verticalRepeat)
        }
        let (grown, overflow) = newStride.multipliedReportingOverflow(by: newRows)
        if overflow || grown > limits.maxBytes / 4 / verticalRepeat {
            newStride = needWidth
            newRows = needRows
        }
        relayout(stride: newStride, rows: newRows, oldRows: capRows)
    }

    mutating func relayout(stride newStride: Int, rows newRows: Int, oldRows: Int) {
        var next = [UInt32](repeating: 0, count: newStride * newRows)
        let columns = min(stride, newStride)
        if columns > 0 {
            for row in 0..<min(oldRows, newRows) {
                for col in 0..<columns {
                    next[row * newStride + col] = pixels[row * stride + col]
                }
            }
        }
        pixels = next
        stride = newStride
    }

    mutating func put(bits: UInt8, count: Int) throws {
        let (end, overflow) = x.addingReportingOverflow(count)
        if overflow { throw SixelFailure() }
        let bottom = bandTop + 6
        try reserve(width: end, rows: bottom)
        maxX = max(maxX, end)
        usedRows = max(usedRows, bottom)
        if bits != 0 {
            let color = palette[current]
            let start = x
            let top = bandTop
            let rowStride = stride
            pixels.withUnsafeMutableBufferPointer { buf in
                for bit in 0..<6 where bits & (1 << bit) != 0 {
                    let base = (top + bit) * rowStride + start
                    for offset in 0..<count {
                        buf[base + offset] = color
                    }
                }
            }
        }
        x = end
    }

    func finish() throws -> SixelImage? {
        let width = max(maxX, declaredWidth)
        let rows = max(usedRows, declaredHeight)
        guard width > 0, rows > 0 else { return nil }
        try check(width: width, rows: rows)
        let height = rows * verticalRepeat
        let capRows = stride == 0 ? 0 : pixels.count / stride
        let background = palette[0]
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var offset = 0
        for y in 0..<height {
            let source = y / verticalRepeat
            for col in 0..<width {
                var value: UInt32 = 0
                if source < capRows && col < stride {
                    value = pixels[source * stride + col]
                }
                if value == 0 && fillsBackground { value = background }
                if value != 0 {
                    out[offset] = UInt8(value & 0xFF)
                    out[offset + 1] = UInt8((value >> 8) & 0xFF)
                    out[offset + 2] = UInt8((value >> 16) & 0xFF)
                    out[offset + 3] = UInt8(value >> 24)
                }
                offset += 4
            }
        }
        return SixelImage(width: width, height: height, rgba: out)
    }
}
