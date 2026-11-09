import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

public enum GraphicsBounds {
    public static let maxSide = 10_000
    public static let maxPixels = TerminalGraphics.byteLimit / 4

    public static func admits(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= maxSide, height <= maxSide else { return false }
        return width * height <= maxPixels
    }

#if canImport(ImageIO)
    public static func admits(imageData data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return false }
        return admits(width: width, height: height)
    }
#endif
}

public enum SixelPrescan {
    public static let maxRegister = 1023
    private static let saturation = 1_000_000_000

    public static func admits(_ sequence: ArraySlice<UInt8>) -> Bool {
        var index = sequence.startIndex
        let end = sequence.endIndex
        guard index + 1 < end, sequence[index] == 0x1B, sequence[index + 1] == 0x50 else { return false }
        while index < end, sequence[index] != 0x71 { index += 1 }
        index += 1
        var column = 0
        var width = 0
        var bands = 0
        var drawnBands = 0
        var declaredWidth = 0
        var declaredHeight = 0
        while index < end {
            let byte = sequence[index]
            switch byte {
            case 0x1B, 0x9C:
                index = end
            case 0x21:
                let (values, next) = parameters(sequence, from: index + 1)
                let count = max(values.first ?? 1, 1)
                column += count
                if next < end, (0x3F...0x7E).contains(sequence[next]) {
                    drawnBands = bands + 1
                    width = max(width, column)
                    index = next + 1
                } else {
                    index = next
                }
                if column > GraphicsBounds.maxSide { return false }
            case 0x22:
                let (values, next) = parameters(sequence, from: index + 1)
                if values.count >= 4 {
                    declaredWidth = values[2]
                    declaredHeight = values[3]
                }
                if declaredWidth > GraphicsBounds.maxSide || declaredHeight > GraphicsBounds.maxSide { return false }
                index = next
            case 0x23:
                let (values, next) = parameters(sequence, from: index + 1)
                if let register = values.first, register > maxRegister { return false }
                index = next
            case 0x24:
                column = 0
                index += 1
            case 0x2D:
                bands += 1
                column = 0
                index += 1
            case 0x3F...0x7E:
                column += 1
                drawnBands = bands + 1
                width = max(width, column)
                if column > GraphicsBounds.maxSide { return false }
                index += 1
            default:
                index += 1
            }
        }
        let finalWidth = max(width, declaredWidth)
        let finalHeight = max(drawnBands * 6, declaredHeight)
        guard finalWidth <= GraphicsBounds.maxSide, finalHeight <= GraphicsBounds.maxSide else { return false }
        return finalWidth * finalHeight <= GraphicsBounds.maxPixels
    }

    private static func parameters(_ bytes: ArraySlice<UInt8>, from start: Int) -> (values: [Int], next: Int) {
        var values: [Int] = []
        var current = 0
        var any = false
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            if (0x30...0x39).contains(byte) {
                current = min(current * 10 + Int(byte - 0x30), saturation)
                any = true
            } else if byte == 0x3B {
                values.append(current)
                current = 0
                any = false
            } else {
                break
            }
            index += 1
        }
        if any || !values.isEmpty { values.append(current) }
        return (values, index)
    }
}

public enum GraphicsAttributes {
    public static let colorRegisters = 256

    public static func reply(for parameters: [Int]) -> [UInt8]? {
        guard parameters.count >= 2 else { return nil }
        let item = parameters[0]
        let action = parameters[1]
        let requested = Array(parameters.dropFirst(2))
        func response(_ status: Int, _ values: [Int]) -> [UInt8] {
            let fields = ([item, status] + values).map(String.init).joined(separator: ";")
            return Array("\u{1B}[?\(fields)S".utf8)
        }
        let fixed: [Int]
        switch item {
        case 1: fixed = [colorRegisters]
        case 2: fixed = [GraphicsBounds.maxSide, GraphicsBounds.maxSide]
        case 3: return response(1, [0])
        default: return response(1, [0])
        }
        switch action {
        case 1, 2, 4: return response(0, fixed)
        case 3: return requested == fixed ? response(0, fixed) : response(3, [0])
        default: return response(2, [0])
        }
    }
}

public enum KittyFilePolicy {
    private static let forbidden = ["/proc", "/sys", "/dev"]
    private static let marker = "tty-graphics-protocol"

    private static var temporaryDirectories: [String] {
        ["/tmp", "/var/folders", NSTemporaryDirectory()].flatMap { [$0, resolve($0)] }
    }

    public static func resolve(_ path: String) -> String {
        if let full = canonical(path) { return full }
        let url = URL(fileURLWithPath: path)
        guard let parent = canonical(url.deletingLastPathComponent().path) else { return url.standardizedFileURL.path }
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func mayRead(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let target = resolve(path)
        return !forbidden.contains { contains(target, in: $0) } && !forbidden.contains { contains(path, in: $0) }
    }

    public static func mayDelete(_ path: String, temporaryDirectories directories: [String]? = nil) -> Bool {
        guard mayRead(path) else { return false }
        let target = resolve(path)
        guard target.contains(marker) else { return false }
        return (directories ?? temporaryDirectories).contains { contains(target, in: resolve($0)) }
    }

    private static func contains(_ path: String, in directory: String) -> Bool {
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return path == base || path.hasPrefix(base + "/")
    }
}

public enum LinkPolicy {
    private static let remoteSchemes: Set<String> = ["http", "https", "mailto", "ssh"]

    public static func allows(_ url: URL, remote: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if remoteSchemes.contains(scheme) { return true }
        return scheme == "file" && !remote
    }
}
