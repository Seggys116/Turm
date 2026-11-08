import CoreGraphics
import Foundation

public struct KittyFrame {
    public var image: CGImage
    public var gap = 0
    public var bytes = 0
    public var opaque = false
}

public final class KittyAnimation {
    public static let defaultGap = 40

    public private(set) var frames: [KittyFrame]
    public private(set) var state = 1
    public private(set) var current = 0
    public private(set) var loops = 0
    private var startedAt = Date()
    public var touched: UInt64 = 0
    public var transient = false

    public init(root: CGImage, opaque: Bool = false, transient: Bool = false, touched: UInt64 = 0) {
        frames = [KittyFrame(image: root, bytes: root.width * root.height * (opaque ? 3 : 4), opaque: opaque)]
        self.transient = transient
        self.touched = touched
    }

    public var rootBytes: Int {
        frames[0].bytes
    }

    public var totalBytes: Int {
        frames.reduce(0) { $0 + $1.bytes }
    }

    public var size: (width: Int, height: Int) {
        (frames[0].image.width, frames[0].image.height)
    }

    public var duration: Int {
        frames.reduce(0) { $0 + $1.gap }
    }

    public var isRunning: Bool {
        state != 1 && frames.count > 1
    }

    private var displayed: [(index: Int, duration: Int)] {
        frames.indices.compactMap { index in frames[index].gap > 0 ? (index, frames[index].gap) : nil }
    }

    private func offset(of frame: Int) -> Int {
        var total = 0
        for entry in displayed {
            if entry.index >= frame { break }
            total += entry.duration
        }
        return total
    }

    private func elapsed(at date: Date) -> Int {
        max(Int(date.timeIntervalSince(startedAt) * 1000), 0)
    }

    public func append(_ image: CGImage, gap: Int, bytes: Int? = nil, opaque: Bool = false) {
        frames.append(KittyFrame(image: image, gap: max(gap, 0), bytes: bytes ?? image.width * image.height * 4, opaque: opaque))
    }

    public func replace(_ index: Int, with image: CGImage, gap: Int?) {
        frames[index].image = image
        frames[index].bytes = size.width * size.height * (frames[index].opaque ? 3 : 4)
        if let gap { frames[index].gap = max(gap, 0) }
    }

    public func setGap(_ gap: Int, of index: Int) {
        frames[index].gap = max(gap, 0)
    }

    public func setState(_ newState: Int, now: Date = Date()) {
        if newState == 1 {
            current = frameIndex(at: now)
            state = 1
            return
        }
        if state == 1 {
            startedAt = now
        } else if duration > 0 {
            startedAt = now.addingTimeInterval(-Double(elapsed(at: now) % duration) / 1000)
        }
        state = newState
    }

    public func setLoops(_ count: Int) {
        if count != 0 { loops = count }
    }

    public func show(_ index: Int, now: Date = Date()) {
        current = index
        startedAt = now.addingTimeInterval(-Double(offset(of: index)) / 1000)
    }

    @discardableResult
    public func removeFrame(_ requested: Int, now: Date = Date()) -> Bool {
        guard frames.count > 1 else { return false }
        let number = max(min(frames.count, requested), 1)
        let shown = frameIndex(at: now)
        let removesRoot = number == 1
        let removed = removesRoot ? 0 : number - 2
        frames.remove(at: number - 1)
        if shown > frames.count - 1 {
            show(frames.count - 1, now: now)
        } else if removed < shown {
            show(shown - 1, now: now)
        } else {
            show(shown, now: now)
        }
        return true
    }

    public func frameIndex(at date: Date) -> Int {
        guard isRunning else { return min(current, frames.count - 1) }
        let list = displayed
        guard let last = list.last else { return min(current, frames.count - 1) }
        let total = list.reduce(0) { $0 + $1.duration }
        let time = elapsed(at: date)
        let finite = loops > 1
        if state == 2 && time >= total || finite && time >= total * (loops - 1) { return last.index }
        var position = time % total
        for entry in list {
            if position < entry.duration { return entry.index }
            position -= entry.duration
        }
        return last.index
    }

    public func nextChange(after now: Date) -> Date? {
        guard isRunning else { return nil }
        let list = displayed
        let total = list.reduce(0) { $0 + $1.duration }
        guard list.count > 1, total > 0 else { return nil }
        let time = elapsed(at: now)
        if state == 2 && time >= total || loops > 1 && time >= total * (loops - 1) { return nil }
        let position = time % total
        var end = 0
        for entry in list {
            end += entry.duration
            if position < end { break }
        }
        return startedAt.addingTimeInterval(Double(time - position + end) / 1000)
    }

    public func frame(at date: Date, cropping crop: CGRect?) -> CGImage {
        let image = frames[frameIndex(at: date)].image
        guard let crop, let cropped = image.cropping(to: crop) else { return image }
        return cropped
    }
}

public enum KittyCompositor {
    public static func compose(
        base: CGImage?, width: Int, height: Int, background: UInt32,
        source: CGImage, at origin: (x: Int, y: Int), replace: Bool
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if let base {
            context.draw(base, in: full)
        } else if background != 0 {
            let alpha = CGFloat(background & 0xFF) / 255
            context.setFillColor(
                red: CGFloat((background >> 24) & 0xFF) / 255,
                green: CGFloat((background >> 16) & 0xFF) / 255,
                blue: CGFloat((background >> 8) & 0xFF) / 255,
                alpha: alpha
            )
            context.setBlendMode(.copy)
            context.fill(full)
        }
        context.setBlendMode(replace ? .copy : .normal)
        context.draw(source, in: CGRect(
            x: origin.x, y: height - origin.y - source.height, width: source.width, height: source.height
        ))
        return context.makeImage()
    }

    public static func fits(_ rect: CGRect, width: Int, height: Int) -> Bool {
        rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= CGFloat(width) && rect.maxY <= CGFloat(height)
    }
}
