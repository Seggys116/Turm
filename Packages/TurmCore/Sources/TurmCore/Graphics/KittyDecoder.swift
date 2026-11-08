import CoreGraphics
import Foundation
import ImageIO

public enum KittyDecoder {
    public static func opaque(command: KittyCommand) -> Bool {
        KittyLoadCheck.format(command) == 24
    }

    public static func decode(command: KittyCommand, bytes: Data) -> Result<CGImage, KittyFailure> {
        switch KittyLoadCheck.format(command) {
        case 100:
            return png(bytes)
        case 24:
            return raw(command, bytes, channels: 3)
        case 32:
            return raw(command, bytes, channels: 4)
        default:
            return .failure(KittyFailure(code: "EINVAL", message: "Unknown image format: \(KittyLoadCheck.format(command))"))
        }
    }

    private static func png(_ bytes: Data) -> Result<CGImage, KittyFailure> {
        guard GraphicsBounds.admits(imageData: bytes) else {
            return .failure(KittyFailure(code: "EBADPNG", message: "PNG image is too large"))
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return .failure(KittyFailure(code: "EBADPNG", message: "Not a PNG file"))
        }
        return .success(image)
    }

    private static func raw(_ command: KittyCommand, _ bytes: Data, channels: Int) -> Result<CGImage, KittyFailure> {
        let width = command.stateValue ?? 0
        let height = command.loopValue ?? 0
        if width == 0 || height == 0 {
            return .failure(KittyFailure(code: "EINVAL", message: "Zero width/height not allowed"))
        }
        guard GraphicsBounds.admits(width: width, height: height) else {
            return .failure(KittyFailure(code: "EINVAL", message: "Image too large, width or height greater than \(GraphicsBounds.maxSide)"))
        }
        let need = width * height * channels
        guard bytes.count >= need else {
            return .failure(KittyFailure(code: "ENODATA", message: "Insufficient image data: \(bytes.count) < \(need)"))
        }
        let info: CGImageAlphaInfo = channels == 4 ? .last : .none
        guard let provider = CGDataProvider(data: Data(bytes.prefix(need)) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: channels * 8,
                  bytesPerRow: width * channels, space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else {
            return .failure(KittyFailure(code: "EINVAL", message: "Failed to create image from pixel data"))
        }
        return .success(image)
    }
}
