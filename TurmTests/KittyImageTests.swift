import AppKit
import Compression
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import Turm

private let pixel = "AAAA"
private let pngPixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

private func apc(_ keys: String, _ payload: String = "") -> [UInt8] {
    let body = payload.isEmpty ? keys : "\(keys);\(payload)"
    return Array("\u{1B}_G\(body)\u{1B}\\".utf8)
}

private func put(_ keys: String) -> [UInt8] {
    apc("a=T,f=24,s=1,v=1,\(keys)", pixel)
}

private func transmit(_ id: Int) -> [UInt8] {
    apc("a=t,f=24,s=1,v=1,i=\(id)", pixel)
}

private func move(_ row: Int, _ column: Int) -> [UInt8] {
    Array("\u{1B}[\(row);\(column)H".utf8)
}

private func text(_ value: String) -> [UInt8] {
    Array(value.utf8)
}

private func ids(_ emulator: BlockEmulator) -> [UInt32] {
    emulator.images.compactMap(\.kittyID).sorted()
}

struct KittyScannerTests {
    @Test func parsesEveryPlacementKey() {
        let command = KittyGraphicsScanner.parse(
            Array("a=p,i=5,I=9,p=3,z=-2,X=4,Y=6,C=1,P=1,Q=2,H=-3,V=4,x=7,y=8,q=2,U=1".utf8)[...]
        )
        #expect(command.action == "p" && command.imageID == 5 && command.imageNumber == 9)
        #expect(command.placementID == 3 && command.zIndex == -2)
        #expect(command.pixelX == 4 && command.pixelY == 6 && command.cursorPolicy == 1)
        #expect(command.parentImage == 1 && command.parentPlacement == 2)
        #expect(command.parentColumns == -3 && command.parentRows == 4)
        #expect(command.x == 7 && command.y == 8 && command.quiet == 2 && command.virtual)
    }

    @Test func graphicsCommandsGetTheirOwnPiece() {
        let stream = text("before") + put("i=1") + text("after")
        let split = KittyGraphicsScanner.split(stream)
        #expect(split.remainder.isEmpty)
        #expect(split.pieces.count == 3)
        #expect(split.pieces[0].command == nil)
        #expect(split.pieces[1].command?.imageID == 1)
        #expect(String(decoding: split.pieces[2].bytes, as: UTF8.self) == "after")
    }

    @Test func unterminatedCommandIsHeldBack() {
        let full = put("i=1")
        let split = KittyGraphicsScanner.split(text("ab") + Array(full.dropLast(3)))
        #expect(split.pieces.count == 1)
        #expect(split.remainder.first == 0x1B)
        #expect(split.remainder.count == full.count - 3)
        #expect(KittyGraphicsScanner.split([0x61, 0x1B]).remainder.count == 1)
    }

    @Test func screenClearsGetTheirOwnPiece() {
        let split = KittyGraphicsScanner.split(text("a\u{1B}[2Jb\u{1B}[3J\u{1B}c"))
        let scopes = split.pieces.compactMap { piece -> KittyGraphicsScanner.ClearScope? in
            if case .clear(let scope) = piece.kind { return scope }
            return nil
        }
        #expect(scopes.count == 3)
        #expect(scopes[0] == .visible)
        #expect(scopes[1] == .everything && scopes[2] == .reset)
    }

    @Test func rewriteDropsAndReplacesKeys() {
        let original = apc("a=p,i=1,P=2,Q=3,C=0", "payload")
        let rewritten = KittyGraphicsScanner.rewrite(original[...], dropping: ["P", "Q"], setting: [("C", "1")])
        #expect(String(decoding: rewritten, as: UTF8.self) == "\u{1B}_Ga=p,i=1,C=1;payload\u{1B}\\")
    }
}

struct KittyPlacementTests {
    @Test func oneImageCanHaveSeveralPlacements() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1))
        emulator.feed(apc("a=p,i=1,p=1,C=1") + apc("a=p,i=1,p=2,C=1"))
        #expect(emulator.images.map(\.placementID) == [1, 2])
        #expect(emulator.images.allSatisfy { $0.kittyID == 1 })
    }

    @Test func samePlacementIDReplacesThePlacement() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1))
        emulator.feed(apc("a=p,i=1,p=1,C=1") + move(4, 4) + apc("a=p,i=1,p=1,C=1"))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].column == 3)
    }

    @Test func placementWithoutImageIDIgnoresPlacementID() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=24,s=1,v=1,p=4", pixel))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].placementID == nil)
    }

    @Test func retransmittingAnImageDropsItsPlacements() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1) + apc("a=p,i=1,p=1,C=1") + apc("a=p,i=1,p=2,C=1"))
        #expect(emulator.images.count == 2)
        emulator.feed(transmit(1))
        #expect(emulator.images.isEmpty)
    }

    @Test func zIndexIsRecorded() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,z=-1,C=1") + put("i=2,z=7,C=1"))
        #expect(emulator.images.map(\.zIndex) == [-1, 7])
    }

    @Test func cellOffsetsAreRecordedInPixels() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,X=3,Y=2,C=1"))
        #expect(emulator.images[0].pixelOffset == CGSize(width: 3, height: 2))
    }

    @Test func offsetsAreClampedInsideTheCell() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,X=5000,Y=5000,C=1"))
        let offset = emulator.images[0].pixelOffset
        #expect(offset.width > 0 && offset.width < 200)
        #expect(offset.height > 0 && offset.height < 200)
    }

    @Test func sourceRectangleCropsTheImage() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let data = String(repeating: "A", count: 22) + "=="
        emulator.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", data))
        emulator.feed(apc("a=T,f=32,s=2,v=2,i=2,x=1,y=0,w=1,h=2,C=1", data))
        #expect(emulator.images[0].pixelSize == CGSize(width: 2, height: 2))
        #expect(emulator.images[1].pixelSize == CGSize(width: 1, height: 2))
    }

    @Test func pngPlacementsAreTracked() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=100,i=8,z=2", pngPixel))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].kittyID == 8 && emulator.images[0].zIndex == 2)
        #expect(emulator.images[0].pixelSize == CGSize(width: 1, height: 1))
    }

    @Test func chunkedTransmissionIsPlacedOnce() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=24,s=2,v=1,i=6,m=1", "AAAA"))
        #expect(emulator.images.isEmpty)
        emulator.feed(apc("m=0", "AAAA"))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].kittyID == 6)
        #expect(emulator.images[0].pixelSize.width == 2)
    }

    @Test func commandSplitAcrossReadsIsAssembled() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let full = put("i=4")
        emulator.feed(Array(full[..<12]))
        #expect(emulator.images.isEmpty)
        emulator.feed(Array(full[12...]))
        #expect(emulator.images.map(\.kittyID) == [4])
    }

    @Test func imageNumbersGetAnIDAndReply() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        var replies: [String] = []
        emulator.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        emulator.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        #expect(replies.contains { $0.contains("i=1,I=5;OK") })
        #expect(emulator.images.map(\.kittyID) == [1])
        emulator.feed(apc("a=p,I=5,p=2,C=1"))
        #expect(emulator.images.count == 2)
        #expect(emulator.images[1].kittyID == 1 && emulator.images[1].placementID == 2)
        emulator.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        #expect(emulator.images.last?.kittyID == 2)
        emulator.feed(apc("a=d,d=n,I=5"))
        #expect(ids(emulator) == [1, 1])
    }
}

struct KittyLayoutTests {
    private func segments(_ emulator: BlockEmulator) -> [OutputSegment] {
        emulator.renderSegments()
    }

    @Test func cursorMovesPastThePlacedImage() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,c=3,r=2") + text("after"))
        let result = segments(emulator)
        #expect(result.count == 2)
        guard case .image(let image) = result[0] else {
            Issue.record("expected an image segment first")
            return
        }
        #expect(image.rowSpan == 2 && image.columnSpan == 3 && image.anchor == 0)
        #expect(result.plainText.contains("after"))
    }

    @Test func cursorPolicyKeepsTheCursorInPlace() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,c=3,r=2,C=1") + text("abc"))
        let result = segments(emulator)
        #expect(result.count == 1)
        guard case .stack(let stack) = result[0] else {
            Issue.record("text drawn over the image should form a stack")
            return
        }
        #expect(stack.rows == 2)
        #expect(String(stack.lines[0].characters) == "abc")
    }

    @Test func imageAtTheBottomScrollsTheScreen() {
        let emulator = BlockEmulator(cols: 40, rows: 5)
        emulator.feed(text("\n\n\n\n") + put("i=1,c=2,r=3") + text("z"))
        let result = segments(emulator)
        #expect(result.count == 3)
        guard case .image(let image) = result[1] else {
            Issue.record("expected the image between the text runs")
            return
        }
        #expect(image.anchor == 4 && image.rowSpan == 3)
        guard case .text(let tail) = result[2] else {
            Issue.record("expected text after the image")
            return
        }
        #expect(String(tail.characters).contains("z"))
    }

    @Test func overlappingImagesShareOneStackOrderedByZ() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,c=2,r=2,z=5,C=1") + put("i=2,c=2,r=2,z=-1,C=1"))
        let result = segments(emulator)
        #expect(result.count == 1)
        guard case .stack(let stack) = result[0] else {
            Issue.record("overlapping placements should share a stack")
            return
        }
        #expect(stack.rows == 2)
        #expect(stack.images.map(\.kittyID) == [2, 1])
    }

    @Test func imagesAreAnchoredToTheirColumn() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(move(1, 6) + put("i=1,C=1"))
        #expect(emulator.images[0].column == 5)
    }
}

struct KittyDeleteTests {
    private func scene() -> BlockEmulator {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(move(1, 1) + put("i=1,c=2,r=1,C=1"))
        emulator.feed(move(3, 5) + put("i=2,c=2,r=2,z=-1,C=1"))
        emulator.feed(move(6, 10) + put("i=3,c=1,r=1,z=5,C=1"))
        return emulator
    }

    @Test func everyDeleteFormRemovesTheRightPlacements() {
        let cases: [(String, [UInt32])] = [
            ("d=p,x=6,y=4", [1, 3]),
            ("d=P,x=1,y=1", [2, 3]),
            ("d=x,x=5", [1, 3]),
            ("d=X,x=10", [1, 2]),
            ("d=y,y=6", [1, 2]),
            ("d=Y,y=1", [2, 3]),
            ("d=z,z=-1", [1, 3]),
            ("d=Z,z=5", [1, 2]),
            ("d=q,x=6,y=4,z=-1", [1, 3]),
            ("d=q,x=6,y=4,z=0", [1, 2, 3]),
            ("d=r,x=2,y=3", [1]),
            ("d=R,x=1,y=1", [2, 3]),
            ("d=i,i=2", [1, 3]),
            ("d=I,i=2", [1, 3]),
            ("d=a", []),
            ("d=A", []),
            ("", []),
        ]
        for (keys, remaining) in cases {
            let emulator = scene()
            emulator.feed(apc(keys.isEmpty ? "a=d" : "a=d,\(keys)"))
            #expect(ids(emulator) == remaining, "\(keys)")
        }
    }

    @Test func deleteAtTheCursorRemovesPlacementsUnderIt() {
        let emulator = scene()
        emulator.feed(move(6, 10) + apc("a=d,d=c"))
        #expect(ids(emulator) == [1, 2])
        emulator.feed(move(9, 9) + apc("a=d,d=C"))
        #expect(ids(emulator) == [1, 2])
    }

    @Test func deletingOnePlacementKeepsTheOthers() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1) + apc("a=p,i=1,p=1,C=1") + apc("a=p,i=1,p=2,C=1"))
        emulator.feed(apc("a=d,d=i,i=1,p=2"))
        #expect(emulator.images.map(\.placementID) == [1])
    }

    @Test func deletedImageCanStillBePlacedAgainAfterSoftDelete() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1) + apc("a=p,i=1,p=1,C=1") + apc("a=d,d=i,i=1"))
        #expect(emulator.images.isEmpty)
        emulator.feed(apc("a=p,i=1,p=1,C=1"))
        #expect(emulator.images.count == 1)
    }

    @Test func freeingOneImageKeepsOthersPlaceable() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1) + transmit(2) + apc("a=p,i=1,p=1,C=1") + apc("a=d,d=I,i=2"))
        emulator.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(emulator.images.count == 2)
    }

    @Test func clearingTheScreenRemovesPlacements() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1") + text("\u{1B}[2J"))
        #expect(emulator.images.isEmpty)
    }

    @Test func imagePlacedAfterAClearSurvives() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1") + text("\u{1B}[3J\u{1B}[H") + put("i=2,C=1"))
        #expect(ids(emulator) == [2])
    }
}

struct KittyRelativeTests {
    private func parentAndChild() -> BlockEmulator {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(move(4, 6) + put("i=1,p=1,C=1"))
        emulator.feed(apc("a=T,f=24,s=1,v=1,i=2,p=1,P=1,Q=1,H=2,V=1", pixel))
        return emulator
    }

    @Test func childIsPositionedFromItsParent() {
        let emulator = parentAndChild()
        #expect(emulator.images.count == 2)
        let parent = emulator.origin(of: emulator.images[0])
        let child = emulator.origin(of: emulator.images[1])
        #expect(parent?.row == 3 && parent?.column == 5)
        #expect(child?.row == 4 && child?.column == 7)
    }

    @Test func relativePlacementLeavesTheCursorAlone() {
        let emulator = parentAndChild()
        #expect(emulator.terminal.buffer.x == 5)
        #expect(emulator.terminal.buffer.y == 3)
    }

    @Test func deletingTheParentDeletesTheChild() {
        let emulator = parentAndChild()
        emulator.feed(apc("a=d,d=i,i=1,p=1"))
        #expect(emulator.images.isEmpty)
    }

    @Test func missingParentIsReported() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        var replies: [String] = []
        emulator.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        emulator.feed(apc("a=T,f=24,s=1,v=1,i=2,P=9,Q=9", pixel))
        #expect(replies.contains { $0.contains("ENOPARENT") })
        #expect(emulator.images.isEmpty)
    }

    @Test func cyclesAreRejected() {
        let emulator = parentAndChild()
        var replies: [String] = []
        emulator.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        emulator.feed(apc("a=p,i=1,p=1,P=2,Q=1"))
        #expect(replies.contains { $0.contains("ECYCLE") })
        #expect(emulator.images.count == 2)
    }
}

private func pixelBytes(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return [] }
    let offset = y * image.bytesPerRow + x * 4
    return (0..<4).map { base[offset + $0] }
}

private func solidImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func capture(_ emulator: BlockEmulator) -> Replies {
    let replies = Replies()
    emulator.onResponse = { replies.lines.append(String(decoding: $0, as: UTF8.self)) }
    return replies
}

private final class Replies {
    var lines: [String] = []

    func contain(_ text: String) -> Bool {
        lines.contains { $0.contains(text) }
    }
}

struct KittyQuietTests {
    @Test func quietOneKeepsErrorsAndDropsOK() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(put("i=1,q=1,C=1"))
        #expect(replies.lines.isEmpty)
        emulator.feed(apc("a=p,i=99,q=1"))
        #expect(replies.contain("ENOENT"))
    }

    @Test func quietTwoDropsEverything() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(put("i=1,q=2,C=1") + apc("a=p,i=99,q=2"))
        #expect(replies.lines.isEmpty)
        #expect(emulator.images.count == 1)
    }

    @Test func defaultQuietDeliversBoth() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(put("i=1,C=1") + apc("a=p,i=99"))
        #expect(replies.contain("i=1;OK"))
        #expect(replies.contain("ENOENT"))
    }

    @Test func filterClassifiesReplies() {
        let ok = KittyReply.parse(Array("\u{1B}_Gi=3,I=4;OK\u{1B}\\".utf8)[...])
        #expect(ok?.ok == true && ok?.imageID == 3 && ok?.imageNumber == 4)
        let failure = KittyReply.parse(Array("\u{1B}_Gi=3;EINVAL:bad\u{1B}\\".utf8)[...])
        #expect(failure?.ok == false)
        #expect(KittyReply.parse(Array("\u{1B}[0c".utf8)[...]) == nil)
        let quietOne = KittyReplyFilter(quiet: 1)
        #expect(quietOne.filtered(Array("x".utf8)[...], reply: ok) == nil)
        #expect(quietOne.filtered(Array("x".utf8)[...], reply: failure) != nil)
        #expect(KittyReplyFilter(quiet: 2).filtered(Array("x".utf8)[...], reply: failure) == nil)
    }
}

struct KittyImageNumberTests {
    @Test func failedTransmitDoesNotShiftIDs() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=t,f=24,s=2,v=2,I=5", pixel))
        #expect(replies.contain("I=5;ENODATA:Insufficient image data: 3 < 12"))
        emulator.feed(apc("a=T,f=24,s=1,v=1,I=6,C=1", pixel))
        #expect(replies.contain("i=1,I=6;OK"))
        #expect(emulator.images.map(\.kittyID) == [1])
    }

    @Test func idsFollowTheEngineEvenWhenRepliesAreSilenced() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=24,s=1,v=1,I=7,q=2,C=1", pixel) + apc("a=T,f=24,s=1,v=1,I=7,q=2,C=1", pixel))
        #expect(ids(emulator) == [1, 2])
        emulator.feed(apc("a=d,d=n,I=7"))
        #expect(ids(emulator) == [1])
    }
}

struct KittyAnimationTests {
    private func animated() -> BlockEmulator {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,z=50", pixel))
        return emulator
    }

    @Test func frameTransmissionAppendsAFrame() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,z=50", pixel))
        #expect(replies.contain("i=1,r=2;OK"))
        #expect(!replies.contain("4294967000"))
        #expect(emulator.sources[1]?.frames.count == 2)
        #expect(emulator.sources[1]?.frames[1].gap == 50)
        #expect(emulator.images[0].animation === emulator.sources[1])
    }

    @Test func editingAFrameKeepsTheCount() {
        let emulator = animated()
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,r=2,z=90", pixel))
        #expect(emulator.sources[1]?.frames.count == 2)
        #expect(emulator.sources[1]?.frames[1].gap == 90)
    }

    @Test func frameOfAnUnknownImageIsRejected() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=9", pixel))
        #expect(replies.contain("ENOENT"))
    }

    @Test func frameDataIsComposedOntoTheBase() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let blank = String(repeating: "A", count: 22) + "=="
        emulator.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", blank))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,x=1,y=0,c=1", "/wAA"))
        guard let frame = emulator.sources[1]?.frames[1].image else {
            Issue.record("the frame should exist")
            return
        }
        #expect(pixelBytes(frame, 1, 0) == [255, 0, 0, 255])
        #expect(pixelBytes(frame, 0, 0)[3] == 0)
    }

    @Test func frameLargerThanTheImageIsRejected() {
        let emulator = animated()
        let replies = capture(emulator)
        emulator.feed(apc("a=f,f=24,s=2,v=1,i=1", "AAAAAAAA"))
        #expect(replies.contain("EINVAL:Frame width 2 larger than image width: 1"))
        #expect(emulator.sources[1]?.frames.count == 2)
    }

    @Test func frameOffsetsBeyondTheImageAreClippedNotRejected() {
        let emulator = animated()
        let replies = capture(emulator)
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,x=4,y=4", pixel))
        #expect(!replies.contain("EINVAL"))
        #expect(emulator.sources[1]?.frames.count == 3)
    }
    @Test func controlCommandsSetStateFrameAndGap() {
        let emulator = animated()
        let replies = capture(emulator)
        emulator.feed(apc("a=a,i=1,s=3,v=3"))
        #expect(emulator.sources[1]?.state == 3 && emulator.sources[1]?.loops == 3)
        emulator.feed(apc("a=a,i=1,s=1,c=2"))
        #expect(emulator.sources[1]?.state == 1 && emulator.sources[1]?.current == 1)
        emulator.feed(apc("a=a,i=1,r=2,z=70"))
        #expect(emulator.sources[1]?.frames[1].gap == 70)
        emulator.feed(apc("a=a,i=1,r=2,z=-5"))
        #expect(emulator.sources[1]?.frames[1].gap == 0)
        emulator.feed(apc("a=a,i=1,c=9,r=9,z=10,s=7"))
        #expect(emulator.sources[1]?.current == 1 && emulator.sources[1]?.state == 1)
        #expect(replies.lines.isEmpty)
    }

    @Test func controlOfAMissingImageIsReported() {
        let emulator = animated()
        let replies = capture(emulator)
        emulator.feed(apc("a=a,i=9,s=3"))
        #expect(replies.contain("i=9;ENOENT:Animation command refers to non-existent image with id: 9 and number: 0"))
        emulator.feed(apc("a=a,s=3"))
        #expect(replies.lines.count == 1)
    }

    @Test func idAndNumberTogetherAreRejected() {
        let emulator = animated()
        let replies = capture(emulator)
        emulator.feed(apc("a=a,i=1,I=2,s=3"))
        #expect(replies.contain("i=1,I=2;EINVAL:Must not specify both image id and image number"))
        #expect(emulator.sources[1]?.state == 1)
    }
    @Test func composingFramesCopiesARectangle() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let blank = String(repeating: "A", count: 22) + "=="
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", blank))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,c=1", "/wAA"))
        emulator.feed(apc("a=c,i=1,r=2,c=1,w=1,h=1,x=1,y=1,C=1"))
        guard let root = emulator.sources[1]?.frames[0].image else {
            Issue.record("the root frame should exist")
            return
        }
        #expect(pixelBytes(root, 1, 1) == [255, 0, 0, 255])
        emulator.feed(apc("a=c,i=1,r=2,c=1,w=1,h=1,x=5,y=5"))
        #expect(replies.contain("EINVAL"))
    }

    @Test func frameRepliesCarryTheNumberAndPlacementInKittyOrder() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=24,s=1,v=1,I=3,C=1", pixel))
        emulator.feed(apc("a=f,f=24,s=1,v=1,I=3,p=8", pixel))
        #expect(replies.lines.last?.contains("I=3,p=8,r=2;OK") == true)
        #expect(replies.lines.last?.contains("i=") == false)
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,p=8", pixel))
        #expect(replies.lines.last?.contains("i=1,p=8,r=3;OK") == true)
    }

    @Test func newFramesFollowTheGapRules() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1", pixel))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,z=-1", pixel))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,z=25", pixel))
        #expect(emulator.sources[1]?.frames.map(\.gap) == [0, 40, 0, 25])
    }

    @Test func frameNumberBeyondTheEndAppendsAndBadBaseIsRejected() {
        let emulator = animated()
        let replies = capture(emulator)
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,r=3", pixel))
        #expect(emulator.sources[1]?.frames.count == 3)
        #expect(replies.contain("i=1,r=3;OK"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,c=9", pixel))
        #expect(replies.contain("EINVAL:No frame with number: 9 found"))
        #expect(emulator.sources[1]?.frames.count == 3)
    }

    @Test func composeErrorsUseKittyMessages() {
        let emulator = animated()
        let replies = capture(emulator)
        emulator.feed(apc("a=c,i=1,r=7,c=1"))
        #expect(replies.contain("ENOENT:No source frame number 7 exists in image id: 1"))
        emulator.feed(apc("a=c,i=1,r=1,c=7"))
        #expect(replies.contain("ENOENT:No destination frame number 7 exists in image id: 1"))
        emulator.feed(apc("a=c,i=1,r=1,c=2,w=2"))
        #expect(replies.contain("EINVAL:The destination rectangle is out of bounds"))
        emulator.feed(apc("a=c,i=1,r=1,c=1"))
        #expect(replies.contain("EINVAL:The source and destination rectangles overlap and the src and destination frames are the same"))
    }
    @Test func placementsShareTheAnimationAndKeepTheirCrop() {
        let emulator = animated()
        emulator.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(emulator.images.count == 2)
        #expect(emulator.images.allSatisfy { $0.animation?.frames.count == 2 })
    }

    @Test func playbackFollowsGapsAndLoops() {
        let animation = KittyAnimation(root: solidImage())
        animation.append(solidImage(), gap: 100)
        animation.setGap(100, of: 0)
        let start = Date(timeIntervalSince1970: 1000)
        animation.setState(3, now: start)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.05)) == 0)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.15)) == 1)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.25)) == 0)
        animation.setLoops(2)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.25)) == 1)
        animation.setState(1)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.05)) == animation.current)
    }

    @Test func gaplessFramesAreSkippedAndLoadingModeWaits() {
        let animation = KittyAnimation(root: solidImage())
        animation.setGap(40, of: 0)
        animation.append(solidImage(), gap: 0)
        animation.append(solidImage(), gap: 50)
        let start = Date(timeIntervalSince1970: 1000)
        animation.setState(2, now: start)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.01)) == 0)
        #expect(animation.frameIndex(at: start.addingTimeInterval(0.05)) == 2)
        #expect(animation.frameIndex(at: start.addingTimeInterval(5)) == 2)
        #expect(animation.duration == 90)
    }

    @Test func removingFramesFollowsKittyRules() {
        func make(_ gaps: [Int]) -> KittyAnimation {
            let animation = KittyAnimation(root: solidImage())
            animation.setGap(gaps[0], of: 0)
            for gap in gaps.dropFirst() { animation.append(solidImage(), gap: gap) }
            return animation
        }
        let single = make([5])
        #expect(!single.removeFrame(1))
        let root = make([5, 10, 20])
        #expect(root.removeFrame(1))
        #expect(root.frames.map(\.gap) == [10, 20] && root.duration == 30)
        let middle = make([5, 10, 20])
        middle.removeFrame(2)
        #expect(middle.frames.map(\.gap) == [5, 20] && middle.duration == 25)
        let clamped = make([5, 10, 20])
        clamped.removeFrame(99)
        #expect(clamped.frames.map(\.gap) == [5, 10])
        let zero = make([5, 10, 20])
        zero.removeFrame(0)
        #expect(zero.frames.map(\.gap) == [10, 20])
    }

    @Test func removingFramesAdjustsTheCurrentFrame() {
        func make() -> KittyAnimation {
            let animation = KittyAnimation(root: solidImage())
            animation.append(solidImage(), gap: 10)
            animation.append(solidImage(), gap: 20)
            return animation
        }
        let before = make()
        before.show(2)
        before.removeFrame(2)
        #expect(before.current == 1)
        let last = make()
        last.show(2)
        last.removeFrame(3)
        #expect(last.current == 1)
        let same = make()
        same.show(1)
        same.removeFrame(3)
        #expect(same.current == 1)
        let earlier = make()
        earlier.show(1)
        earlier.removeFrame(2)
        #expect(earlier.current == 0)
        let root = make()
        root.removeFrame(1)
        #expect(root.current == 0)
    }
}

struct KittyDeleteFrameTests {
    private func threeFrames() -> BlockEmulator {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,z=10", pixel))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,z=20", pixel))
        return emulator
    }

    @Test func withoutAnIDNothingHappens() {
        let emulator = threeFrames()
        let replies = capture(emulator)
        emulator.feed(apc("a=d,d=f"))
        emulator.feed(apc("a=d,d=F"))
        #expect(emulator.sources[1]?.frames.count == 3)
        #expect(replies.lines.isEmpty)
    }

    @Test func deletesExactlyOneFrameByIDOrNumber() {
        let emulator = threeFrames()
        emulator.feed(apc("a=d,d=f,i=1,r=2"))
        #expect(emulator.sources[1]?.frames.map(\.gap) == [0, 20])
        let numbered = BlockEmulator(cols: 40, rows: 10)
        numbered.feed(apc("a=T,f=24,s=1,v=1,I=4,C=1", pixel))
        numbered.feed(apc("a=f,f=24,s=1,v=1,I=4,z=10", pixel))
        numbered.feed(apc("a=f,f=24,s=1,v=1,I=4,z=20", pixel))
        numbered.feed(apc("a=d,d=F,I=4,r=3"))
        #expect(numbered.sources[1]?.frames.map(\.gap) == [0, 10])
    }

    @Test func frameOneRemovalPromotesTheNextFrame() {
        let emulator = threeFrames()
        emulator.feed(apc("a=d,d=f,i=1"))
        #expect(emulator.sources[1]?.frames.map(\.gap) == [10, 20])
        emulator.feed(apc("a=d,d=f,i=1,r=1"))
        #expect(emulator.sources[1]?.frames.map(\.gap) == [20])
    }

    @Test func oversizedFrameNumberRemovesTheLastFrame() {
        let emulator = threeFrames()
        emulator.feed(apc("a=d,d=f,i=1,r=50"))
        #expect(emulator.sources[1]?.frames.map(\.gap) == [0, 10])
    }

    @Test func lowercaseKeepsASingleFrameImageAndUppercaseRemovesIt() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=d,d=f,i=1"))
        #expect(emulator.sources[1] != nil && emulator.images.count == 1)
        emulator.feed(apc("a=d,d=F,i=1"))
        #expect(emulator.sources[1] == nil)
        #expect(emulator.images.isEmpty)
    }

    @Test func uppercaseOnAMultiFrameImageOnlyRemovesAFrame() {
        let emulator = threeFrames()
        emulator.feed(apc("a=d,d=F,i=1,r=2"))
        #expect(emulator.sources[1]?.frames.count == 2)
        #expect(emulator.images.count == 1)
    }

    @Test func idAndNumberTogetherAreRejected() {
        let emulator = threeFrames()
        let replies = capture(emulator)
        emulator.feed(apc("a=d,d=f,i=1,I=2"))
        #expect(replies.contain("EINVAL:Must not specify both image id and image number"))
        #expect(emulator.sources[1]?.frames.count == 3)
    }

    @Test func removingTheShownFrameOfARunningAnimationKeepsItPlayable() {
        let emulator = threeFrames()
        emulator.feed(apc("a=a,i=1,s=3,c=3"))
        emulator.feed(apc("a=d,d=f,i=1,r=3"))
        #expect(emulator.sources[1]?.frames.count == 2)
        #expect(emulator.sources[1]?.duration == 10)
        #expect((emulator.sources[1]?.frameIndex(at: Date()) ?? 9) < 2)
    }
}

struct KittyPlaceholderTests {
    private let mark0 = "\u{0305}"
    private let mark1 = "\u{030D}"

    private func drawn() -> BlockEmulator {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=2,q=2", pixel))
        let cell = "\u{10EEEE}"
        emulator.feed(text("\u{1B}[38;5;42m\(cell)\(mark0)\(mark0)\(cell)\(mark0)\(mark1)\u{1B}[39m\r\n"))
        emulator.feed(text("\u{1B}[38;5;42m\(cell)\(mark1)\(mark0)\(cell)\(mark1)\(mark1)\u{1B}[39m"))
        return emulator
    }

    private func tiles(_ emulator: BlockEmulator) -> [InlineImage] {
        emulator.renderSegments().flatMap { segment -> [InlineImage] in
            switch segment {
            case .image(let image): return [image]
            case .stack(let stack): return stack.images
            case .text: return []
            }
        }
    }

    @Test func virtualPlacementIsRegisteredWithoutDrawing() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=2,q=2", pixel))
        #expect(emulator.images.isEmpty)
        #expect(emulator.virtualPlacements.count == 1)
        #expect(emulator.virtualPlacements[0].columnSpan == 2 && emulator.virtualPlacements[0].rowSpan == 2)
        #expect(emulator.terminal.buffer.x == 0 && emulator.terminal.buffer.y == 0)
    }

    @Test func virtualPlacementFromAnEarlierTransmit() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(5))
        emulator.feed(apc("a=p,U=1,i=5,p=3,c=4,r=1"))
        #expect(emulator.virtualPlacements.map(\.placementID) == [3])
        emulator.feed(apc("a=d,d=i,i=5"))
        #expect(emulator.virtualPlacements.isEmpty)
    }

    @Test func virtualPlacementOfUnknownImageIsRejected() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=p,U=1,i=8,c=1,r=1"))
        #expect(replies.contain("ENOENT"))
        #expect(emulator.virtualPlacements.isEmpty)
    }

    @Test func placeholderCellsBecomeImageTiles() {
        let emulator = drawn()
        let found = tiles(emulator)
        #expect(found.count == 2)
        #expect(found.map(\.anchor) == [0, 1])
        #expect(found.allSatisfy { $0.columnSpan == 2 && $0.rowSpan == 1 && $0.tile?.columns == 2 && $0.tile?.rows == 2 })
        #expect(found.map { $0.tile?.partRow } == [0, 1])
        #expect(found.allSatisfy { $0.tile?.partColumn == 0 })
    }

    @Test func placeholderGlyphsAreNotShownAsText() {
        let emulator = drawn()
        #expect(!emulator.renderSegments().plainText.unicodeScalars.contains { $0.value == 0x10EEEE })
    }

    @Test func placeholdersWithoutAPlacementStayText() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(text("\u{1B}[38;5;9m\u{10EEEE}\u{0305}\u{0305}"))
        #expect(tiles(emulator).isEmpty)
    }

    @Test func relativePlacementCanFollowAVirtualParent() {
        let emulator = drawn()
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=24,s=1,v=1,i=7,p=1,P=42,Q=0,H=1,V=1", pixel))
        #expect(!replies.contain("ENOPARENT"))
        #expect(emulator.images.count == 1)
        let origin = emulator.origin(of: emulator.images[0])
        #expect(origin?.row == 1 && origin?.column == 1)
    }

    @Test func deletingTheVirtualParentDeletesTheChild() {
        let emulator = drawn()
        emulator.feed(apc("a=T,f=24,s=1,v=1,i=7,p=1,P=42,Q=0", pixel))
        emulator.feed(apc("a=d,d=i,i=42"))
        #expect(emulator.images.isEmpty)
    }
}

struct KittyStackTextTests {
    @Test func stackLinesKeepTheirAttributesWhenJoined() {
        var first = AttributedString("ab")
        first.link = URL(string: "https://example.com")
        let stack = ImageStack(start: 0, rows: 2, lines: [first, AttributedString("cd")], images: [])
        #expect(String(stack.text.characters) == "ab\ncd")
        #expect(stack.text.runs.contains { $0.link != nil })
    }

    @Test func placeholderMaskKeepsAttributes() {
        var line = AttributedString("\u{10EEEE}\u{0305}x")
        line.link = URL(string: "https://example.com")
        let masked = line.maskingPlaceholders()
        #expect(String(masked.characters) == " x")
        #expect(masked.runs.allSatisfy { $0.link != nil })
    }
}

@_silgen_name("shm_open")
private func openSharedMemory(_ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32

private func base64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

private func scratchFile(_ data: Data, protocolName: Bool) -> URL {
    let stem = protocolName ? "tty-graphics-protocol-" : "turm-kitty-"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem)\(UUID().uuidString)")
    try? data.write(to: url)
    return url
}

struct KittyMediumTests {
    private let png = Data(base64Encoded: pngPixel)!

    @Test func mediumsIgnoreTheChunkFlag() {
        #expect(!KittyGraphicsScanner.parse(Array("a=T,t=f,m=1".utf8)[...]).more)
        #expect(KittyGraphicsScanner.parse(Array("a=T,t=d,m=1".utf8)[...]).more)
    }

    @Test func pngFileIsReadAndKept() {
        let url = scratchFile(png, protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=100,t=f,i=1,C=1", base64(url.path)))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].pixelSize == CGSize(width: 1, height: 1))
        #expect(emulator.sources[1] != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func temporaryFileIsRemovedAfterReading() {
        let url = scratchFile(Data(count: 3), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=24,s=1,v=1,t=t,i=2,C=1", base64(url.path)))
        #expect(emulator.images.count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func temporaryFileWithoutTheProtocolNameIsReadButKept() {
        let url = scratchFile(Data(count: 3), protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=24,s=1,v=1,t=t,i=2,C=1", base64(url.path)))
        #expect(emulator.images.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func transmitOnlyFileStillCapturesTheRootFrame() {
        let url = scratchFile(png, protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=t,f=100,t=f,i=3", base64(url.path)))
        #expect(emulator.images.isEmpty)
        #expect(emulator.sources[3]?.frames.count == 1)
        emulator.feed(apc("a=p,i=3,C=1"))
        #expect(emulator.images.map(\.kittyID) == [3])
    }

    @Test func transmitOnlyTemporaryFileIsReadOnce() {
        let url = scratchFile(Data(count: 3), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=t,f=24,s=1,v=1,t=t,i=4", base64(url.path)))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(emulator.sources[4] != nil)
        emulator.feed(apc("a=p,i=4,C=1"))
        #expect(emulator.images.count == 1)
    }

    @Test func frameDataCanComeFromAFile() {
        let url = scratchFile(Data(count: 3), protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,t=f,i=1", base64(url.path)))
        #expect(emulator.sources[1]?.frames.count == 2)
    }

    @Test func croppedTemporaryFileIsReadOnce() {
        let url = scratchFile(Data(count: 12), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=24,s=2,v=2,t=t,x=0,y=0,w=1,h=2,i=4,C=1", base64(url.path)))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].pixelSize == CGSize(width: 1, height: 2))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: sharedMemoryWorks(), "POSIX shared memory cannot be created, mapped and re-opened read-only here"))
    func sharedMemoryIsReadAndUnlinked() {
        let name = "/turmk\(UUID().uuidString.prefix(8))"
        defer { _ = name.withCString { shm_unlink($0) } }
        #expect(createSharedMemory(name, size: 3))
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=24,s=1,v=1,t=s,i=5,C=1", base64(name)))
        #expect(emulator.images.count == 1)
        #expect(emulator.sources[5] != nil)
        #expect(name.withCString { openSharedMemory($0, O_RDONLY, 0) } < 0)
    }
}

private func createSharedMemory(_ name: String, size: Int) -> Bool {
    let descriptor = name.withCString { openSharedMemory($0, O_CREAT | O_RDWR | O_EXCL, 0o600) }
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

private func sharedMemoryWorks() -> Bool {
    let name = "/turmk\(UUID().uuidString.prefix(8))"
    defer { _ = name.withCString { shm_unlink($0) } }
    guard createSharedMemory(name, size: 3) else { return false }
    let descriptor = name.withCString { openSharedMemory($0, O_RDONLY, 0) }
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

struct KittyInternalIDTests {
    @Test func croppedTransmitWithoutAnIDGetsAnInternalOne() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=24,s=2,v=2,x=0,y=0,w=1,h=2,C=1", "AAAAAAAAAAAAAAAA"))
        #expect(replies.lines.isEmpty)
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].pixelSize == CGSize(width: 1, height: 2))
        #expect(emulator.images[0].placementID == nil)
        guard let id = emulator.images[0].kittyID else {
            Issue.record("the placement should carry an internal id")
            return
        }
        #expect(emulator.sources[id]?.frames.count == 1)
        #expect(emulator.images[0].animation === emulator.sources[id])
        emulator.feed(apc("a=d"))
        #expect(emulator.images.isEmpty)
    }
}

struct KittyPlaceholderStyleTests {
    private func tiles(_ emulator: BlockEmulator) -> [InlineImage] {
        emulator.renderSegments().flatMap { segment -> [InlineImage] in
            switch segment {
            case .image(let image): return [image]
            case .stack(let stack): return stack.images
            case .text: return []
            }
        }
    }

    @Test func tilesCarryTheCellBackgroundAndTheVirtualZIndex() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,z=-3,q=2", pixel))
        emulator.feed(text("\u{1B}[38;5;42m\u{1B}[48;2;10;20;30m\u{10EEEE}\u{0305}\u{0305}\u{1B}[0m"))
        let found = tiles(emulator)
        #expect(found.count == 1)
        #expect(found[0].zIndex == -3)
        let color = found[0].background?.usingColorSpace(.sRGB)
        #expect(abs((color?.redComponent ?? 0) - 10.0 / 255) < 0.01)
        #expect(abs((color?.blueComponent ?? 0) - 30.0 / 255) < 0.01)
    }

    @Test func cellsWithDifferentBackgroundsAreNotMerged() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=2,r=1,q=2", pixel))
        emulator.feed(text("\u{1B}[38;5;42m\u{1B}[48;5;1m\u{10EEEE}\u{0305}\u{0305}\u{1B}[48;5;2m\u{10EEEE}\u{0305}\u{030D}"))
        #expect(tiles(emulator).count == 2)
    }

    @Test func plainCellsHaveNoBackground() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        emulator.feed(text("\u{1B}[38;5;42m\u{10EEEE}\u{0305}\u{0305}"))
        #expect(tiles(emulator).first?.background == nil)
    }

    @Test func negativeZTileSharesAStackWithTheText() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,z=-3,q=2", pixel))
        emulator.feed(text("\u{1B}[38;5;42m\u{10EEEE}\u{0305}\u{0305}\u{1B}[0mx"))
        let result = emulator.renderSegments()
        guard case .stack(let stack) = result.first else {
            Issue.record("text next to a tile should form a stack")
            return
        }
        #expect(stack.images.first?.zIndex == -3)
        #expect(String(stack.lines[0].characters).contains("x"))
    }
}

private let zlibTwelveZeros = "eJxjYEAAAAAMAAE="

struct KittyErrorTests {
    private func reply(_ keys: String, _ payload: String = "AAAA") -> String {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc(keys, payload))
        return replies.lines.joined()
    }

    @Test func formatAndDimensionErrors() {
        #expect(reply("a=t,f=99,s=1,v=1,i=1").contains("i=1;EINVAL:Unknown image format: 99"))
        #expect(reply("a=t,f=24,s=0,v=0,i=1").contains("EINVAL:Zero width/height not allowed"))
        #expect(reply("a=t,f=24,s=10001,v=1,i=1").contains("EINVAL:Image too large, width or height greater than 10000"))
    }

    @Test func dataSizeErrors() {
        #expect(reply("a=t,f=24,s=2,v=2,i=1").contains("i=1;ENODATA:Insufficient image data: 3 < 12"))
        let long = Data(count: 14).base64EncodedString()
        #expect(reply("a=t,f=24,s=1,v=1,i=1", long).contains("EFBIG:Too much data"))
    }

    @Test func mediumAndCompressionErrors() {
        #expect(reply("a=t,f=24,s=1,v=1,t=x,i=1").contains("EINVAL:Unknown transmission type: x"))
        #expect(reply("a=t,f=24,s=1,v=1,o=y,i=1").contains("EINVAL:Unknown image compression: y"))
    }

    @Test func zlibFailuresUseKittyMessages() {
        let garbage = Data([1, 2, 3, 4]).base64EncodedString()
        #expect(reply("a=t,f=24,s=2,v=2,o=z,i=1", garbage).contains("EINVAL:Failed to inflate image data with error: Z_DATA_ERROR"))
        let three = "eJxjYGAAAAADAAE="
        #expect(reply("a=t,f=24,s=2,v=2,o=z,i=1", three).contains("Image data size post inflation does not match expected size"))
        let tooBig = "eJxjYEAAAAAMAAE="
        #expect(reply("a=t,f=24,s=1,v=1,o=z,i=1", tooBig).contains("Failed to inflate image data with error: Z_BUF_ERROR"))
    }

    @Test func compressedDataIsInflatedBeforeTheEngineSeesIt() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=24,s=2,v=2,o=z,i=1,C=1", zlibTwelveZeros))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].pixelSize == CGSize(width: 2, height: 2))
        #expect(replies.contain("i=1;OK"))
    }

    @Test func compressedChunksAreAssembledFirst() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let text = zlibTwelveZeros
        let split = text.index(text.startIndex, offsetBy: 8)
        emulator.feed(apc("a=T,f=24,s=2,v=2,o=z,i=1,m=1,C=1", String(text[..<split])))
        emulator.feed(apc("m=0", String(text[split...])))
        #expect(emulator.images.count == 1)
    }

    @Test func fileFailuresAreGeneric() {
        #expect(reply("a=t,f=24,s=1,v=1,t=f,i=1", base64("/no/such/kitty/file")).contains("EBADF:Failed to read image file"))
        #expect(reply("a=t,f=24,s=1,v=1,t=s,i=1", base64("no-slash")).contains("EBADF:Failed to read image file"))
        let long = Data(repeating: 0x61, count: 2049).base64EncodedString()
        #expect(reply("a=t,f=24,s=1,v=1,t=f,i=1", long).contains("EINVAL:Filename too long"))
    }

    @Test func shortFilesAreGenericNotEnodata() {
        let url = scratchFile(Data(count: 3), protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = reply("a=t,f=24,s=2,v=2,t=f,i=1", base64(url.path))
        #expect(text.contains("EBADF:Failed to read image file"))
        #expect(!text.contains("ENODATA"))
    }

    @Test func failedTemporaryFilesAreStillRemoved() {
        let url = scratchFile(Data(count: 3), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = reply("a=t,f=24,s=2,v=2,t=t,i=1", base64(url.path))
        #expect(text.contains("EBADF"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func badPNGDataIsReportedAsAPNGError() {
        #expect(reply("a=t,f=100,i=1", Data([1, 2, 3, 4, 5, 6, 7, 8]).base64EncodedString()).contains("EBADPNG:Not a PNG file"))
    }

    @Test func failedRetransmitDropsTheOldImage() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=t,f=24,s=2,v=2,i=1", pixel))
        #expect(emulator.images.isEmpty && emulator.sources[1] == nil)
        emulator.feed(apc("a=p,i=1"))
        #expect(replies.contain("ENOENT:Put command refers to image with id: 1 that could not load its data"))
    }

    @Test func remainingChunksOfARejectedTransmitAreSwallowed() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=t,f=24,s=1,v=1,i=1,m=1", Data(count: 30).base64EncodedString()))
        emulator.feed(apc("m=0", "AAAA"))
        #expect(replies.lines.count == 1)
        #expect(replies.contain("EFBIG"))
    }

    @Test func putOfAnUnknownImageUsesKittysMessage() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=p,i=9"))
        #expect(replies.contain("i=9;ENOENT:Put command refers to non-existent image with id: 9 and number: 0"))
    }

    @Test func engineErrorsLoseTheSpaceAfterTheColon() {
        let reply = KittyReply(control: "i=1", message: "EINVAL: bad thing")
        #expect(reply.normalized(fileMedium: false, png: false).message == "EINVAL:bad thing")
        #expect(reply.normalized(fileMedium: false, png: false) != reply)
        let bad = KittyReply(control: "i=1", message: "EINVAL: bad path")
        #expect(bad.normalized(fileMedium: true, png: false).message == "EBADF:Failed to read image file")
    }
}

struct KittyStorageTests {
    private let word = "AAAAAA=="

    private func transmitWord(_ id: Int, _ extra: String = "") -> [UInt8] {
        apc("a=t,f=32,s=1,v=1,i=\(id)\(extra)", word)
    }

    @Test func unreferencedImagesAreEvictedWhenTheLimitIsExceeded() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.storageLimit = 10
        emulator.feed(transmitWord(1) + transmitWord(2))
        #expect(emulator.usedStorage == 8)
        emulator.feed(transmitWord(3))
        #expect(emulator.sources.keys.sorted() == [3])
        #expect(!emulator.engineHasImage(1))
    }

    @Test func referencedImagesAreEvictedOldestFirst() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.storageLimit = 5
        emulator.feed(put("i=1,C=1"))
        emulator.feed(transmitWord(2))
        #expect(emulator.sources.keys.sorted() == [2])
        #expect(emulator.images.isEmpty)
    }

    @Test func transientImagesGoFirst() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.storageLimit = 5
        emulator.feed(put("i=1,C=1"))
        emulator.feed(put("i=2,N=1,C=1"))
        #expect(emulator.sources.keys.sorted() == [1])
        #expect(emulator.images.map(\.kittyID) == [1])
    }

    @Test func imagesUnderTheLimitAreKept() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmitWord(1) + transmitWord(2))
        #expect(emulator.sources.keys.sorted() == [1, 2])
    }

    @Test func frameCacheIsBoundedAtFiveTimesTheLimit() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        let sixteen = String(repeating: "A", count: 22) + "=="
        emulator.storageLimit = 16
        emulator.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", sixteen))
        for _ in 0..<4 { emulator.feed(apc("a=f,f=32,s=2,v=2,i=1", sixteen)) }
        #expect(emulator.sources[1]?.frames.count == 5)
        #expect(emulator.cacheSize == 80)
        emulator.feed(apc("a=f,f=32,s=2,v=2,i=1", sixteen))
        #expect(replies.contain("ENOSPC:Cache size exceeded cannot add new frames"))
        #expect(emulator.sources[1]?.frames.count == 5)
    }
}

struct KittyEngineReleaseTests {
    @Test func uppercaseDeleteFreesTheEngineCopy() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(transmit(1))
        #expect(emulator.engineHasImage(1))
        emulator.feed(apc("a=d,d=I,i=1"))
        #expect(emulator.sources[1] == nil)
        #expect(!emulator.engineHasImage(1))
        emulator.feed(apc("a=p,i=1"))
        #expect(replies.contain("ENOENT"))
        #expect(emulator.images.isEmpty)
    }

    @Test func lowercaseDeleteKeepsTheEngineCopy() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1) + apc("a=p,i=1,C=1") + apc("a=d,d=i,i=1"))
        #expect(emulator.engineHasImage(1))
        emulator.feed(apc("a=p,i=1,C=1"))
        #expect(emulator.images.count == 1)
    }

    @Test func freeingOneImageKeepsTheOthersInTheEngine() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1) + transmit(2) + apc("a=d,d=I,i=1"))
        #expect(!emulator.engineHasImage(1))
        #expect(emulator.engineHasImage(2))
    }

    @Test func uppercaseDeleteAllFreesOnlyImagesWhosePlacementsWentAway() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1) + transmit(2) + apc("a=p,i=1,C=1") + apc("a=d,d=A"))
        #expect(emulator.sources[1] == nil && emulator.sources[2] != nil)
        #expect(!emulator.engineHasImage(1) && emulator.engineHasImage(2))
    }

    @Test func removingTheWholeImageWithDeleteFrameFreesIt() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=d,d=F,i=1"))
        #expect(!emulator.engineHasImage(1))
    }

    @Test func enteringAndLeavingTheAlternateScreenKeepsImages() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1))
        emulator.feed(text("\u{1B}[?1049h\u{1B}[?1049l"))
        #expect(emulator.engineHasImage(1))
    }

    @Test func evictedImagesAreFreedInTheEngine() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.storageLimit = 5
        emulator.feed(apc("a=t,f=32,s=1,v=1,i=1", "AAAAAA==") + apc("a=t,f=32,s=1,v=1,i=2", "AAAAAA=="))
        #expect(!emulator.engineHasImage(1))
        #expect(emulator.engineHasImage(2) == (emulator.sources[2] != nil))
    }
}

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var value: UInt32 = 0xFFFFFFFF
    for byte in bytes {
        value ^= UInt32(byte)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1 }
    }
    return ~value
}

private func pngChunk(_ name: String, _ body: [UInt8], badChecksum: Bool = false) -> [UInt8] {
    func big(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    let checked = Array(name.utf8) + body
    return big(UInt32(body.count)) + checked + big(crc32(checked) ^ (badChecksum ? 1 : 0))
}

private func header(width: UInt32, height: UInt32, depth: UInt8 = 8, color: UInt8 = 6, interlace: UInt8 = 0) -> [UInt8] {
    func big(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    return big(width) + big(height) + [depth, color, 0, 0, interlace]
}

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

struct KittyPNGErrorTests {
    private func reply(_ bytes: [UInt8]) -> String {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=t,f=100,i=1", Data(bytes).base64EncodedString()))
        return replies.lines.joined()
    }

    @Test func signatureProblemsUseLibpngMessages() {
        #expect(reply([0, 1, 2, 3, 4, 5, 6, 7, 8]).contains("EBADPNG:Not a PNG file"))
        var corrupted = pngSignature
        corrupted[4] = 0x0A
        #expect(reply(corrupted + [0]).contains("EBADPNG:PNG file corrupted by ASCII conversion"))
    }

    @Test func truncationIsReportedLikeKittysReadCallback() {
        let text = "EBADPNG:PNG data is truncated: not enough bytes to satisfy read request"
        #expect(reply([0x89, 0x50]).contains(text))
        #expect(reply(pngSignature).contains(text))
        let idat = pngSignature + pngChunk("IHDR", header(width: 1, height: 1)) + [0, 0, 0, 100] + Array("IDAT".utf8) + [1, 2]
        #expect(reply(idat).contains(text))
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
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,f=100,i=1,C=1", pngPixel))
        #expect(emulator.images.count == 1)
    }
}

private let zlibFixtures: [String: String] = [
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

struct KittyZlibTests {
    private func reply(_ name: String, width: Int = 5) -> String {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=32,s=\(width),v=2,o=z,i=1,C=1", zlibFixtures[name]!))
        return replies.lines.joined() + "|images=\(emulator.images.count)"
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

    @Test func inflaterHandlesStoredFixedAndDynamicBlocks() {
        let stored = Data([0x78, 0x01, 0x01, 0x03, 0x00, 0xFC, 0xFF, 1, 2, 3, 0x00, 0x0D, 0x00, 0x07])
        if case .success(let bytes) = KittyInflate.inflate(stored, capacity: 3) {
            #expect([UInt8](bytes) == [1, 2, 3])
        } else {
            Issue.record("stored block should inflate")
        }
        if case .success(let bytes) = KittyInflate.inflate(Data(base64Encoded: zlibFixtures["good"]!)!, capacity: 40) {
            #expect([UInt8](bytes) == Array(0..<40))
        } else {
            Issue.record("fixed block stream should inflate")
        }
    }
}

struct KittyBufferTests {
    private func enterAlternate(_ emulator: BlockEmulator) {
        emulator.feed(text("\u{1B}[?1049h"))
    }

    private func leaveAlternate(_ emulator: BlockEmulator) {
        emulator.feed(text("\u{1B}[?1049l"))
    }

    @Test func eachScreenBufferHasItsOwnImageTable() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1))
        enterAlternate(emulator)
        emulator.feed(transmit(7))
        #expect(emulator.altStore.sources[7] != nil && emulator.normalStore.sources[7] == nil)
        #expect(emulator.sources.keys.sorted() == [7])
        leaveAlternate(emulator)
        #expect(emulator.sources.keys.sorted() == [1])
        #expect(emulator.engineHasImage(1))
    }

    @Test func enteringTheAlternateScreenClearsItsImages() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        enterAlternate(emulator)
        emulator.feed(transmit(7))
        leaveAlternate(emulator)
        #expect(emulator.altStore.sources[7] != nil)
        enterAlternate(emulator)
        #expect(emulator.altStore.sources.isEmpty)
    }

    @Test func quotasAreSeparatePerBuffer() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.normalStore.storageLimit = 5
        enterAlternate(emulator)
        emulator.feed(apc("a=t,f=32,s=1,v=1,i=1", "AAAAAA==") + apc("a=t,f=32,s=1,v=1,i=2", "AAAAAA=="))
        #expect(emulator.altStore.sources.count == 2)
        leaveAlternate(emulator)
        emulator.feed(apc("a=t,f=32,s=1,v=1,i=3", "AAAAAA==") + apc("a=t,f=32,s=1,v=1,i=4", "AAAAAA=="))
        #expect(emulator.normalStore.sources.keys.sorted() == [4])
    }

    @Test func alternateScreenPlacementsStayOutOfTheBlockOutput() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        enterAlternate(emulator)
        emulator.feed(put("i=1,C=1"))
        #expect(emulator.altStore.images.count == 1)
        leaveAlternate(emulator)
        #expect(emulator.normalStore.images.isEmpty)
        #expect(emulator.renderSegments().count == 0)
    }
}

struct KittyClearTests {
    private func scrolledOff() -> BlockEmulator {
        let emulator = BlockEmulator(cols: 40, rows: 5)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(text(String(repeating: "\n", count: 12)))
        return emulator
    }

    @Test func clearScreenKeepsImagesReferencedFromScrollback() {
        let emulator = scrolledOff()
        emulator.feed(text("\u{1B}[2J"))
        #expect(emulator.sources[1] != nil)
        #expect(emulator.images.count == 1)
        #expect(emulator.engineHasImage(1))
        emulator.feed(apc("a=p,i=1,C=1"))
        #expect(emulator.images.count == 2)
    }

    @Test func clearScreenFreesImagesWithNoPlacementsLeft() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(put("i=1,C=1") + transmit(2))
        emulator.feed(text("\u{1B}[2J"))
        #expect(emulator.sources.isEmpty)
        #expect(!emulator.engineHasImage(1) && !emulator.engineHasImage(2))
        emulator.feed(apc("a=p,i=1"))
        #expect(replies.contain("ENOENT"))
    }

    @Test func eraseScrollbackFreesEverythingUnreferenced() {
        let emulator = scrolledOff()
        emulator.feed(text("\u{1B}[3J"))
        #expect(emulator.sources.isEmpty && emulator.images.isEmpty)
        #expect(!emulator.engineHasImage(1))
    }

    @Test func virtualPlacementsKeepTheirImageAcrossClears() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=T,U=1,f=24,s=1,v=1,i=42,c=1,r=1,q=2", pixel))
        emulator.feed(text("\u{1B}[2J\u{1B}[3J"))
        #expect(emulator.sources[42] != nil)
        #expect(emulator.engineHasImage(42))
    }

    @Test func hardResetFreesTheAlternateBufferAndVisiblePlacements() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(text("\u{1B}[?1049h"))
        emulator.feed(transmit(9))
        emulator.feed(text("\u{1B}c"))
        #expect(emulator.normalStore.sources.isEmpty && emulator.altStore.sources.isEmpty)
    }
}

struct KittyByteAccountingTests {
    @Test func upToTenExtraRawBytesAreTrimmed() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=24,s=1,v=1,i=1,C=1", Data(count: 13).base64EncodedString()))
        #expect(replies.contain("i=1;OK"))
        #expect(emulator.images.count == 1)
    }

    @Test func rgbFramesCountThreeBytesPerPixel() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let twelve = Data(count: 12).base64EncodedString()
        emulator.feed(apc("a=T,f=24,s=2,v=2,i=1,C=1", twelve))
        emulator.feed(apc("a=f,f=24,s=2,v=2,i=1", twelve))
        #expect(emulator.usedStorage == 12)
        #expect(emulator.cacheSize == 24)
    }

    @Test func rgbaFramesCountFourBytesPerPixel() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let sixteen = Data(count: 16).base64EncodedString()
        emulator.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", sixteen))
        emulator.feed(apc("a=f,f=32,s=2,v=2,i=1", sixteen))
        #expect(emulator.usedStorage == 16)
        #expect(emulator.cacheSize == 32)
    }
}

private func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func zlibStored(_ raw: [UInt8], checksum: UInt32? = nil) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01]
    var offset = 0
    repeat {
        let count = min(65535, raw.count - offset)
        let final: UInt8 = offset + count >= raw.count ? 1 : 0
        out += [final, UInt8(count & 255), UInt8(count >> 8), UInt8(~count & 255), UInt8((~count >> 8) & 255)]
        out += raw[offset..<(offset + count)]
        offset += count
    } while offset < raw.count
    return out + bigEndian(checksum ?? KittyInflate.adler32(raw))
}

private func png(rows: [[UInt8]], stream: [UInt8]? = nil, interlace: UInt8 = 0, color: UInt8 = 6, width: UInt32 = 2, height: UInt32 = 2, badChecksum: Bool = false) -> [UInt8] {
    let raw = rows.flatMap { $0 }
    return pngSignature + pngChunk("IHDR", header(width: width, height: height, color: color, interlace: interlace))
        + pngChunk("IDAT", stream ?? zlibStored(raw), badChecksum: badChecksum) + pngChunk("IEND", [])
}

private func rgbaRows(_ filters: [UInt8]) -> [[UInt8]] {
    filters.map { [$0] + [UInt8](repeating: 0, count: 8) }
}

struct KittyPNGDataTests {
    private func check(_ bytes: [UInt8]) -> KittyFailure? {
        KittyPNGCheck.validate(bytes, maxDimension: 10_000)
    }

    @Test func wellFormedImageDataPasses() {
        #expect(check(png(rows: rgbaRows([0, 4]))) == nil)
    }

    @Test func badFilterBytesAreRejected() {
        #expect(check(png(rows: rgbaRows([0, 9])))?.message == "bad adaptive filter value")
        #expect(check(png(rows: rgbaRows([5, 0])))?.code == "EBADPNG")
    }

    @Test func missingRowsAreNotEnoughImageData() {
        #expect(check(png(rows: rgbaRows([0])))?.message == "Not enough image data")
    }

    @Test func extraDecodedDataIsToleratedLikeLibpng() {
        #expect(check(png(rows: rgbaRows([0, 0, 0]))) == nil)
    }

    @Test func zlibDamageIsReportedWithZlibsText() {
        let rows = rgbaRows([0, 0])
        let raw = rows.flatMap { $0 }
        #expect(check(png(rows: rows, stream: zlibStored(raw, checksum: 1)))?.message == "IDAT: incorrect data check")
        var badBlock = zlibStored(raw)
        badBlock[2] = 7
        #expect(check(png(rows: rows, stream: badBlock))?.message == "IDAT: invalid block type")
        var badHeader = zlibStored(raw)
        badHeader[0] = 0
        badHeader[1] = 0
        #expect(check(png(rows: rows, stream: badHeader))?.message == "IDAT: unknown compression method")
        var badCheck = zlibStored(raw)
        badCheck[1] = 0x02
        #expect(check(png(rows: rows, stream: badCheck))?.message == "IDAT: incorrect header check")
        var storedLength = zlibStored(raw)
        storedLength[5] ^= 0xFF
        #expect(check(png(rows: rows, stream: storedLength))?.message == "IDAT: invalid stored block lengths")
    }

    @Test func truncatedStreamsFollowedByAnotherChunkAreNotEnoughData() {
        let rows = rgbaRows([0, 0])
        let stream = zlibStored(rows.flatMap { $0 })
        #expect(check(png(rows: rows, stream: Array(stream.dropLast(12))))?.message == "Not enough image data")
    }

    @Test func missingChecksumAfterAllRowsIsNotAnError() {
        let rows = rgbaRows([0, 0])
        #expect(check(png(rows: rows, stream: Array(zlibStored(rows.flatMap { $0 }).dropLast(4)))) == nil)
    }

    @Test func idatChunkCRCCorruptionIsACRCError() {
        #expect(check(png(rows: rgbaRows([0, 0]), badChecksum: true))?.message == "IDAT: CRC error")
    }

    @Test func zlibChecksumCorruptionIsNotACRCError() {
        let rows = rgbaRows([0, 0])
        let raw = rows.flatMap { $0 }
        #expect(check(png(rows: rows, stream: zlibStored(raw, checksum: 7)))?.message == "IDAT: incorrect data check")
    }

    @Test func rowSizesFollowBitDepthAndAdam7() {
        #expect(KittyPNGCheck.rowLengths(width: 3, height: 2, depth: 16, color: 2, interlaced: false) == [19, 19])
        #expect(KittyPNGCheck.rowLengths(width: 3, height: 3, depth: 8, color: 0, interlaced: true) == [2, 2, 3, 2, 2, 4])
        #expect(KittyPNGCheck.rowLengths(width: 9, height: 1, depth: 1, color: 0, interlaced: false) == [3])
        let interlaced = png(rows: [[UInt8](repeating: 0, count: 15)], interlace: 1, color: 0, width: 3, height: 3)
        #expect(check(interlaced) == nil)
        let short = png(rows: [[UInt8](repeating: 0, count: 14)], interlace: 1, color: 0, width: 3, height: 3)
        #expect(check(short)?.message == "Not enough image data")
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

struct KittyFastInflateTests {
    private func stream(_ raw: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: raw.count + raw.count / 8 + 4096)
        let size = compression_encode_buffer(&output, output.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + output[0..<size] + bigEndian(KittyInflate.adler32(raw))
    }

    @Test func fastPathAndPuffPortAgreeOnALargeStream() throws {
        var generator = SplitMix64(state: 0x1234_5678_9ABC_DEF0)
        let raw = (0..<4_000_000).map { _ in UInt8(truncatingIfNeeded: generator.next() & 0x0F) }
        let packed = stream(raw)
        try #require(packed.count - 6 > 256 * 1024, "the fixture must compress to more than the 256 KB fast-path threshold")
        try #require(packed[2] & 0x06 != 0, "the first deflate block must not be a stored block")
        #expect(KittyDeflate.prefersFast(packed[2...]))
        #expect(KittyDeflate.fast(packed[2...], capacity: raw.count) == raw)
        #expect(KittyDeflate.trailerMatches(packed, raw))
        let slow = KittyDeflate.inflate(packed, from: 2, capacity: raw.count)
        #expect(slow.failure == nil && slow.output == raw)
        if case .success(let data) = KittyInflate.inflate(Data(packed), capacity: raw.count) {
            #expect([UInt8](data) == raw)
        } else {
            Issue.record("a valid stream should inflate")
        }
    }

    @Test func fastPathRefusesStreamsLargerThanExpected() {
        let raw = [UInt8](repeating: 7, count: 1000)
        #expect(KittyDeflate.fast(stream(raw)[2...], capacity: 10) == nil)
    }

    @Test func checksumAlgorithmMatchesKnownValues() {
        #expect(KittyInflate.adler32(Array("Wikipedia".utf8)) == 0x11E60398)
        #expect(KittyInflate.adler32([]) == 1)
    }
}

struct KittyEngineNamespaceTests {
    @Test func theSameClientIDInBothBuffersDoesNotCollide() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(apc("a=t,f=24,s=1,v=1,i=1", pixel))
        emulator.feed(text("\u{1B}[?1049h"))
        emulator.feed(apc("a=t,f=24,s=2,v=1,i=1", "AAAAAAAA"))
        #expect(emulator.normalStore.engineIDs[1] != nil && emulator.altStore.engineIDs[1] != nil)
        #expect(emulator.normalStore.engineIDs[1] != emulator.altStore.engineIDs[1])
        emulator.feed(text("\u{1B}[?1049l"))
        emulator.feed(apc("a=p,i=1,C=1"))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].pixelSize == CGSize(width: 1, height: 1))
    }

    @Test func freeingAnImageInOneBufferKeepsTheOthersCopy() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1))
        emulator.feed(text("\u{1B}[?1049h"))
        emulator.feed(transmit(1))
        emulator.feed(apc("a=d,d=I,i=1"))
        #expect(!emulator.engineHasImage(1))
        emulator.feed(text("\u{1B}[?1049l"))
        #expect(emulator.engineHasImage(1))
    }

    @Test func repliesShowTheClientsIDsNotTheEngines() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(transmit(1))
        emulator.feed(text("\u{1B}[?1049h"))
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=24,s=1,v=1,I=9,C=1", pixel))
        #expect(replies.contain("i=1,I=9;OK"))
        emulator.feed(apc("a=p,i=1,p=4,C=1"))
        #expect(replies.contain("i=1,p=4;OK"))
        emulator.feed(apc("a=p,i=77"))
        #expect(replies.contain("i=77;ENOENT"))
    }

    @Test func numberBasedTransmitsUseTheirOwnIDsWithoutTheEngine() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let replies = capture(emulator)
        emulator.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        emulator.feed(apc("a=p,I=5,p=2,C=1"))
        #expect(replies.contain("i=1,I=5;OK"))
        #expect(replies.contain("i=1,I=5,p=2;OK"))
        #expect(emulator.images.map(\.kittyID) == [1, 1])
    }
}

struct KittyRootEditTests {
    private func redPixel(_ image: InlineImage, _ x: Int = 0, _ y: Int = 0) -> [UInt8] {
        guard let cg = image.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
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

    @Test func editingTheRootFrameRefreshesTheEngineCopy() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,r=1", "/wAA"))
        emulator.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(emulator.images.count == 2)
        #expect(redPixel(emulator.images[1]) == [255, 0, 0, 255])
    }

    @Test func composingOntoTheRootFrameRefreshesTheEngineCopy() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        let blank = String(repeating: "A", count: 22) + "=="
        emulator.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", blank))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1,c=1", "/wAA"))
        emulator.feed(apc("a=c,i=1,r=2,c=1,w=1,h=1,x=1,y=1,C=1"))
        emulator.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(redPixel(emulator.images[1], 1, 1) == [255, 0, 0, 255])
        #expect(redPixel(emulator.images[1], 0, 0)[3] == 0)
    }

    @Test func editingANonRootFrameLeavesTheEngineCopyAlone() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(put("i=1,C=1"))
        emulator.feed(apc("a=f,f=24,s=1,v=1,i=1", "/wAA"))
        emulator.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(redPixel(emulator.images[1]) == [0, 0, 0, 255])
    }
}

struct KittyScrollbackClearTests {
    @Test func screenContentsMoveIntoScrollbackAndKeepTheirPlacements() {
        let emulator = BlockEmulator(cols: 40, rows: 5)
        emulator.feed(put("i=1,C=1") + text("\r\n\r\nhello") + text("\u{1B}[22J"))
        #expect(emulator.images.count == 1)
        #expect(emulator.sources[1] != nil)
        #expect(String(emulator.render().characters).contains("hello"))
    }

    @Test func placementsBelowTheLastTextRowAreDeleted() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(text("x") + move(6, 1) + put("i=1,C=1") + text("\u{1B}[22J"))
        #expect(emulator.images.isEmpty)
        #expect(emulator.sources.isEmpty)
        #expect(String(emulator.render().characters).contains("x"))
    }

    @Test func scannerSplitsOffTheSequence() {
        let split = KittyGraphicsScanner.split(text("ab\u{1B}[22Jcd"))
        #expect(split.pieces.count == 2)
        #expect(String(decoding: split.pieces[0].bytes, as: UTF8.self) == "ab")
        if case .clear(let scope) = split.pieces[0].kind {
            #expect(scope == .scrollback)
        } else {
            Issue.record("expected a scrollback clear")
        }
    }
}
