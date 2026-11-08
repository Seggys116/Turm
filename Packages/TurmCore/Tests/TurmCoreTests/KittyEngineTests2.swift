import CoreGraphics
import Foundation
import Testing

@testable import TurmCore

private let pixel = KittyFixtures.pixel
private let pngPixel = KittyFixtures.pngPixel
private let pngSignature = KittyFixtures.pngSignature
private let zlibFixtures = KittyFixtures.zlibFixtures

private func apc(_ keys: String, _ payload: String = "") -> [UInt8] { KittyFixtures.apc(keys, payload) }
private func put(_ keys: String) -> [UInt8] { KittyFixtures.put(keys) }
private func transmit(_ id: Int) -> [UInt8] { KittyFixtures.transmit(id) }
private func move(_ row: Int, _ column: Int) -> [UInt8] { KittyFixtures.move(row, column) }
private func text(_ value: String) -> [UInt8] { KittyFixtures.text(value) }
private func base64(_ value: String) -> String { KittyFixtures.base64(value) }
private func scratchFile(_ data: Data, protocolName: Bool) -> URL { KittyFixtures.scratchFile(data, protocolName: protocolName) }
private func pngChunk(_ name: String, _ body: [UInt8], badChecksum: Bool = false) -> [UInt8] {
    KittyFixtures.pngChunk(name, body, badChecksum: badChecksum)
}
private func header(width: UInt32, height: UInt32, depth: UInt8 = 8, color: UInt8 = 6, interlace: UInt8 = 0) -> [UInt8] {
    KittyFixtures.header(width: width, height: height, depth: depth, color: color, interlace: interlace)
}

private func ids(_ rig: KittyRig) -> [UInt32] {
    rig.images.compactMap(\.kittyID).sorted()
}

private func animation(_ placement: GraphicsPlacement) -> KittyAnimation? {
    if case .animated(let animation) = placement.source { return animation }
    return nil
}

private let marks = ["\u{0305}", "\u{030D}", "\u{030E}"]

private func glyph(_ indices: Int...) -> Character {
    Character("\u{10EEEE}" + indices.map { marks[$0] }.joined())
}

private func cell(
    _ row: Int, _ column: Int, _ character: Character, foreground: GraphicsColor = .indexed(42),
    underline: GraphicsColor = .none, background: GraphicsColor = .none
) -> GraphicsCell {
    GraphicsCell(
        point: GridPoint(row: row, column: column), character: character,
        foreground: foreground, underline: underline, background: background
    )
}

struct KittyRootEditTests {
    private func redPixel(_ placement: GraphicsPlacement, at date: Date, _ x: Int = 0, _ y: Int = 0) -> [UInt8] {
        guard let source = animation(placement) else { return [] }
        let cg = source.frame(at: date, cropping: nil)
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
            return true
        }
        return drawn ? pixel : []
    }

    @Test func editingTheRootFrameShowsInLaterPlacements() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,r=1", "/wAA"))
        rig.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(rig.images.count == 2)
        #expect(redPixel(rig.images[1], at: rig.clock.date) == [255, 0, 0, 255])
    }

    @Test func composingOntoTheRootFrameShowsInLaterPlacements() {
        let rig = KittyRig()
        let blank = String(repeating: "A", count: 22) + "=="
        rig.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", blank))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,c=1", "/wAA"))
        rig.feed(apc("a=c,i=1,r=2,c=1,w=1,h=1,x=1,y=1,C=1"))
        rig.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(redPixel(rig.images[1], at: rig.clock.date, 1, 1) == [255, 0, 0, 255])
        #expect(redPixel(rig.images[1], at: rig.clock.date, 0, 0)[3] == 0)
    }

    @Test func editingANonRootFrameLeavesTheRootAlone() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1", "/wAA"))
        rig.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(redPixel(rig.images[1], at: rig.clock.date) == [0, 0, 0, 255])
    }
}

struct KittyQueryTests {
    @Test func queryOfValidDataRepliesOKWithoutStoring() {
        let rig = KittyRig()
        rig.feed(apc("a=q,f=24,s=1,v=1,i=31", pixel))
        #expect(rig.replies.contain("i=31;OK"))
        #expect(rig.sources[31] == nil)
        #expect(rig.images.isEmpty)
    }

    @Test func queryOfBadFormatRepliesWithTheError() {
        let rig = KittyRig()
        rig.feed(apc("a=q,f=99,s=1,v=1,i=31", pixel))
        #expect(rig.replies.contain("i=31;EINVAL:Unknown image format: 99"))
        #expect(!rig.replies.contain("OK"))
    }

    @Test func queryWithAnIDAndANumberIsRejected() {
        let rig = KittyRig()
        rig.feed(apc("a=q,f=24,s=1,v=1,i=31,I=2", pixel))
        #expect(rig.replies.contain("EINVAL:Must not specify both image id and image number"))
        #expect(!rig.replies.contain("OK"))
    }

    @Test func queryOfShortDataRepliesWithTheError() {
        let rig = KittyRig()
        rig.feed(apc("a=q,f=24,s=2,v=2,i=31", pixel))
        #expect(rig.replies.contain("i=31;ENODATA:Insufficient image data: 3 < 12"))
        #expect(rig.sources[31] == nil)
    }

    @Test func queryDoesNotDisturbAnExistingImage() {
        let rig = KittyRig()
        rig.feed(transmit(31))
        rig.feed(apc("a=q,f=24,s=1,v=1,i=31", pixel))
        #expect(rig.sources[31] != nil)
        rig.feed(apc("a=p,i=31,C=1"))
        #expect(rig.images.count == 1)
    }
}

struct KittyMissingActionTests {
    @Test func missingActionTransmitsLikeT() {
        let rig = KittyRig()
        rig.feed(apc("f=24,s=1,v=1,i=9", pixel))
        #expect(rig.replies.contain("i=9;OK"))
        #expect(rig.sources[9] != nil)
        #expect(rig.images.isEmpty)
        rig.feed(apc("a=p,i=9,C=1"))
        #expect(rig.images.map(\.kittyID) == [9])
    }

    @Test func missingActionFeedsTheQuota() {
        let rig = KittyRig()
        rig.feed(apc("f=24,s=1,v=1,i=9", pixel))
        #expect(rig.engine.store.usedStorage > 0)
    }

    @Test func chunksWithoutAnActionContinueTheActiveJob() {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=2,v=1,i=6,m=1", "AAAA"))
        #expect(rig.sources[6] == nil)
        rig.feed(apc("m=0", "AAAA"))
        #expect(rig.sources[6]?.size.width == 2)
    }

    @Test func chunkedTransmitWithoutAnyActionKey() {
        let rig = KittyRig()
        rig.feed(apc("f=24,s=2,v=1,i=6,m=1", "AAAA"))
        rig.feed(apc("m=0", "AAAA"))
        #expect(rig.sources[6]?.size.width == 2)
    }

    @Test func aStrayChunkWithoutAJobChangesNothing() {
        let rig = KittyRig()
        rig.feed(apc("m=0", "AAAA"))
        #expect(rig.images.isEmpty && rig.sources.isEmpty)
    }
}

struct KittyFileSliceTests {
    private func place(_ data: Data, _ keys: String, medium: String = "f") -> KittyRig {
        let url = scratchFile(data, protocolName: false)
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,t=\(medium),i=1,C=1,\(keys)", base64(url.path)))
        try? FileManager.default.removeItem(at: url)
        return rig
    }

    @Test func offsetSkipsTheStartOfTheFile() {
        let data = Data([9, 9, 1, 2, 3])
        #expect(place(data, "O=2").images.count == 1)
        let short = place(data, "O=3")
        #expect(short.replies.contain("EBADF"))
        #expect(short.images.isEmpty)
    }

    @Test func sizeLimitsHowMuchIsRead() {
        let data = Data(count: 8)
        #expect(place(data, "S=3").images.count == 1)
        let short = place(data, "S=2")
        #expect(short.replies.contain("EBADF"))
        #expect(short.images.isEmpty)
    }

    @Test func sizeAndOffsetCombine() {
        #expect(place(Data(count: 8), "S=3,O=5").images.count == 1)
        let short = place(Data(count: 8), "S=3,O=6")
        #expect(short.replies.contain("EBADF"))
        #expect(short.images.isEmpty)
    }

    @Test func slicedFileIsRefusedWhenLocalMediaIsDisallowed() {
        let url = scratchFile(Data([9, 9, 1, 2, 3]), protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.host.allowsLocalMedia = false
        rig.feed(apc("a=T,f=24,s=1,v=1,t=f,i=1,C=1,O=2", base64(url.path)))
        #expect(rig.replies.contain("EBADF"))
        #expect(rig.images.isEmpty)
    }

    @Test(.enabled(if: KittySharedMemory.works(), "POSIX shared memory cannot be created, mapped and re-opened read-only here"))
    func sharedMemoryHonoursSizeAndOffset() {
        let first = KittySharedMemory.uniqueName()
        let second = KittySharedMemory.uniqueName()
        defer {
            KittySharedMemory.unlink(first)
            KittySharedMemory.unlink(second)
        }
        #expect(KittySharedMemory.create(first, size: 5) && KittySharedMemory.create(second, size: 5))
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,t=s,i=1,C=1,S=3,O=2", base64(first)))
        #expect(rig.images.count == 1)
        rig.feed(apc("a=T,f=24,s=1,v=1,t=s,i=2,C=1,O=20000", base64(second)))
        #expect(rig.replies.contain("i=2;EBADF"))
        #expect(rig.images.map(\.kittyID) == [1])
    }
}

struct KittyDeleteNumberTests {
    @Test func deleteByNumberRemovesThePlacementsOfThatImage() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        rig.feed(apc("a=d,d=N,I=5"))
        #expect(rig.images.isEmpty)
        #expect(rig.sources[1] == nil)
    }

    @Test func lowercaseDeleteByNumberKeepsTheData() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        rig.feed(apc("a=d,d=n,I=5"))
        #expect(rig.images.isEmpty)
        #expect(rig.sources[1] != nil)
    }

    @Test func deleteOfAnUnknownNumberChangesNothing() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        rig.feed(apc("a=d,d=N,I=6"))
        #expect(rig.images.count == 1)
        #expect(rig.sources[1] != nil)
    }
}

struct KittyVirtualDeleteTests {
    private func scene() -> KittyRig {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,p=3,c=1,r=1,z=-3,q=2", pixel))
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=43,p=4,c=1,r=1,z=2,q=2", pixel))
        return rig
    }

    @Test func deleteAllRemovesVirtualPlacementsAndKeepsTheData() {
        let rig = scene()
        rig.feed(apc("a=d,d=a"))
        #expect(rig.virtualPlacements.isEmpty)
        #expect(rig.sources[42] != nil && rig.sources[43] != nil)
    }

    @Test func uppercaseDeleteAllAlsoFreesTheData() {
        let rig = scene()
        rig.feed(apc("a=d,d=A"))
        #expect(rig.virtualPlacements.isEmpty)
        #expect(rig.sources[42] == nil && rig.sources[43] == nil)
    }

    @Test func deleteWithoutATargetRemovesVirtualPlacements() {
        let rig = scene()
        rig.feed(apc("a=d"))
        #expect(rig.virtualPlacements.isEmpty)
    }

    @Test func deleteByZIndexRemovesOnlyMatchingVirtualPlacements() {
        let rig = scene()
        rig.feed(apc("a=d,d=z,z=-3"))
        #expect(rig.virtualPlacements.map(\.kittyID) == [43])
        rig.feed(apc("a=d,d=Z,z=2"))
        #expect(rig.virtualPlacements.isEmpty)
        #expect(rig.sources[43] == nil)
    }

    @Test func positionBasedDeletesLeaveVirtualPlacementsAlone() {
        let rig = scene()
        for keys in ["d=p,x=1,y=1", "d=P,x=1,y=1", "d=c", "d=x,x=1", "d=y,y=1", "d=q,x=1,y=1,z=-3"] {
            rig.feed(apc("a=d,\(keys)"))
            #expect(rig.virtualPlacements.count == 2, "\(keys)")
        }
    }

    @Test func deleteByIDAndRangeStillRemoveVirtualPlacements() {
        let rig = scene()
        rig.feed(apc("a=d,d=i,i=42,p=3"))
        #expect(rig.virtualPlacements.map(\.kittyID) == [43])
        rig.feed(apc("a=d,d=r,x=40,y=50"))
        #expect(rig.virtualPlacements.isEmpty)
    }
}

struct KittyChainDepthTests {
    @Test func chainsBeyondTheLimitAreRejected() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,i=1,p=1,C=1", pixel))
        for id in 2...17 {
            rig.feed(apc("a=T,f=24,s=1,v=1,i=\(id),p=1,P=\(id - 1),Q=1", pixel))
        }
        #expect(!rig.replies.contain("ETOODEEP"))
        #expect(rig.images.count == 17)
        rig.feed(apc("a=T,f=24,s=1,v=1,i=18,p=1,P=17,Q=1", pixel))
        #expect(rig.replies.contain("ETOODEEP"))
        #expect(rig.images.count == 17)
    }
}

struct KittyPNGErrorTests {
    private func reply(_ bytes: [UInt8]) -> String {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=100,i=1", Data(bytes).base64EncodedString()))
        return rig.replies.lines.joined()
    }

    @Test func signatureProblemsUseLibpngMessages() {
        #expect(reply([0, 1, 2, 3, 4, 5, 6, 7, 8]).contains("EBADPNG:Not a PNG file"))
        var corrupted = pngSignature
        corrupted[4] = 0x0A
        #expect(reply(corrupted + [0]).contains("EBADPNG:PNG file corrupted by ASCII conversion"))
    }

    @Test func truncationIsReportedLikeKittysReadCallback() {
        let message = "EBADPNG:PNG data is truncated: not enough bytes to satisfy read request"
        #expect(reply([0x89, 0x50]).contains(message))
        #expect(reply(pngSignature).contains(message))
        let idat = pngSignature + pngChunk("IHDR", header(width: 1, height: 1)) + [0, 0, 0, 100] + Array("IDAT".utf8) + [1, 2]
        #expect(reply(idat).contains(message))
    }

    @Test func chunkProblemsCarryTheChunkName() {
        #expect(reply(pngSignature + pngChunk("tEXt", [65])).contains("EBADPNG:tEXt: missing IHDR"))
        #expect(reply(pngSignature + pngChunk("IDAT", [])).contains("EBADPNG:IDAT: Missing IHDR before IDAT"))
        #expect(reply(pngSignature + pngChunk("IHDR", header(width: 1, height: 1), badChecksum: true)).contains("EBADPNG:IHDR: CRC error"))
        #expect(reply(pngSignature + [0x80, 0, 0, 0] + Array("IHDR".utf8)).contains("EBADPNG:IHDR: bad header (invalid length)"))
        #expect(reply(pngSignature + [0, 0, 0, 0, 0x31, 0x32, 0x33, 0x34]).contains("EBADPNG:[31][32][33][34]: bad header (invalid type)"))
        #expect(reply(pngSignature + pngChunk("IHDR", [1, 2, 3])).contains("EBADPNG:IHDR: too short"))
    }

    @Test func headerValidationUsesLibpngRules() {
        #expect(reply(pngSignature + pngChunk("IHDR", header(width: 0, height: 1))).contains("EBADPNG:Invalid IHDR data"))
        #expect(reply(pngSignature + pngChunk("IHDR", header(width: 1, height: 1, depth: 3))).contains("EBADPNG:Invalid IHDR data"))
        #expect(reply(pngSignature + pngChunk("IHDR", header(width: 1, height: 1, depth: 4, color: 6))).contains("EBADPNG:Invalid IHDR data"))
        #expect(reply(pngSignature + pngChunk("IHDR", header(width: 0x80000000, height: 1))).contains("EBADPNG:PNG unsigned integer out of range"))
        let palette = pngSignature + pngChunk("IHDR", header(width: 1, height: 1, depth: 8, color: 3)) + pngChunk("IDAT", [])
        #expect(reply(palette).contains("EBADPNG:IDAT: Missing PLTE before IDAT"))
    }

    @Test func hugeImagesAreRejectedAfterTheHeaderChunks() {
        let big = pngSignature + pngChunk("IHDR", header(width: 10001, height: 1)) + pngChunk("IDAT", [])
        #expect(reply(big).contains("ENOMEM:PNG image is too large"))
    }

    @Test func validPNGStillPlaces() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=100,i=1,C=1", pngPixel))
        #expect(rig.images.count == 1)
    }

    @Test func rejectedPNGLeavesNothingStored() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=100,i=1,C=1", Data([1, 2, 3, 4, 5, 6, 7, 8]).base64EncodedString()))
        #expect(rig.images.isEmpty)
        #expect(rig.sources[1] == nil)
    }
}

struct KittyZlibTests {
    private func reply(_ name: String, width: Int = 5) -> String {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=32,s=\(width),v=2,o=z,i=1,C=1", zlibFixtures[name]!))
        return rig.replies.lines.joined() + "|images=\(rig.images.count)"
    }

    @Test func truncatedStreamsAreBufferErrorsLikeZlib() {
        for name in ["truncatedBody", "missingTrailer", "partialTrailer", "headerOnly", "oneByte"] {
            #expect(reply(name).contains("Failed to inflate image data with error: Z_BUF_ERROR"), "\(name)")
        }
    }

    @Test func corruptStreamsAreDataErrorsLikeZlib() {
        for name in ["badChecksum", "badHeader", "corruptBody"] {
            #expect(reply(name).contains("Failed to inflate image data with error: Z_DATA_ERROR"), "\(name)")
        }
    }

    @Test func outputLargerThanExpectedIsABufferError() {
        #expect(reply("good", width: 2).contains("Failed to inflate image data with error: Z_BUF_ERROR"))
    }

    @Test func outputSmallerThanExpectedIsASizeMismatch() {
        #expect(reply("good", width: 9).contains("Image data size post inflation does not match expected size"))
    }

    @Test func goodStreamsAndTrailingBytesAreAccepted() {
        #expect(reply("good").hasSuffix("|images=1"))
        #expect(reply("trailing").hasSuffix("|images=1"))
    }

    @Test func failedStreamsPlaceNothing() {
        #expect(reply("badChecksum").hasSuffix("|images=0"))
    }
}

struct KittyPlaceholderTests {
    private func drawn() -> KittyRig {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=2,q=2", pixel))
        rig.host.cells = [
            cell(0, 0, glyph(0, 0)), cell(0, 1, glyph(0, 1)),
            cell(1, 0, glyph(1, 0)), cell(1, 1, glyph(1, 1)),
        ]
        return rig
    }

    @Test func virtualPlacementIsRegisteredWithoutDrawing() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=2,q=2", pixel))
        #expect(rig.images.isEmpty)
        #expect(rig.virtualPlacements.count == 1)
        #expect(rig.virtualPlacements[0].columnSpan == 2 && rig.virtualPlacements[0].rowSpan == 2)
        #expect(rig.host.cursor == GridPoint(row: 0, column: 0))
        #expect(rig.visible().isEmpty)
    }

    @Test func virtualPlacementFromAnEarlierTransmit() {
        let rig = KittyRig()
        rig.feed(transmit(5))
        rig.feed(apc("a=p,U=1,i=5,p=3,c=4,r=1"))
        #expect(rig.virtualPlacements.map(\.placementID) == [3])
        rig.feed(apc("a=d,d=i,i=5"))
        #expect(rig.virtualPlacements.isEmpty)
    }

    @Test func virtualPlacementOfUnknownImageIsRejected() {
        let rig = KittyRig()
        rig.feed(apc("a=p,U=1,i=8,c=1,r=1"))
        #expect(rig.replies.contain("ENOENT"))
        #expect(rig.virtualPlacements.isEmpty)
    }

    @Test func placeholderCellsBecomeImageTiles() {
        let rig = drawn()
        let found = rig.tiles()
        #expect(found.count == 2)
        #expect(found.map(\.origin) == [GridPoint(row: 0, column: 0), GridPoint(row: 1, column: 0)])
        #expect(found.allSatisfy { $0.columnSpan == 2 && $0.rowSpan == 1 && $0.tile?.columns == 2 && $0.tile?.rows == 2 })
        #expect(found.map { $0.tile?.partRow } == [0, 1])
        #expect(found.allSatisfy { $0.tile?.partColumn == 0 })
        #expect(found.allSatisfy { $0.kittyID == 42 })
    }

    @Test func placeholdersWithoutAPlacementStayText() {
        let rig = KittyRig()
        rig.host.cells = [cell(0, 0, glyph(0, 0), foreground: .indexed(9))]
        #expect(rig.tiles().isEmpty)
    }

    @Test func placeholdersOutsideTheVisibleRowsAreIgnored() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        rig.host.cells = [cell(0, 0, glyph(0, 0))]
        #expect(rig.visible(5..<10).filter { $0.tile != nil }.isEmpty)
        #expect(rig.visible(0..<10).filter { $0.tile != nil }.count == 1)
    }

    @Test func placeholderTilesFollowTheScrolledScreen() {
        let rig = KittyRig(columns: 40, rows: 5)
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        rig.feed(text(String(repeating: "\n", count: 12)))
        rig.host.cells = [cell(10, 3, glyph(0, 0))]
        let found = rig.tiles()
        #expect(found.map(\.origin) == [GridPoint(row: 10, column: 3)])
    }

    @Test func relativePlacementCanFollowAVirtualParent() {
        let rig = drawn()
        rig.feed(apc("a=T,f=24,s=1,v=1,i=7,p=1,P=42,Q=0,H=1,V=1", pixel))
        #expect(!rig.replies.contain("ENOPARENT"))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].parent == KittyParent(imageID: 42, placementID: 0, columns: 1, rows: 1))
    }

    @Test func relativeChildOfAVirtualParentIsPlacedFromTheTileOrigin() {
        let rig = drawn()
        rig.feed(apc("a=T,f=24,s=1,v=1,i=7,p=1,P=42,Q=0,H=1,V=1", pixel))
        let child = rig.visible().first { $0.kittyID == 7 }
        #expect(child?.origin == GridPoint(row: 1, column: 1))
    }

    @Test func deletingTheVirtualParentDeletesTheChild() {
        let rig = drawn()
        rig.feed(apc("a=T,f=24,s=1,v=1,i=7,p=1,P=42,Q=0", pixel))
        #expect(rig.images.count == 1)
        rig.feed(apc("a=d,d=i,i=42"))
        #expect(rig.images.isEmpty)
    }
}

struct KittyPlaceholderStyleTests {
    @Test func tilesCarryTheCellBackgroundAndTheVirtualZIndex() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,z=-3,q=2", pixel))
        rig.host.cells = [cell(0, 0, glyph(0, 0), background: .rgb(10, 20, 30))]
        let found = rig.tiles()
        #expect(found.count == 1)
        #expect(found[0].zIndex == -3)
        #expect(found[0].background == .rgb(10, 20, 30))
    }

    @Test func cellsWithDifferentBackgroundsAreNotMerged() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=1,q=2", pixel))
        rig.host.cells = [
            cell(0, 0, glyph(0, 0), background: .indexed(1)),
            cell(0, 1, glyph(0, 1), background: .indexed(2)),
        ]
        #expect(rig.tiles().count == 2)
    }

    @Test func cellsWithTheSameBackgroundAreMerged() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=1,q=2", pixel))
        rig.host.cells = [
            cell(0, 0, glyph(0, 0), background: .indexed(1)),
            cell(0, 1, glyph(0, 1), background: .indexed(1)),
        ]
        let found = rig.tiles()
        #expect(found.count == 1)
        #expect(found[0].columnSpan == 2)
    }

    @Test func plainCellsHaveNoBackground() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        rig.host.cells = [cell(0, 0, glyph(0, 0))]
        #expect(rig.tiles().first?.background == GraphicsColor.none)
    }
}

struct KittyPlaceholderIdentityTests {
    private func twoPlacements(id: Int) -> KittyRig {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=1,v=1,i=\(id)", pixel))
        rig.feed(apc("a=p,U=1,i=\(id),p=7,c=1,r=1"))
        rig.feed(apc("a=p,U=1,i=\(id),p=8,c=2,r=1"))
        return rig
    }

    @Test func thirdDiacriticSuppliesTheHighByteOfTheID() {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=1,v=1,i=\(0x0100_002A)", pixel))
        rig.feed(apc("a=p,U=1,i=\(0x0100_002A),c=1,r=1"))
        rig.host.cells = [cell(0, 0, glyph(0, 0, 1))]
        #expect(rig.tiles().map(\.kittyID) == [0x0100_002A])
        let plain = KittyRig()
        plain.feed(apc("a=t,f=24,s=1,v=1,i=42", pixel))
        plain.feed(apc("a=p,U=1,i=42,c=1,r=1"))
        plain.host.cells = [cell(0, 0, glyph(0, 0, 1))]
        #expect(plain.tiles().isEmpty)
    }

    @Test func trueColourForegroundSuppliesTheID() {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=1,v=1,i=258", pixel))
        rig.feed(apc("a=p,U=1,i=258,c=1,r=1"))
        rig.host.cells = [cell(0, 0, glyph(0, 0), foreground: .rgb(0, 1, 2))]
        #expect(rig.tiles().map(\.kittyID) == [258])
    }

    @Test func the256ColourForegroundSuppliesTheID() {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=1,v=1,i=200", pixel))
        rig.feed(apc("a=p,U=1,i=200,c=1,r=1"))
        rig.host.cells = [cell(0, 0, glyph(0, 0), foreground: .indexed(200))]
        #expect(rig.tiles().map(\.kittyID) == [200])
    }

    @Test func trueColourUnderlineSuppliesThePlacementID() {
        let rig = twoPlacements(id: 42)
        rig.host.cells = [
            cell(0, 0, glyph(0, 0), underline: .rgb(0, 0, 8)),
            cell(0, 1, glyph(0, 1), underline: .rgb(0, 0, 8)),
        ]
        let found = rig.tiles()
        #expect(found.count == 1)
        #expect(found[0].placementID == 8)
        #expect(found[0].tile?.columns == 2)
    }

    @Test func indexedUnderlineSuppliesThePlacementID() {
        let rig = twoPlacements(id: 42)
        rig.host.cells = [
            cell(0, 0, glyph(0, 0), underline: .indexed(8)),
            cell(0, 1, glyph(0, 1), underline: .indexed(8)),
        ]
        let found = rig.tiles()
        #expect(found.count == 1)
        #expect(found[0].placementID == 8)
        #expect(found[0].tile?.columns == 2)
    }

    @Test func otherUnderlineSelectsTheOtherPlacement() {
        let rig = twoPlacements(id: 42)
        rig.host.cells = [cell(0, 0, glyph(0, 0), underline: .indexed(7))]
        let found = rig.tiles()
        #expect(found.count == 1)
        #expect(found[0].placementID == 7)
        #expect(found[0].tile?.columns == 1)
    }
}

struct KittyPlaceholderCropTests {
    private func fill(_ rig: KittyRig, columns: Int, rows: Int) {
        rig.host.cells = (0..<rows).flatMap { row in
            (0..<columns).map { column in cell(row, column, glyph(row, column)) }
        }
    }

    private func source(_ tile: GraphicsPlacement) -> CGRect {
        guard let crop = tile.crop, let part = tile.tile else { return .zero }
        let width = crop.width / CGFloat(part.columns)
        let height = crop.height / CGFloat(part.rows)
        return CGRect(
            x: crop.minX + CGFloat(part.partColumn) * width, y: crop.minY + CGFloat(part.partRow) * height,
            width: CGFloat(tile.columnSpan) * width, height: height
        )
    }

    private func big() -> String {
        Data(count: 48).base64EncodedString()
    }

    @Test func cropIsCarriedToTheVirtualPlacement() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=4,v=4,i=42,c=2,r=2,x=1,y=1,w=2,h=2,q=2", big()))
        let placement = rig.virtualPlacements[0]
        #expect(placement.crop == CGRect(x: 1, y: 1, width: 2, height: 2))
        #expect(placement.pixelSize == CGSize(width: 2, height: 2))
    }

    @Test func cropThenTilingSplitsTheCroppedRegion() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=4,v=4,i=42,c=2,r=2,x=1,y=1,w=2,h=2,q=2", big()))
        fill(rig, columns: 2, rows: 2)
        let found = rig.tiles()
        #expect(found.count == 2)
        #expect(found.map(source) == [CGRect(x: 1, y: 1, width: 2, height: 1), CGRect(x: 1, y: 2, width: 2, height: 1)])
    }

    @Test func omittedSizeCropsToTheEdge() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=4,v=4,i=42,c=3,r=2,x=1,y=2,q=2", big()))
        #expect(rig.virtualPlacements[0].crop == CGRect(x: 1, y: 2, width: 3, height: 2))
        fill(rig, columns: 3, rows: 2)
        let found = rig.tiles()
        #expect(found.map(source) == [CGRect(x: 1, y: 2, width: 3, height: 1), CGRect(x: 1, y: 3, width: 3, height: 1)])
    }

    @Test func uncroppedPlacementHasNoCrop() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=4,v=4,i=42,c=2,r=2,q=2", big()))
        #expect(rig.virtualPlacements[0].crop == nil)
        #expect(rig.virtualPlacements[0].pixelSize == CGSize(width: 4, height: 4))
    }
}

struct KittyClearTests {
    private func scrolledOff() -> KittyRig {
        let rig = KittyRig(columns: 40, rows: 5)
        rig.feed(put("i=1,C=1"))
        rig.feed(text(String(repeating: "\n", count: 12)))
        return rig
    }

    @Test func clearScreenKeepsImagesReferencedFromScrollback() {
        let rig = scrolledOff()
        #expect(rig.host.screen.top == 8)
        rig.feed(text("\u{1B}[2J"))
        #expect(rig.sources[1] != nil)
        #expect(rig.images.count == 1)
        rig.feed(apc("a=p,i=1,C=1"))
        #expect(rig.images.count == 2)
    }

    @Test func clearScreenRemovesPlacementsOnTheScreen() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1") + move(8, 1) + put("i=2,C=1"))
        rig.feed(text("\u{1B}[2J"))
        #expect(rig.images.isEmpty)
    }

    @Test func clearScreenFreesImagesWithNoPlacementsLeft() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1") + transmit(2))
        rig.feed(text("\u{1B}[2J"))
        #expect(rig.sources.isEmpty)
        rig.feed(apc("a=p,i=1"))
        #expect(rig.replies.contain("ENOENT"))
    }

    @Test func eraseScrollbackFreesEverythingUnreferenced() {
        let rig = scrolledOff()
        rig.feed(text("\u{1B}[3J"))
        #expect(rig.sources.isEmpty && rig.images.isEmpty)
    }

    @Test func virtualPlacementsKeepTheirImageAcrossClears() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        rig.feed(text("\u{1B}[2J\u{1B}[3J"))
        #expect(rig.sources[42] != nil)
        #expect(rig.virtualPlacements.count == 1)
    }

    @Test func hardResetFreesBothBuffers() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.enterAlternate()
        rig.feed(transmit(9))
        rig.feed(text("\u{1B}c"))
        rig.leaveAlternate()
        #expect(rig.sources.isEmpty && rig.images.isEmpty)
        rig.feed(apc("a=p,i=1"))
        #expect(rig.replies.contain("i=1;ENOENT"))
    }

    @Test func clearAllDropsEveryImage() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1") + transmit(2) + apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        rig.engine.clearAll()
        #expect(rig.images.isEmpty)
        #expect(rig.virtualPlacements.isEmpty)
        #expect(rig.sources.isEmpty)
    }

    @Test func placementsAfterAnExplicitClearSurvive() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.engine.clear(.visible, host: rig.host)
        rig.feed(put("i=2,C=1"))
        #expect(ids(rig) == [2])
    }
}

struct KittyFreeTests {
    @Test func uppercaseDeleteFreesTheImage() {
        let rig = KittyRig()
        rig.feed(transmit(1))
        rig.feed(apc("a=d,d=I,i=1"))
        #expect(rig.sources[1] == nil)
        rig.feed(apc("a=p,i=1"))
        #expect(rig.replies.contain("ENOENT"))
        #expect(rig.images.isEmpty)
    }

    @Test func lowercaseDeleteKeepsTheImage() {
        let rig = KittyRig()
        rig.feed(transmit(1) + apc("a=p,i=1,C=1") + apc("a=d,d=i,i=1"))
        #expect(rig.sources[1] != nil)
        rig.feed(apc("a=p,i=1,C=1"))
        #expect(rig.images.count == 1)
    }

    @Test func freeingOneImageKeepsTheOthers() {
        let rig = KittyRig()
        rig.feed(transmit(1) + transmit(2) + apc("a=d,d=I,i=1"))
        #expect(rig.sources[1] == nil)
        #expect(rig.sources[2] != nil)
    }

    @Test func uppercaseDeleteAllFreesOnlyImagesWhosePlacementsWentAway() {
        let rig = KittyRig()
        rig.feed(transmit(1) + transmit(2) + apc("a=p,i=1,C=1") + apc("a=d,d=A"))
        #expect(rig.sources[1] == nil && rig.sources[2] != nil)
    }
}

struct KittyBufferTests {
    @Test func eachScreenBufferHasItsOwnImageTable() {
        let rig = KittyRig()
        rig.feed(transmit(1))
        rig.enterAlternate()
        rig.feed(apc("a=p,i=1,C=1"))
        #expect(rig.replies.contain("i=1;ENOENT"))
        rig.feed(transmit(7))
        rig.feed(apc("a=p,i=7,C=1"))
        #expect(rig.visible().compactMap(\.kittyID) == [7])
        rig.leaveAlternate()
        rig.feed(apc("a=p,i=7,C=1"))
        #expect(rig.replies.contain("i=7;ENOENT"))
        #expect(rig.sources.keys.sorted() == [1])
        rig.feed(apc("a=p,i=1,C=1"))
        #expect(rig.images.compactMap(\.kittyID) == [1])
    }

    @Test func enteringTheAlternateScreenClearsItsImages() {
        let rig = KittyRig()
        rig.enterAlternate()
        rig.feed(transmit(7))
        rig.leaveAlternate()
        rig.enterAlternate()
        rig.feed(apc("a=p,i=7,C=1"))
        #expect(rig.replies.contain("i=7;ENOENT"))
    }

    @Test func enteringAndLeavingTheAlternateScreenKeepsNormalImages() {
        let rig = KittyRig()
        rig.feed(transmit(1) + apc("a=p,i=1,C=1"))
        rig.enterAlternate()
        rig.leaveAlternate()
        #expect(rig.sources[1] != nil)
        #expect(rig.images.count == 1)
    }

    @Test func quotasAreSeparatePerBuffer() {
        let rig = KittyRig()
        rig.engine.store.storageLimit = 5
        rig.enterAlternate()
        rig.feed(apc("a=t,f=32,s=1,v=1,i=1", "AAAAAA==") + apc("a=t,f=32,s=1,v=1,i=2", "AAAAAA=="))
        rig.feed(apc("a=p,i=1,C=1") + apc("a=p,i=2,C=1"))
        #expect(!rig.replies.contain("ENOENT"))
        rig.leaveAlternate()
        rig.feed(apc("a=t,f=32,s=1,v=1,i=3", "AAAAAA==") + apc("a=t,f=32,s=1,v=1,i=4", "AAAAAA=="))
        #expect(rig.sources.keys.sorted() == [4])
    }

    @Test func alternateScreenPlacementsStayOutOfTheNormalScreen() {
        let rig = KittyRig()
        rig.enterAlternate()
        rig.feed(put("i=1,C=1"))
        #expect(rig.visible().count == 1)
        rig.leaveAlternate()
        #expect(rig.images.isEmpty)
        #expect(rig.visible().isEmpty)
    }
}

struct KittyPruneTests {
    @Test func placementsFullyAboveTheTrimLineAreDropped() {
        let rig = KittyRig()
        rig.feed(move(1, 1) + put("i=1,C=1") + move(4, 1) + put("i=2,C=1"))
        rig.engine.pruneScrolledOff(trimmed: 1)
        #expect(ids(rig) == [2])
        rig.engine.pruneScrolledOff(trimmed: 4)
        #expect(ids(rig).isEmpty)
    }

    @Test func nothingIsDroppedWhenNothingWasTrimmed() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.engine.pruneScrolledOff(trimmed: 0)
        #expect(ids(rig) == [1])
    }

    @Test func tallPlacementsSurviveUntilTheirLastRowIsTrimmed() {
        let rig = KittyRig()
        rig.feed(put("i=1,c=1,r=3,C=1"))
        rig.engine.pruneScrolledOff(trimmed: 2)
        #expect(ids(rig) == [1])
        rig.engine.pruneScrolledOff(trimmed: 3)
        #expect(ids(rig).isEmpty)
    }

    @Test func childrenOfAPrunedParentGoWithIt() {
        let rig = KittyRig()
        rig.feed(put("i=1,p=1,C=1"))
        rig.feed(apc("a=T,f=24,s=1,v=1,i=2,p=1,P=1,Q=1,V=1", pixel))
        #expect(rig.images.count == 2)
        rig.engine.pruneScrolledOff(trimmed: 1)
        #expect(rig.images.isEmpty)
    }

    @Test func virtualPlacementsAreNotPruned() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        rig.engine.pruneScrolledOff(trimmed: 100)
        #expect(rig.virtualPlacements.count == 1)
    }
}

struct KittyCellRequestTests {
    @Test func placementCarriesTheRequestedCells() {
        let rig = KittyRig()
        rig.feed(put("i=1,c=3,r=2"))
        #expect(rig.images[0].requested == GraphicsCellRequest(columns: 3, rows: 2))
    }

    @Test func unsizedPlacementFollowsTheImage() {
        let rig = KittyRig()
        rig.feed(put("i=1"))
        #expect(rig.images[0].requested == GraphicsCellRequest())
    }

    @Test func putKeepsItsOwnRequest() {
        let rig = KittyRig()
        rig.feed(transmit(5))
        rig.feed(apc("a=p,i=5,p=1,c=6"))
        rig.feed(apc("a=p,i=5,p=2,r=4"))
        #expect(rig.images.map(\.requested) == [GraphicsCellRequest(columns: 6), GraphicsCellRequest(rows: 4)])
    }

    @Test func chunkedTransferTakesTheRequestFromItsFirstChunk() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=2,v=1,i=6,c=5,r=3,m=1", "AAAA"))
        #expect(rig.images.isEmpty)
        rig.feed(apc("m=0", "AAAA"))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].requested == GraphicsCellRequest(columns: 5, rows: 3))
    }

    @Test func virtualPlacementAndItsTilesCarryTheRequest() {
        let rig = KittyRig()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=1,q=2", pixel))
        rig.host.cells = [cell(0, 0, glyph(0, 0)), cell(0, 1, glyph(0, 1))]
        #expect(rig.virtualPlacements[0].requested == GraphicsCellRequest(columns: 2, rows: 1))
        let tiles = rig.tiles()
        #expect(!tiles.isEmpty)
        #expect(tiles.allSatisfy { $0.requested == GraphicsCellRequest(columns: 2, rows: 1) })
    }

    @Test func negativeRequestsClampToZero() {
        #expect(GraphicsCellRequest(columns: -2, rows: -1) == GraphicsCellRequest())
    }
}

struct KittyNormalBufferLayoutTests {
    private func mainScreen() -> KittyRig {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=2,q=2", pixel))
        rig.host.cells = [
            cell(4, 0, glyph(0, 0)), cell(4, 1, glyph(0, 1)),
            cell(5, 0, glyph(1, 0)), cell(5, 1, glyph(1, 1)),
        ]
        return rig
    }

    @Test func normalBufferIsLaidOutWhileTheAlternateIsUp() {
        let rig = mainScreen()
        rig.enterAlternate()
        rig.host.alternateCells = [cell(0, 0, glyph(0, 0))]
        rig.host.scanned = []
        let placed = rig.engine.placements(visible: 0..<20, host: rig.host, buffer: .normal)
        #expect(rig.engine.isAlternate)
        #expect(rig.host.scanned == [.normal])
        #expect(placed.filter { $0.tile == nil }.compactMap(\.kittyID) == [1])
        let tiles = placed.filter { $0.tile != nil }.sorted { $0.origin.row < $1.origin.row }
        #expect(tiles.map(\.origin) == [GridPoint(row: 4, column: 0), GridPoint(row: 5, column: 0)])
        #expect(tiles.allSatisfy { $0.kittyID == 42 && $0.columnSpan == 2 })
    }

    @Test func activeLayoutStaysOnTheAlternateScreen() {
        let rig = mainScreen()
        rig.enterAlternate()
        rig.host.scanned = []
        #expect(rig.engine.placements(visible: 0..<20, host: rig.host).isEmpty)
        #expect(rig.host.scanned.allSatisfy { $0 == .alternate })
    }

    @Test func alternateBufferCanBeAskedForByName() {
        let rig = KittyRig()
        rig.enterAlternate()
        rig.feed(apc("a=T,U=1,f=24,s=1,v=1,i=9,c=1,r=1,q=2", pixel))
        rig.host.alternateCells = [cell(2, 3, glyph(0, 0), foreground: .indexed(9))]
        let tiles = rig.engine.placements(visible: 0..<10, host: rig.host, buffer: .alternate).filter { $0.tile != nil }
        #expect(tiles.map(\.origin) == [GridPoint(row: 2, column: 3)])
        #expect(rig.engine.placements(visible: 0..<10, host: rig.host, buffer: .normal).isEmpty)
    }

    @Test func originFollowsAVirtualParentOfTheNormalBuffer() throws {
        let rig = mainScreen()
        rig.feed(apc("a=T,f=24,s=1,v=1,i=7,p=1,P=42,Q=0,H=1,V=1", pixel))
        let child = try #require(rig.images.first { $0.kittyID == 7 })
        rig.enterAlternate()
        #expect(rig.engine.origin(of: child.id, host: rig.host, buffer: .normal) == GridPoint(row: 5, column: 1))
        #expect(rig.engine.origin(of: child.id, host: rig.host) == nil)
    }

    @Test func hardResetOnTheAlternateScreenReadsNormalPlaceholders() {
        let rig = mainScreen()
        rig.enterAlternate()
        rig.host.scanned = []
        rig.feed(text("\u{1B}c"))
        #expect(rig.host.scanned.contains(.normal))
    }
}
