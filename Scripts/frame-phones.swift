import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 4 else {
    fputs("usage: frame-phones.swift sidebar.png running.png ssh.png ios.png\n", stderr)
    exit(1)
}

struct Shot {
    let image: NSImage
    let pixels: CGSize
}

func load(_ path: String) -> Shot {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let rep = NSBitmapImageRep(data: data) else {
        fputs("Could not read \(path)\n", stderr)
        exit(1)
    }
    let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    image.addRepresentation(rep)
    return Shot(image: image, pixels: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
}

let shots = args.dropLast().map(load)
let canvas = NSSize(width: 2560, height: 1600)
let phone = NSSize(width: 635, height: 1380)
let radius: CGFloat = 66
let frames = [
    NSRect(x: 178, y: 110, width: phone.width, height: phone.height),
    NSRect(x: 962, y: 110, width: phone.width, height: phone.height),
    NSRect(x: 1747, y: 110, width: phone.width, height: phone.height),
]

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not allocate the composite\n", stderr)
    exit(1)
}
bitmap.size = canvas

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not draw the composite\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(origin: .zero, size: canvas).fill()

for (shot, frame) in zip(shots, frames) {
    let aspect = shot.pixels.width / shot.pixels.height
    let fitted: NSRect
    if aspect > frame.width / frame.height {
        let width = frame.height * aspect
        fitted = NSRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
    } else {
        let height = frame.width / aspect
        fitted = NSRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
    }
    context.saveGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
    shot.image.draw(in: fitted, from: .zero, operation: .copy, fraction: 1)
    context.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode the composite\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: args[3]))
} catch {
    fputs("Could not write \(args[3]): \(error)\n", stderr)
    exit(1)
}
