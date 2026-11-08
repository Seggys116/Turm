import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

@testable import TurmCore

final class Replies {
    var lines: [String] = []

    func contain(_ text: String) -> Bool {
        lines.contains { $0.contains(text) }
    }
}

final class TestClock {
    var date = Date(timeIntervalSince1970: 1000)

    func advance(_ seconds: Double) {
        date = date.addingTimeInterval(seconds)
    }
}

final class FakeGraphicsHost: GraphicsHost {
    var cursor = GridPoint(row: 0, column: 0)
    var screen = GraphicsScreen(columns: 40, rows: 10, top: 0, alternate: false, cellWidth: 10, cellHeight: 20, scale: 1)
    var allowsLocalMedia = true
    let replies = Replies()
    var terminalBytes: [UInt8] = []
    var cells: [GraphicsCell] = []

    init(columns: Int = 40, rows: Int = 10) {
        screen.columns = columns
        screen.rows = rows
    }

    func reply(_ bytes: [UInt8]) {
        replies.lines.append(String(decoding: bytes, as: UTF8.self))
    }

    func placeholderCells(rows: Range<Int>) -> [GraphicsCell] {
        cells.filter { rows.contains($0.point.row) }
    }

    func feedTerminal(_ bytes: ArraySlice<UInt8>) {
        terminalBytes.append(contentsOf: bytes)
        let data = Array(bytes)
        var index = 0
        while index < data.count {
            switch data[index] {
            case 0x0A:
                lineFeed()
                index += 1
            case 0x0D:
                cursor.column = 0
                index += 1
            case 0x1B:
                index = escape(data, index)
            default:
                index = print(data, index)
            }
        }
    }

    private func lineFeed() {
        if cursor.row >= screen.top + screen.rows - 1 { screen.top += 1 }
        cursor.row += 1
    }

    private func clampColumn(_ column: Int) -> Int {
        max(0, min(column, screen.columns - 1))
    }

    private func print(_ data: [UInt8], _ start: Int) -> Int {
        var end = start
        while end < data.count, data[end] != 0x0A, data[end] != 0x0D, data[end] != 0x1B { end += 1 }
        let count = String(decoding: data[start..<end], as: UTF8.self).count
        cursor.column = clampColumn(cursor.column + count)
        return end
    }

    private func escape(_ data: [UInt8], _ start: Int) -> Int {
        guard start + 1 < data.count else { return data.count }
        guard data[start + 1] == 0x5B else { return start + 2 }
        var end = start + 2
        while end < data.count, !(0x40...0x7E).contains(data[end]) { end += 1 }
        guard end < data.count else { return data.count }
        let parameters = String(decoding: data[(start + 2)..<end], as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        let numbers = parameters.map { Int($0) }
        let first = (numbers.first ?? nil) ?? 1
        switch data[end] {
        case UInt8(ascii: "G"):
            cursor.column = clampColumn(first - 1)
        case UInt8(ascii: "H"):
            let column = numbers.count > 1 ? (numbers[1] ?? 1) : 1
            cursor.row = screen.top + max(0, min(first - 1, screen.rows - 1))
            cursor.column = clampColumn(column - 1)
        case UInt8(ascii: "C"):
            cursor.column = clampColumn(cursor.column + first)
        case UInt8(ascii: "D"):
            cursor.column = clampColumn(cursor.column - first)
        case UInt8(ascii: "A"):
            cursor.row = max(screen.top, cursor.row - first)
        case UInt8(ascii: "B"):
            cursor.row = min(screen.top + screen.rows - 1, cursor.row + first)
        default:
            break
        }
        return end + 1
    }
}

final class KittyRig {
    let engine: KittyEngine
    let host: FakeGraphicsHost
    let clock: TestClock
    private var pending: [UInt8] = []

    init(columns: Int = 40, rows: Int = 10, storageLimit: Int = 320 << 20) {
        let clock = TestClock()
        self.clock = clock
        host = FakeGraphicsHost(columns: columns, rows: rows)
        engine = KittyEngine(storageLimit: storageLimit, now: { clock.date })
    }

    var images: [GraphicsPlacement] { engine.store.images }
    var sources: [UInt32: KittyAnimation] { engine.store.sources }
    var virtualPlacements: [GraphicsPlacement] { engine.store.virtualPlacements }
    var replies: Replies { host.replies }

    func feed(_ bytes: [UInt8]) {
        let split = KittyGraphicsScanner.split(pending + bytes)
        pending = Array(split.remainder)
        for piece in split.pieces {
            switch piece.kind {
            case .text:
                host.feedTerminal(piece.bytes)
            case .clear(let scope):
                host.feedTerminal(piece.bytes)
                engine.clear(scope, host: host)
            case .graphics:
                engine.handle(piece.bytes, host: host)
            }
        }
    }

    func visible(_ rows: Range<Int>? = nil) -> [GraphicsPlacement] {
        engine.placements(visible: rows ?? host.screen.top..<(host.screen.top + host.screen.rows), host: host)
    }

    func tiles() -> [GraphicsPlacement] {
        visible().filter { $0.tile != nil }.sorted { ($0.origin.row, $0.origin.column) < ($1.origin.row, $1.origin.column) }
    }

    func enterAlternate() {
        host.screen.alternate = true
        engine.bufferSwitched(toAlternate: true)
    }

    func leaveAlternate() {
        host.screen.alternate = false
        engine.bufferSwitched(toAlternate: false)
    }
}

@_silgen_name("shm_open")
private func sharedMemoryOpen(_ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32

// shm_open is variadic, so its mode has to travel where C varargs do: on the stack on arm64
private func sharedMemoryCreate(_ name: UnsafePointer<CChar>, mode: mode_t) -> Int32 {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return -1 }
    let flags = O_CREAT | O_RDWR | O_EXCL
    #if arch(arm64)
    typealias Create = @convention(c) (UnsafePointer<CChar>, Int32, Int, Int, Int, Int, Int, Int, Int) -> Int32
    return unsafeBitCast(symbol, to: Create.self)(name, flags, 0, 0, 0, 0, 0, 0, Int(mode))
    #else
    typealias Create = @convention(c) (UnsafePointer<CChar>, Int32, Int) -> Int32
    return unsafeBitCast(symbol, to: Create.self)(name, flags, Int(mode))
    #endif
}

enum KittySharedMemory {
    static func uniqueName() -> String {
        "/turmk\(UUID().uuidString.prefix(8))"
    }

    static func create(_ name: String, size: Int) -> Bool {
        let descriptor = name.withCString { sharedMemoryCreate($0, mode: 0o600) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0 else { return false }
        guard let map = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), map != MAP_FAILED else {
            return false
        }
        memset(map, 0, size)
        munmap(map, size)
        return true
    }

    static func exists(_ name: String) -> Bool {
        let descriptor = name.withCString { sharedMemoryOpen($0, O_RDONLY, 0) }
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    static func unlink(_ name: String) {
        _ = name.withCString { shm_unlink($0) }
    }

    static func works() -> Bool {
        let name = uniqueName()
        defer { unlink(name) }
        guard create(name, size: 3) else { return false }
        let descriptor = name.withCString { sharedMemoryOpen($0, O_RDONLY, 0) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 3 else { return false }
        guard let map = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, descriptor, 0), map != MAP_FAILED else {
            return false
        }
        munmap(map, Int(info.st_size))
        return true
    }
}

enum KittyFixtures {
    static let pixel = "AAAA"
    static let pngPixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let zlibTwelveZeros = "eJxjYEAAAAAMAAE="

    static let zlibFixtures: [String: String] = [
        "good": "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVTBwApzAMN",
        "truncatedBody": "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYR",
        "missingTrailer": "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVTBwA=",
        "partialTrailer": "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVTBwApzA==",
        "badChecksum": "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVTBwApzAMM",
        "headerOnly": "eJw=",
        "oneByte": "eA==",
        "badHeader": "AABjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVTBwApzAMN",
        "trailing": "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVTBwApzAMNeHg=",
        "corruptBody": "eJxjn2RiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVTBwApzAMN",
    ]

    static func apc(_ keys: String, _ payload: String = "") -> [UInt8] {
        let body = payload.isEmpty ? keys : "\(keys);\(payload)"
        return Array("\u{1B}_G\(body)\u{1B}\\".utf8)
    }

    static func put(_ keys: String) -> [UInt8] {
        apc("a=T,f=24,s=1,v=1,\(keys)", pixel)
    }

    static func transmit(_ id: Int) -> [UInt8] {
        apc("a=t,f=24,s=1,v=1,i=\(id)", pixel)
    }

    static func move(_ row: Int, _ column: Int) -> [UInt8] {
        Array("\u{1B}[\(row);\(column)H".utf8)
    }

    static func text(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    static func scratchFile(_ data: Data, protocolName: Bool) -> URL {
        let stem = protocolName ? "tty-graphics-protocol-" : "turm-kitty-"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem)\(UUID().uuidString)")
        try? data.write(to: url)
        return url
    }

    static func solidImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    static func pixelBytes(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return [] }
        let offset = y * image.bytesPerRow + x * 4
        return (0..<4).map { base[offset + $0] }
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1 }
        }
        return ~value
    }

    static func pngChunk(_ name: String, _ body: [UInt8], badChecksum: Bool = false) -> [UInt8] {
        let checked = Array(name.utf8) + body
        return bigEndian(UInt32(body.count)) + checked + bigEndian(crc32(checked) ^ (badChecksum ? 1 : 0))
    }

    static func header(width: UInt32, height: UInt32, depth: UInt8 = 8, color: UInt8 = 6, interlace: UInt8 = 0) -> [UInt8] {
        bigEndian(width) + bigEndian(height) + [depth, color, 0, 0, interlace]
    }
}
