import CoreGraphics
import Foundation
import Testing

@testable import TurmCore

private func rgba(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels
}

private func apc(_ keys: String, _ payload: String = "") -> [UInt8] { KittyFixtures.apc(keys, payload) }
private func base64(_ value: String) -> String { KittyFixtures.base64(value) }

struct KittySharedMemoryPixelTests {
    private static let quad: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]

    @Test(.enabled(if: KittySharedMemory.works(), "POSIX shared memory cannot be created, mapped and re-opened read-only here"))
    func sharedMemoryPixelsSurviveTheTransmit() throws {
        let name = KittySharedMemory.uniqueName()
        defer { KittySharedMemory.unlink(name) }
        #expect(KittySharedMemory.create(name, bytes: Self.quad))
        let rig = KittyRig()
        rig.feed(apc("a=T,f=32,s=2,v=2,t=s,i=1,C=1,q=2", base64(name)))
        let image = try #require(rig.sources[1]?.frames.first?.image)
        #expect(rgba(image) == Self.quad)
    }

    @Test(.enabled(if: KittySharedMemory.works(), "POSIX shared memory cannot be created, mapped and re-opened read-only here"))
    func sharedMemoryFramesReplaceEachOtherAfterADelete() throws {
        let rig = KittyRig()
        for (index, colour) in [[UInt8](arrayLiteral: 255, 0, 0, 255), [0, 0, 255, 255]].enumerated() {
            let name = KittySharedMemory.uniqueName()
            defer { KittySharedMemory.unlink(name) }
            let pixels = Array([[UInt8]](repeating: colour, count: 4).joined())
            #expect(KittySharedMemory.create(name, bytes: pixels))
            rig.feed(apc("a=d,d=i,i=1,p=1,q=2"))
            rig.feed(apc("a=T,f=32,s=2,v=2,t=s,i=1,p=1,C=1,z=0,q=2", base64(name)))
            let image = try #require(rig.sources[1]?.frames.first?.image, "frame \(index)")
            #expect(rgba(image) == pixels, "frame \(index)")
            #expect(rig.images.count == 1, "frame \(index)")
        }
    }
}
