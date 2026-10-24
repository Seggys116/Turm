import AppKit
import ImageIO

enum MotionPicture {
    struct Clip {
        let animation: KittyAnimation
        let pixels: CGSize
    }

    /// Decoded frames stay under this many bytes. A small GIF can expand to a frame buffer
    /// far larger than the file, and those frames are not counted by the Kitty image quota.
    static let decodedByteLimit = 32 * 1024 * 1024

    static func framesToKeep(width: Int, height: Int, count: Int) -> Int {
        let frameBytes = Int64(width) * Int64(height) * 4
        guard width > 0, height > 0, width <= 10_000, height <= 10_000, frameBytes > 0,
              frameBytes <= Int64(decodedByteLimit)
        else { return 0 }
        return min(count, 240, Int(Int64(decodedByteLimit) / frameBytes))
    }

    static func decode(_ data: Data) -> Clip? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let kept = framesToKeep(width: first.width, height: first.height, count: count)
        guard kept > 1 else { return nil }
        let animation = KittyAnimation(root: first)
        animation.setGap(delay(source, 0), of: 0)
        for index in 1..<kept {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                  frame.width == first.width, frame.height == first.height
            else { continue }
            animation.append(frame, gap: delay(source, index))
        }
        guard animation.frames.count > 1 else { return nil }
        animation.setLoops(1)
        animation.setState(3)
        return Clip(animation: animation, pixels: CGSize(width: first.width, height: first.height))
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? 0.1
        return max(Int((max(seconds, 0.02) * 1000).rounded()), 20)
    }
}
