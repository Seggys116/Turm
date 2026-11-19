import AppKit
import SwiftTerm
import TurmCore
@testable import Turm

/// Draws a full-screen pane the way the window composites it, without putting anything on screen:
/// the background fill, the images under the text, the text layer and the images above it.
@MainActor
struct PaneSnapshot {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let pixels: [UInt8]

    init(_ host: AltScreenHost, scale: CGFloat = 2) {
        let view = host.view
        let size = view.bounds.size
        self.scale = scale
        width = max(Int(size.width * scale), 1)
        height = max(Int(size.height * scale), 1)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        if let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.scaleBy(x: scale, y: scale)
            view.needsDisplay = true
            view.layer?.displayIfNeeded()
            // a bitmap context keeps its top row first in memory, so the layers render upright as they are
            for layer in [view.graphicsBackdrop.layer, view.layer, view.graphicsOverlay.layer].compactMap({ $0 }) {
                layer.render(in: context)
            }
        }
        pixels = buffer
    }

    /// The colour at a point measured in view points from the top left.
    func colour(x: CGFloat, y: CGFloat) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let column = min(max(Int(x * scale), 0), width - 1)
        let row = min(max(Int(y * scale), 0), height - 1)
        let base = (row * width + column) * 4
        return (Int(pixels[base]), Int(pixels[base + 1]), Int(pixels[base + 2]), Int(pixels[base + 3]))
    }

    /// The colour at the centre of a terminal cell.
    func colour(row: Int, column: Int, of host: AltScreenHost) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let cell = host.cellPoints
        return colour(x: (CGFloat(column) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height)
    }

    /// The share of the cell's pixels that are close to a colour, from 0 to 1.
    func share(near target: (Int, Int, Int), row: Int, column: Int, of host: AltScreenHost, tolerance: Int = 40) -> Double {
        let cell = host.cellPoints
        let left = Int(CGFloat(column) * cell.width * scale), right = Int(CGFloat(column + 1) * cell.width * scale)
        let top = Int(CGFloat(row) * cell.height * scale), bottom = Int(CGFloat(row + 1) * cell.height * scale)
        var hits = 0, total = 0
        for y in max(top, 0)..<min(bottom, height) {
            for x in max(left, 0)..<min(right, width) {
                let base = (y * width + x) * 4
                total += 1
                if abs(Int(pixels[base]) - target.0) <= tolerance, abs(Int(pixels[base + 1]) - target.1) <= tolerance,
                   abs(Int(pixels[base + 2]) - target.2) <= tolerance {
                    hits += 1
                }
            }
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    static func isNear(_ colour: (red: Int, green: Int, blue: Int, alpha: Int), _ target: (Int, Int, Int), tolerance: Int = 40) -> Bool {
        abs(colour.red - target.0) <= tolerance && abs(colour.green - target.1) <= tolerance && abs(colour.blue - target.2) <= tolerance
    }
}

/// A full-screen host laid out in a pane of a fixed size, ready for sequences and snapshots.
@MainActor
final class RenderRig {
    let host: AltScreenHost
    let container: AltContainer
    var replies: [UInt8] = []

    init(cols: Int = 40, rows: Int = 12) {
        host = AltScreenHost(cols: cols, rows: rows)
        host.apply(dark: true)
        container = AltContainer(host: host)
        host.onInput = { [weak self] bytes in self?.replies.append(contentsOf: bytes) }
        host.feed(Array("\u{1B}[?1049h".utf8))
        let cell = host.cellPoints
        container.setFrameSize(NSSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height))
    }

    func feed(_ text: String) {
        host.feed(Array(text.utf8))
    }

    func feed(_ bytes: [UInt8]) {
        host.feed(bytes)
    }

    func snapshot() -> PaneSnapshot {
        host.refreshGraphics()
        return PaneSnapshot(host)
    }

    var replyText: String {
        String(decoding: replies, as: UTF8.self)
    }
}

enum Sequences {
    static func apc(_ keys: String, _ payload: String = "") -> String {
        payload.isEmpty ? "\u{1B}_G\(keys)\u{1B}\\" : "\u{1B}_G\(keys);\(payload)\u{1B}\\"
    }

    static func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8, width: Int, height: Int, alpha: UInt8? = 255) -> [UInt8] {
        let pixel: [UInt8] = alpha.map { [red, green, blue, $0] } ?? [red, green, blue]
        return Array([[UInt8]](repeating: pixel, count: width * height).joined())
    }

    static func png(_ red: UInt8, _ green: UInt8, _ blue: UInt8, width: Int, height: Int) -> Data {
        var pixels = solid(red, green, blue, width: width, height: height)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
    static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
}
