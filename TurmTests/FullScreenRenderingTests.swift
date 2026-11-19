import AppKit
import SwiftTerm
import Testing
import TurmCore
@testable import Turm

private let red: (Int, Int, Int) = (255, 0, 0)
private let green: (Int, Int, Int) = (0, 255, 0)
private let blue: (Int, Int, Int) = (0, 0, 255)
private let white: (Int, Int, Int) = (255, 255, 255)

private func apc(_ keys: String, _ payload: String = "") -> String { Sequences.apc(keys, payload) }

/// Moves the cursor to a zero-based cell.
private func at(_ row: Int, _ column: Int) -> String { "\u{1B}[\(row + 1);\(column + 1)H" }

@MainActor
private func expectFilled(
    _ snapshot: PaneSnapshot, _ rig: RenderRig, _ colour: (Int, Int, Int), rows: ClosedRange<Int>, columns: ClosedRange<Int>,
    _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
) {
    for row in rows {
        for column in columns {
            let share = snapshot.share(near: colour, row: row, column: column, of: rig.host)
            #expect(share > 0.9, "cell \(row),\(column) is \(share) of \(colour) \(comment?.rawValue ?? "")", sourceLocation: sourceLocation)
        }
    }
}

@MainActor
private func expectClear(
    _ snapshot: PaneSnapshot, _ rig: RenderRig, _ colour: (Int, Int, Int), row: Int, column: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let share = snapshot.share(near: colour, row: row, column: column, of: rig.host)
    #expect(share < 0.05, "cell \(row),\(column) still shows \(colour) (\(share))", sourceLocation: sourceLocation)
}

// MARK: - Text

@MainActor
struct FullScreenTextRenderingTests {
    @Test func textForegroundAndBackgroundColoursReachThePane() {
        let rig = RenderRig()
        rig.feed(at(0, 0) + "\u{1B}[38;2;255;0;0m\u{2588}\u{2588}\u{1B}[0m" + at(0, 4) + "\u{1B}[48;2;0;0;255m  \u{1B}[0m")
        let snapshot = rig.snapshot()
        #expect(snapshot.share(near: red, row: 0, column: 0, of: rig.host) > 0.6)
        #expect(snapshot.share(near: red, row: 0, column: 1, of: rig.host) > 0.6)
        expectFilled(snapshot, rig, blue, rows: 0...0, columns: 4...5)
        let background = Theme.terminalBackground.resolved(dark: true).usingColorSpace(.sRGB)!
        let expected = (Int(background.redComponent * 255), Int(background.greenComponent * 255), Int(background.blueComponent * 255))
        #expect(snapshot.share(near: expected, row: 6, column: 20, of: rig.host, tolerance: 6) > 0.95)
    }

    @Test func indexedColoursUseThePalette() {
        let rig = RenderRig()
        rig.feed(at(1, 0) + "\u{1B}[48;5;196m  \u{1B}[0m" + at(1, 3) + "\u{1B}[48;5;21m  \u{1B}[0m")
        let snapshot = rig.snapshot()
        expectFilled(snapshot, rig, red, rows: 1...1, columns: 0...1)
        expectFilled(snapshot, rig, blue, rows: 1...1, columns: 3...4)
    }

    @Test func underlineStylesAndColourAreParsed() throws {
        let rig = RenderRig()
        rig.feed(at(0, 0) + "\u{1B}[4:3m\u{1B}[58:2::255:0:0mA\u{1B}[4:4m\u{1B}[58;2;0;255;0mB\u{1B}[4:5;59mC\u{1B}[0mD")
        let terminal = rig.host.view.getTerminal()
        let curly = try #require(terminal.getCharData(col: 0, row: 0))
        #expect(curly.attribute.underlineStyle == .curly)
        #expect(curly.attribute.underlineColor == .trueColor(red: 255, green: 0, blue: 0))
        let dotted = try #require(terminal.getCharData(col: 1, row: 0))
        #expect(dotted.attribute.underlineStyle == .dotted)
        #expect(dotted.attribute.underlineColor == .trueColor(red: 0, green: 255, blue: 0))
        let dashed = try #require(terminal.getCharData(col: 2, row: 0))
        #expect(dashed.attribute.underlineStyle == .dashed)
        #expect(dashed.attribute.underlineColor == nil)
        #expect(try #require(terminal.getCharData(col: 3, row: 0)).attribute.underlineStyle == .none)
    }

    @Test func synchronizedOutputHoldsImagesUntilTheUpdateEnds() {
        let rig = RenderRig()
        rig.feed("\u{1B}[?2026h" + at(2, 2) + apc("a=T,f=32,s=2,v=2,c=2,r=1,C=1,i=1,q=2", Sequences.base64(Sequences.solid(0, 255, 0, width: 2, height: 2))))
        #expect(rig.host.painter.overlay.sublayers?.isEmpty ?? true)
        rig.feed("\u{1B}[?2026l")
        expectFilled(rig.snapshot(), rig, green, rows: 2...2, columns: 2...3)
    }
}

// MARK: - Kitty graphics

@MainActor
struct FullScreenKittyRenderingTests {
    @Test func directRGBAIsDrawnOverTheCellsItCovers() {
        let rig = RenderRig()
        rig.feed(at(2, 4) + apc("a=T,f=32,s=4,v=4,c=2,r=2,C=1,i=1,q=2", Sequences.base64(Sequences.solid(0, 255, 0, width: 4, height: 4))))
        let snapshot = rig.snapshot()
        expectFilled(snapshot, rig, green, rows: 2...3, columns: 4...5)
        expectClear(snapshot, rig, green, row: 2, column: 6)
        expectClear(snapshot, rig, green, row: 4, column: 4)
    }

    @Test func directRGBIsDrawn() {
        let rig = RenderRig()
        rig.feed(at(1, 1) + apc("a=T,f=24,s=3,v=3,c=1,r=1,C=1,i=2,q=2", Sequences.base64(Sequences.solid(0, 0, 255, width: 3, height: 3, alpha: nil))))
        expectFilled(rig.snapshot(), rig, blue, rows: 1...1, columns: 1...1)
    }

    @Test func pngIsDrawn() {
        let rig = RenderRig()
        let png = Sequences.png(255, 0, 0, width: 6, height: 6)
        rig.feed(at(0, 0) + apc("a=T,f=100,c=3,r=2,C=1,i=3,q=2", png.base64EncodedString()))
        expectFilled(rig.snapshot(), rig, red, rows: 0...1, columns: 0...2)
    }

    @Test func zlibCompressedPixelsAreDrawn() {
        let rig = RenderRig()
        let raw = Sequences.solid(0, 255, 0, width: 4, height: 4)
        rig.feed(at(3, 3) + apc("a=T,f=32,o=z,s=4,v=4,c=2,r=1,C=1,i=4,q=2", Sequences.base64(Zlib.wrap(raw))))
        expectFilled(rig.snapshot(), rig, green, rows: 3...3, columns: 3...4)
    }

    @Test func chunkedTransmissionIsDrawnWhenTheLastChunkArrives() {
        let rig = RenderRig()
        let encoded = Sequences.base64(Sequences.solid(0, 0, 255, width: 8, height: 8))
        let chunks = stride(from: 0, to: encoded.count, by: 64).map { start -> String in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            let to = encoded.index(from, offsetBy: min(64, encoded.count - start))
            return String(encoded[from..<to])
        }
        rig.feed(at(4, 0))
        for (index, chunk) in chunks.enumerated() {
            let more = index < chunks.count - 1 ? 1 : 0
            let keys = index == 0 ? "a=T,f=32,s=8,v=8,c=2,r=2,C=1,i=5,q=2,m=\(more)" : "m=\(more)"
            rig.feed(apc(keys, chunk))
            if more == 1 { #expect(rig.host.painter.overlay.sublayers?.isEmpty ?? true) }
        }
        expectFilled(rig.snapshot(), rig, blue, rows: 4...5, columns: 0...1)
    }

    @Test func temporaryFileIsDrawnAndRemoved() throws {
        let rig = RenderRig()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tty-graphics-protocol-\(UUID().uuidString).rgba")
        try Data(Sequences.solid(255, 0, 0, width: 2, height: 2)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.feed(at(5, 5) + apc("a=T,f=32,t=t,s=2,v=2,c=1,r=1,C=1,i=6,q=2", Sequences.base64(url.path)))
        expectFilled(rig.snapshot(), rig, red, rows: 5...5, columns: 5...5)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fileIsDrawnAndKept() throws {
        let rig = RenderRig()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turm-render-\(UUID().uuidString).png")
        try Sequences.png(0, 255, 0, width: 4, height: 4).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.feed(at(6, 6) + apc("a=T,f=100,t=f,c=2,r=1,C=1,i=7,q=2", Sequences.base64(url.path)))
        expectFilled(rig.snapshot(), rig, green, rows: 6...6, columns: 6...7)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: SharedMemoryFixture.works(), "POSIX shared memory is not available here"))
    func sharedMemoryIsDrawnAndUnlinked() throws {
        let rig = RenderRig()
        let name = SharedMemoryFixture.uniqueName()
        defer { SharedMemoryFixture.unlink(name) }
        #expect(SharedMemoryFixture.create(name, bytes: Sequences.solid(0, 0, 255, width: 4, height: 4)))
        rig.feed(at(7, 0) + apc("a=T,f=32,t=s,s=4,v=4,c=3,r=2,C=1,i=8,q=2", Sequences.base64(name)))
        expectFilled(rig.snapshot(), rig, blue, rows: 7...8, columns: 0...2)
        #expect(!SharedMemoryFixture.exists(name))
    }

    /// GPU front ends such as terminal-browser and t3-term send every frame as a fresh image under the same ids.
    @Test(.enabled(if: SharedMemoryFixture.works(), "POSIX shared memory is not available here"))
    func everyRetransmittedFrameReplacesThePicture() throws {
        let rig = RenderRig()
        for (index, colour) in [(255, 0, 0), (0, 255, 0), (0, 0, 255)].enumerated() {
            let name = SharedMemoryFixture.uniqueName()
            defer { SharedMemoryFixture.unlink(name) }
            #expect(SharedMemoryFixture.create(name, bytes: Sequences.solid(UInt8(colour.0), UInt8(colour.1), UInt8(colour.2), width: 8, height: 4)))
            rig.feed("\u{1B}[H" + apc("a=d,d=i,i=1,p=1,q=2") + apc("a=T,f=32,s=8,v=4,t=s,i=1,p=1,C=1,z=0,c=4,r=2,q=2", Sequences.base64(name)))
            expectFilled(rig.snapshot(), rig, colour, rows: 0...1, columns: 0...3, "frame \(index)")
        }
        #expect(rig.host.painter.overlay.sublayers?.count == 1)
    }

    @Test func retransmittingDirectDataUnderTheSameIDsReplacesThePicture() {
        let rig = RenderRig()
        for colour in [(UInt8(255), UInt8(0), UInt8(0)), (0, 0, 255)] {
            rig.feed("\u{1B}[H" + apc("a=T,f=32,s=2,v=2,i=9,p=3,c=2,r=1,C=1,q=2", Sequences.base64(Sequences.solid(colour.0, colour.1, colour.2, width: 2, height: 2))))
            expectFilled(rig.snapshot(), rig, (Int(colour.0), Int(colour.1), Int(colour.2)), rows: 0...0, columns: 0...1)
        }
    }

    @Test func placingAStoredImageTwiceDrawsBothPlacements() {
        let rig = RenderRig()
        rig.feed(apc("a=t,f=32,s=2,v=2,i=10,q=2", Sequences.base64(Sequences.solid(0, 255, 0, width: 2, height: 2))))
        rig.feed(at(1, 1) + apc("a=p,i=10,p=1,c=1,r=1,C=1,q=2") + at(3, 8) + apc("a=p,i=10,p=2,c=2,r=1,C=1,q=2"))
        let snapshot = rig.snapshot()
        expectFilled(snapshot, rig, green, rows: 1...1, columns: 1...1)
        expectFilled(snapshot, rig, green, rows: 3...3, columns: 8...9)
    }

    @Test func deleteRemovesThePicture() {
        let rig = RenderRig()
        rig.feed(at(2, 2) + apc("a=T,f=32,s=2,v=2,c=2,r=1,C=1,i=11,q=2", Sequences.base64(Sequences.solid(255, 0, 0, width: 2, height: 2))))
        expectFilled(rig.snapshot(), rig, red, rows: 2...2, columns: 2...3)
        rig.feed(apc("a=d,d=I,i=11,q=2"))
        expectClear(rig.snapshot(), rig, red, row: 2, column: 2)
    }

    @Test func clearingTheScreenRemovesPicturesOnIt() {
        let rig = RenderRig()
        rig.feed(at(2, 2) + apc("a=T,f=32,s=2,v=2,c=2,r=1,C=1,i=12,q=2", Sequences.base64(Sequences.solid(255, 0, 0, width: 2, height: 2))))
        rig.feed(apc("a=d,d=a,q=2"))
        expectClear(rig.snapshot(), rig, red, row: 2, column: 2)
    }

    @Test func negativeZIndexDrawsUnderTheText() {
        let rig = RenderRig()
        rig.feed(at(0, 0) + apc("a=T,f=32,s=2,v=2,c=4,r=1,C=1,z=-1,i=13,q=2", Sequences.base64(Sequences.solid(255, 0, 0, width: 2, height: 2))))
        rig.feed(at(0, 0) + "\u{1B}[38;2;255;255;255m\u{2588}\u{1B}[0m")
        let snapshot = rig.snapshot()
        #expect(snapshot.share(near: white, row: 0, column: 0, of: rig.host) > 0.6)
        expectFilled(snapshot, rig, red, rows: 0...0, columns: 2...3)
    }

    @Test func positiveZIndexDrawsOverTheText() {
        let rig = RenderRig()
        rig.feed(at(0, 0) + "\u{1B}[38;2;255;255;255m\u{2588}\u{2588}\u{1B}[0m")
        rig.feed(at(0, 0) + apc("a=T,f=32,s=2,v=2,c=2,r=1,C=1,z=1,i=14,q=2", Sequences.base64(Sequences.solid(0, 0, 255, width: 2, height: 2))))
        expectFilled(rig.snapshot(), rig, blue, rows: 0...0, columns: 0...1)
    }

    @Test func showingAnotherAnimationFrameChangesThePicture() {
        let rig = RenderRig()
        rig.feed(at(1, 0) + apc("a=T,f=32,s=2,v=2,c=2,r=1,C=1,i=15,q=2", Sequences.base64(Sequences.solid(255, 0, 0, width: 2, height: 2))))
        rig.feed(apc("a=f,f=32,s=2,v=2,i=15,q=2", Sequences.base64(Sequences.solid(0, 255, 0, width: 2, height: 2))))
        rig.feed(apc("a=a,i=15,s=1,c=2,q=2"))
        expectFilled(rig.snapshot(), rig, green, rows: 1...1, columns: 0...1)
        rig.feed(apc("a=a,i=15,c=1,q=2"))
        expectFilled(rig.snapshot(), rig, red, rows: 1...1, columns: 0...1)
    }

    @Test func editingTheShownFrameInPlaceChangesThePicture() {
        let rig = RenderRig()
        rig.feed(at(1, 0) + apc("a=T,f=32,s=2,v=2,c=2,r=1,C=1,i=16,q=2", Sequences.base64(Sequences.solid(255, 0, 0, width: 2, height: 2))))
        expectFilled(rig.snapshot(), rig, red, rows: 1...1, columns: 0...1)
        rig.feed(apc("a=f,r=1,f=32,s=2,v=2,i=16,q=2", Sequences.base64(Sequences.solid(0, 0, 255, width: 2, height: 2))))
        expectFilled(rig.snapshot(), rig, blue, rows: 1...1, columns: 0...1)
    }

    @Test func unicodePlaceholdersDrawTheVirtualPlacement() {
        let rig = RenderRig()
        rig.feed(apc("a=T,U=1,f=32,s=4,v=2,c=2,r=1,i=17,q=2", Sequences.base64(Sequences.solid(0, 255, 0, width: 4, height: 2))))
        // the image id travels in the foreground colour, the row and column in the diacritics
        rig.feed(at(5, 10) + "\u{1B}[38;5;17m\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}\u{1B}[39m")
        let snapshot = rig.snapshot()
        expectFilled(snapshot, rig, green, rows: 5...5, columns: 10...11)
        expectClear(snapshot, rig, green, row: 5, column: 12)
    }

    @Test func queriesAreAnsweredAndNothingIsDrawn() {
        let rig = RenderRig()
        rig.feed(apc("a=q,i=31,s=1,v=1,f=24,t=d", "AAAA"))
        #expect(rig.replyText.contains("\u{1B}_Gi=31;OK\u{1B}\\"))
        #expect(rig.host.engine.activeStore.images.isEmpty)
        _ = rig.snapshot()
        #expect(rig.host.painter.overlay.sublayers?.isEmpty ?? true)
    }
}

// MARK: - Other image protocols

@MainActor
struct FullScreenImageProtocolRenderingTests {
    @Test func sixelIsDrawn() {
        let rig = RenderRig()
        let cell = rig.host.cellPixels
        let width = cell.width * 2
        let bands = (cell.height + 5) / 6
        let band = "#1!\(width)~"
        let body = Array(repeating: band, count: bands).joined(separator: "-")
        rig.feed(at(3, 2) + "\u{1B}P0;1;0q\"1;1;\(width);\(bands * 6)#1;2;0;0;100" + body + "\u{1B}\\")
        let snapshot = rig.snapshot()
        // SwiftTerm builds Sixel bitmaps in device RGB, which shifts pure blue a little in this sRGB snapshot
        #expect(snapshot.share(near: blue, row: 3, column: 2, of: rig.host, tolerance: 70) > 0.8)
        #expect(snapshot.share(near: blue, row: 3, column: 3, of: rig.host, tolerance: 70) > 0.8)
    }

    @Test func iTermInlineImageIsDrawn() {
        let rig = RenderRig()
        let png = Sequences.png(255, 0, 0, width: 8, height: 8).base64EncodedString()
        rig.feed(at(2, 3) + "\u{1B}]1337;File=inline=1;width=2;height=1;preserveAspectRatio=0:\(png)\u{07}")
        let snapshot = rig.snapshot()
        #expect(snapshot.share(near: red, row: 2, column: 3, of: rig.host) > 0.8)
        #expect(snapshot.share(near: red, row: 2, column: 4, of: rig.host) > 0.8)
    }
}

// MARK: - Keyboard

@MainActor
struct FullScreenKeyboardProtocolTests {
    private func press(_ rig: RenderRig, characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> String {
        rig.replies = []
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
        rig.host.view.keyDown(with: event)
        return rig.replyText
    }

    @Test func legacyKeysWithoutFlags() {
        let rig = RenderRig()
        #expect(press(rig, characters: "\u{1B}", keyCode: 53) == "\u{1B}")
        #expect(press(rig, characters: "a", keyCode: 0) == "a")
    }

    @Test func disambiguateSendsEscapeAsCSIu() {
        let rig = RenderRig()
        rig.feed("\u{1B}[>1u")
        rig.replies = []
        rig.feed("\u{1B}[?u")
        #expect(rig.replyText == "\u{1B}[?1u")
        #expect(press(rig, characters: "\u{1B}", keyCode: 53) == "\u{1B}[27u")
        #expect(press(rig, characters: "a", keyCode: 0) == "a")
    }

    @Test func popRestoresLegacyKeys() {
        let rig = RenderRig()
        rig.feed("\u{1B}[>1u\u{1B}[<u")
        #expect(press(rig, characters: "\u{1B}", keyCode: 53) == "\u{1B}")
    }
}

// MARK: - Fixtures

enum Zlib {
    /// RFC 1950 framing around the raw deflate stream Foundation produces, as the kitty protocol expects for `o=z`.
    static func wrap(_ bytes: [UInt8]) -> [UInt8] {
        let deflated = [UInt8]((try? (Data(bytes) as NSData).compressed(using: .zlib) as Data) ?? Data())
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        return [0x78, 0x9C] + deflated + [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
    }
}

@_silgen_name("shm_open")
private func sharedMemoryOpen(_ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32

enum SharedMemoryFixture {
    static func uniqueName() -> String {
        "/turmr\(UUID().uuidString.prefix(8))"
    }

    // shm_open is variadic, so its mode has to travel where C varargs do: on the stack on arm64
    private static func createDescriptor(_ name: String) -> Int32 {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return -1 }
        let flags = O_CREAT | O_RDWR | O_EXCL
        return name.withCString { pointer in
            #if arch(arm64)
            typealias Create = @convention(c) (UnsafePointer<CChar>, Int32, Int, Int, Int, Int, Int, Int, Int) -> Int32
            return unsafeBitCast(symbol, to: Create.self)(pointer, flags, 0, 0, 0, 0, 0, 0, 0o600)
            #else
            typealias Create = @convention(c) (UnsafePointer<CChar>, Int32, Int) -> Int32
            return unsafeBitCast(symbol, to: Create.self)(pointer, flags, 0o600)
            #endif
        }
    }

    static func create(_ name: String, bytes: [UInt8]) -> Bool {
        let descriptor = createDescriptor(name)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(bytes.count)) == 0,
              let map = mmap(nil, bytes.count, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), map != MAP_FAILED
        else { return false }
        bytes.withUnsafeBytes { map.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        munmap(map, bytes.count)
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
        return create(name, bytes: [1, 2, 3]) && exists(name)
    }
}
