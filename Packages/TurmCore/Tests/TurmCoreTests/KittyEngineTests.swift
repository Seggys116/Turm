import CoreGraphics
import Darwin
import Foundation
import Testing

@testable import TurmCore

private let pixel = KittyFixtures.pixel
private let pngPixel = KittyFixtures.pngPixel
private let zlibTwelveZeros = KittyFixtures.zlibTwelveZeros

private func apc(_ keys: String, _ payload: String = "") -> [UInt8] { KittyFixtures.apc(keys, payload) }
private func put(_ keys: String) -> [UInt8] { KittyFixtures.put(keys) }
private func transmit(_ id: Int) -> [UInt8] { KittyFixtures.transmit(id) }
private func move(_ row: Int, _ column: Int) -> [UInt8] { KittyFixtures.move(row, column) }
private func text(_ value: String) -> [UInt8] { KittyFixtures.text(value) }
private func base64(_ value: String) -> String { KittyFixtures.base64(value) }
private func scratchFile(_ data: Data, protocolName: Bool) -> URL { KittyFixtures.scratchFile(data, protocolName: protocolName) }
private func pixelBytes(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] { KittyFixtures.pixelBytes(image, x, y) }

private func ids(_ rig: KittyRig) -> [UInt32] {
    rig.images.compactMap(\.kittyID).sorted()
}

private func animation(_ placement: GraphicsPlacement) -> KittyAnimation? {
    if case .animated(let animation) = placement.source { return animation }
    return nil
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

    @Test func scrollbackClearIsSplitOffTheSequence() {
        let split = KittyGraphicsScanner.split(text("ab\u{1B}[22Jcd"))
        #expect(split.pieces.count == 2)
        #expect(String(decoding: split.pieces[0].bytes, as: UTF8.self) == "ab")
        if case .clear(let scope) = split.pieces[0].kind {
            #expect(scope == .scrollback)
        } else {
            Issue.record("expected a scrollback clear")
        }
    }

    @Test func mediumsIgnoreTheChunkFlag() {
        #expect(!KittyGraphicsScanner.parse(Array("a=T,t=f,m=1".utf8)[...]).more)
        #expect(KittyGraphicsScanner.parse(Array("a=T,t=d,m=1".utf8)[...]).more)
    }
}

struct KittyPlacementTests {
    @Test func oneImageCanHaveSeveralPlacements() {
        let rig = KittyRig()
        rig.feed(transmit(1))
        rig.feed(apc("a=p,i=1,p=1,C=1") + apc("a=p,i=1,p=2,C=1"))
        #expect(rig.images.map(\.placementID) == [1, 2])
        #expect(rig.images.allSatisfy { $0.kittyID == 1 })
    }

    @Test func samePlacementIDReplacesThePlacement() {
        let rig = KittyRig()
        rig.feed(transmit(1))
        rig.feed(apc("a=p,i=1,p=1,C=1") + move(4, 4) + apc("a=p,i=1,p=1,C=1"))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].origin == GridPoint(row: 3, column: 3))
    }

    @Test func placementWithoutImageIDIgnoresPlacementID() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,p=4", pixel))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].placementID == nil)
    }

    @Test func retransmittingAnImageDropsItsPlacements() {
        let rig = KittyRig()
        rig.feed(transmit(1) + apc("a=p,i=1,p=1,C=1") + apc("a=p,i=1,p=2,C=1"))
        #expect(rig.images.count == 2)
        rig.feed(transmit(1))
        #expect(rig.images.isEmpty)
    }

    @Test func zIndexIsRecorded() {
        let rig = KittyRig()
        rig.feed(put("i=1,z=-1,C=1") + put("i=2,z=7,C=1"))
        #expect(rig.images.map(\.zIndex) == [-1, 7])
    }

    @Test func cellOffsetsAreRecordedInPixels() {
        let rig = KittyRig()
        rig.feed(put("i=1,X=3,Y=2,C=1"))
        #expect(rig.images[0].pixelOffset == CGSize(width: 3, height: 2))
    }

    @Test func offsetsAreClampedInsideTheCell() {
        let rig = KittyRig()
        rig.feed(put("i=1,X=5000,Y=5000,C=1"))
        #expect(rig.images[0].pixelOffset == CGSize(width: 9, height: 19))
    }

    @Test func sourceRectangleCropsTheImage() {
        let rig = KittyRig()
        let data = String(repeating: "A", count: 22) + "=="
        rig.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", data))
        rig.feed(apc("a=T,f=32,s=2,v=2,i=2,x=1,y=0,w=1,h=2,C=1", data))
        #expect(rig.images[0].pixelSize == CGSize(width: 2, height: 2))
        #expect(rig.images[1].pixelSize == CGSize(width: 1, height: 2))
    }

    @Test func pngPlacementsAreTracked() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=100,i=8,z=2", pngPixel))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].kittyID == 8 && rig.images[0].zIndex == 2)
        #expect(rig.images[0].pixelSize == CGSize(width: 1, height: 1))
    }

    @Test func chunkedTransmissionIsPlacedOnce() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=2,v=1,i=6,m=1", "AAAA"))
        #expect(rig.images.isEmpty)
        rig.feed(apc("m=0", "AAAA"))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].kittyID == 6)
        #expect(rig.images[0].pixelSize.width == 2)
    }

    @Test func commandSplitAcrossReadsIsAssembled() {
        let rig = KittyRig()
        let full = put("i=4")
        rig.feed(Array(full[..<12]))
        #expect(rig.images.isEmpty)
        rig.feed(Array(full[12...]))
        #expect(rig.images.map(\.kittyID) == [4])
    }

    @Test func imageNumbersGetAnIDAndReply() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        #expect(rig.replies.contain("i=1,I=5;OK"))
        #expect(rig.images.map(\.kittyID) == [1])
        rig.feed(apc("a=p,I=5,p=2,C=1"))
        #expect(rig.images.count == 2)
        #expect(rig.images[1].kittyID == 1 && rig.images[1].placementID == 2)
        rig.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        #expect(rig.images.last?.kittyID == 2)
        rig.feed(apc("a=d,d=n,I=5"))
        #expect(ids(rig) == [1, 1])
    }

    @Test func placementsRecordTheScreenScale() {
        let rig = KittyRig()
        rig.host.screen.scale = 2
        rig.feed(put("i=1,C=1"))
        #expect(rig.images[0].scale == 2)
        #expect(rig.images[0].fromKitty)
    }
}

struct KittyLayoutTests {
    @Test func placementRecordsItsSpanAndOrigin() {
        let rig = KittyRig()
        rig.feed(put("i=1,c=3,r=2"))
        #expect(rig.images[0].rowSpan == 2 && rig.images[0].columnSpan == 3)
        #expect(rig.images[0].origin == GridPoint(row: 0, column: 0))
    }

    @Test func cursorMovesPastThePlacedImage() {
        let rig = KittyRig()
        rig.feed(put("i=1,c=3,r=2"))
        #expect(rig.host.cursor.row == 2)
        rig.feed(text("after"))
        #expect(rig.host.cursor.row == 2)
    }

    @Test func cursorPolicyKeepsTheCursorInPlace() {
        let rig = KittyRig()
        rig.feed(put("i=1,c=3,r=2,C=1"))
        #expect(rig.host.cursor == GridPoint(row: 0, column: 0))
        #expect(rig.images[0].rowSpan == 2)
    }

    @Test func imageAtTheBottomScrollsTheScreen() {
        let rig = KittyRig(columns: 40, rows: 5)
        rig.feed(text("\n\n\n\n") + put("i=1,c=2,r=3"))
        #expect(rig.images[0].origin.row == 4 && rig.images[0].rowSpan == 3)
        #expect(rig.host.cursor.row == 7)
        #expect(rig.host.screen.top == 3)
    }

    @Test func imageInTheMiddleOfTheScreenDoesNotScroll() {
        let rig = KittyRig()
        rig.feed(put("i=1,c=2,r=3"))
        #expect(rig.host.screen.top == 0)
        #expect(rig.host.cursor.row == 3)
    }

    @Test func overlappingImagesAreBothKept() {
        let rig = KittyRig()
        rig.feed(put("i=1,c=2,r=2,z=5,C=1") + put("i=2,c=2,r=2,z=-1,C=1"))
        let shown = rig.visible()
        #expect(Set(shown.compactMap(\.kittyID)) == [1, 2])
        #expect(shown.first { $0.kittyID == 1 }?.zIndex == 5)
        #expect(shown.first { $0.kittyID == 2 }?.zIndex == -1)
    }

    @Test func imagesAreAnchoredToTheirColumn() {
        let rig = KittyRig()
        rig.feed(move(1, 6) + put("i=1,C=1"))
        #expect(rig.images[0].origin.column == 5)
    }

    @Test func imagesAreAnchoredToTheirAbsoluteRow() {
        let rig = KittyRig(columns: 40, rows: 5)
        rig.feed(text("\n\n\n\n\n\n") + move(2, 1) + put("i=1,C=1"))
        #expect(rig.host.screen.top == 2)
        #expect(rig.images[0].origin.row == 3)
    }

    @Test func visibleRowsFilterThePlacements() {
        let rig = KittyRig()
        rig.feed(move(1, 1) + put("i=1,C=1") + move(8, 1) + put("i=2,C=1"))
        #expect(rig.visible(0..<4).compactMap(\.kittyID) == [1])
        #expect(rig.visible(6..<10).compactMap(\.kittyID) == [2])
        #expect(Set(rig.visible(0..<10).compactMap(\.kittyID)) == [1, 2])
    }
}

struct KittyDeleteTests {
    private func scene() -> KittyRig {
        let rig = KittyRig()
        rig.feed(move(1, 1) + put("i=1,c=2,r=1,C=1"))
        rig.feed(move(3, 5) + put("i=2,c=2,r=2,z=-1,C=1"))
        rig.feed(move(6, 10) + put("i=3,c=1,r=1,z=5,C=1"))
        return rig
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
            let rig = scene()
            rig.feed(apc(keys.isEmpty ? "a=d" : "a=d,\(keys)"))
            #expect(ids(rig) == remaining, "\(keys)")
        }
    }

    @Test func deleteAtTheCursorRemovesPlacementsUnderIt() {
        let rig = scene()
        rig.feed(move(6, 10) + apc("a=d,d=c"))
        #expect(ids(rig) == [1, 2])
        rig.feed(move(9, 9) + apc("a=d,d=C"))
        #expect(ids(rig) == [1, 2])
    }

    @Test func positionDeletesUseTheScrolledScreenTop() {
        let rig = KittyRig(columns: 40, rows: 5)
        rig.feed(text("\n\n\n\n\n\n") + move(2, 1) + put("i=1,C=1"))
        rig.feed(apc("a=d,d=p,x=1,y=1"))
        #expect(ids(rig) == [1])
        rig.feed(apc("a=d,d=p,x=1,y=2"))
        #expect(ids(rig).isEmpty)
    }

    @Test func deletingOnePlacementKeepsTheOthers() {
        let rig = KittyRig()
        rig.feed(transmit(1) + apc("a=p,i=1,p=1,C=1") + apc("a=p,i=1,p=2,C=1"))
        rig.feed(apc("a=d,d=i,i=1,p=2"))
        #expect(rig.images.map(\.placementID) == [1])
    }

    @Test func deletedImageCanStillBePlacedAgainAfterSoftDelete() {
        let rig = KittyRig()
        rig.feed(transmit(1) + apc("a=p,i=1,p=1,C=1") + apc("a=d,d=i,i=1"))
        #expect(rig.images.isEmpty)
        rig.feed(apc("a=p,i=1,p=1,C=1"))
        #expect(rig.images.count == 1)
    }

    @Test func freeingOneImageKeepsOthersPlaceable() {
        let rig = KittyRig()
        rig.feed(transmit(1) + transmit(2) + apc("a=p,i=1,p=1,C=1") + apc("a=d,d=I,i=2"))
        rig.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(rig.images.count == 2)
    }

    @Test func clearingTheScreenRemovesPlacements() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1") + text("\u{1B}[2J"))
        #expect(rig.images.isEmpty)
    }

    @Test func imagePlacedAfterAClearSurvives() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1") + text("\u{1B}[3J\u{1B}[H") + put("i=2,C=1"))
        #expect(ids(rig) == [2])
    }
}

struct KittyRelativeTests {
    private func parentAndChild() -> KittyRig {
        let rig = KittyRig()
        rig.feed(move(4, 6) + put("i=1,p=1,C=1"))
        rig.feed(apc("a=T,f=24,s=1,v=1,i=2,p=1,P=1,Q=1,H=2,V=1", pixel))
        return rig
    }

    @Test func childIsPositionedFromItsParent() {
        let rig = parentAndChild()
        #expect(rig.images.count == 2)
        let parent = rig.images.origin(of: rig.images[0])
        let child = rig.images.origin(of: rig.images[1])
        #expect(parent == GridPoint(row: 3, column: 5))
        #expect(child == GridPoint(row: 4, column: 7))
    }

    @Test func childRecordsItsParentOffsets() {
        let rig = parentAndChild()
        #expect(rig.images[1].parent == KittyParent(imageID: 1, placementID: 1, columns: 2, rows: 1))
        #expect(rig.images[0].parent == nil)
    }

    @Test func relativePlacementLeavesTheCursorAlone() {
        let rig = parentAndChild()
        #expect(rig.host.cursor == GridPoint(row: 3, column: 5))
    }

    @Test func deletingTheParentDeletesTheChild() {
        let rig = parentAndChild()
        rig.feed(apc("a=d,d=i,i=1,p=1"))
        #expect(rig.images.isEmpty)
    }

    @Test func missingParentIsReported() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,i=2,P=9,Q=9", pixel))
        #expect(rig.replies.contain("ENOPARENT"))
        #expect(rig.images.isEmpty)
    }

    @Test func cyclesAreRejected() {
        let rig = parentAndChild()
        rig.feed(apc("a=p,i=1,p=1,P=2,Q=1"))
        #expect(rig.replies.contain("ECYCLE"))
        #expect(rig.images.count == 2)
    }
}

struct KittyQuietTests {
    @Test func quietOneKeepsErrorsAndDropsOK() {
        let rig = KittyRig()
        rig.feed(put("i=1,q=1,C=1"))
        #expect(rig.replies.lines.isEmpty)
        rig.feed(apc("a=p,i=99,q=1"))
        #expect(rig.replies.contain("ENOENT"))
    }

    @Test func quietTwoDropsEverything() {
        let rig = KittyRig()
        rig.feed(put("i=1,q=2,C=1") + apc("a=p,i=99,q=2"))
        #expect(rig.replies.lines.isEmpty)
        #expect(rig.images.count == 1)
    }

    @Test func defaultQuietDeliversBoth() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1") + apc("a=p,i=99"))
        #expect(rig.replies.contain("i=1;OK"))
        #expect(rig.replies.contain("ENOENT"))
    }

    @Test func quietAppliesToAFailedTransmit() {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=2,v=2,i=3,q=2", pixel))
        #expect(rig.replies.lines.isEmpty)
        rig.feed(apc("a=t,f=24,s=2,v=2,i=3,q=1", pixel))
        #expect(rig.replies.contain("i=3;ENODATA"))
    }

    @Test func repliesAreFramedAsKittyGraphicsSequences() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        #expect(rig.replies.lines == ["\u{1B}_Gi=1;OK\u{1B}\\"])
    }
}

struct KittyImageNumberTests {
    @Test func failedTransmitDoesNotShiftIDs() {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=2,v=2,I=5", pixel))
        #expect(rig.replies.contain("I=5;ENODATA:Insufficient image data: 3 < 12"))
        rig.feed(apc("a=T,f=24,s=1,v=1,I=6,C=1", pixel))
        #expect(rig.replies.contain("i=1,I=6;OK"))
        #expect(rig.images.map(\.kittyID) == [1])
    }

    @Test func idsFollowTheEngineEvenWhenRepliesAreSilenced() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=7,q=2,C=1", pixel) + apc("a=T,f=24,s=1,v=1,I=7,q=2,C=1", pixel))
        #expect(ids(rig) == [1, 2])
        rig.feed(apc("a=d,d=n,I=7"))
        #expect(ids(rig) == [1])
    }

    @Test func numberBasedTransmitsReplyWithTheirOwnIDs() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=5,C=1", pixel))
        rig.feed(apc("a=p,I=5,p=2,C=1"))
        #expect(rig.replies.contain("i=1,I=5;OK"))
        #expect(rig.replies.contain("i=1,I=5,p=2;OK"))
        #expect(rig.images.map(\.kittyID) == [1, 1])
    }

    @Test func repliesShowTheClientsIDs() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=9,C=1", pixel))
        #expect(rig.replies.contain("i=1,I=9;OK"))
        rig.feed(apc("a=p,i=1,p=4,C=1"))
        #expect(rig.replies.contain("i=1,p=4;OK"))
        rig.feed(apc("a=p,i=77"))
        #expect(rig.replies.contain("i=77;ENOENT"))
    }

    @Test func idAndNumberTogetherAreRejectedForEveryAction() {
        for action in ["p", "d", "q"] {
            let rig = KittyRig()
            rig.feed(apc("a=\(action),f=24,s=1,v=1,i=1,I=2", pixel))
            #expect(rig.replies.contain("EINVAL:Must not specify both image id and image number"), "\(action)")
        }
    }
}

struct KittyAnimationTests {
    private func animated() -> KittyRig {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,z=50", pixel))
        return rig
    }

    @Test func frameTransmissionAppendsAFrame() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,z=50", pixel))
        #expect(rig.replies.contain("i=1,r=2;OK"))
        #expect(!rig.replies.contain("4294967000"))
        #expect(rig.sources[1]?.frames.count == 2)
        #expect(rig.sources[1]?.frames[1].gap == 50)
        #expect(animation(rig.images[0]) === rig.sources[1])
    }

    @Test func editingAFrameKeepsTheCount() {
        let rig = animated()
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,r=2,z=90", pixel))
        #expect(rig.sources[1]?.frames.count == 2)
        #expect(rig.sources[1]?.frames[1].gap == 90)
    }

    @Test func frameOfAnUnknownImageIsRejected() {
        let rig = KittyRig()
        rig.feed(apc("a=f,f=24,s=1,v=1,i=9", pixel))
        #expect(rig.replies.contain("ENOENT"))
    }

    @Test func frameDataIsComposedOntoTheBase() {
        let rig = KittyRig()
        let blank = String(repeating: "A", count: 22) + "=="
        rig.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", blank))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,x=1,y=0,c=1", "/wAA"))
        guard let frame = rig.sources[1]?.frames[1].image else {
            Issue.record("the frame should exist")
            return
        }
        #expect(pixelBytes(frame, 1, 0) == [255, 0, 0, 255])
        #expect(pixelBytes(frame, 0, 0)[3] == 0)
    }

    @Test func frameLargerThanTheImageIsRejected() {
        let rig = animated()
        rig.feed(apc("a=f,f=24,s=2,v=1,i=1", "AAAAAAAA"))
        #expect(rig.replies.contain("EINVAL:Frame width 2 larger than image width: 1"))
        #expect(rig.sources[1]?.frames.count == 2)
    }

    @Test func frameOffsetsBeyondTheImageAreClippedNotRejected() {
        let rig = animated()
        let before = rig.replies.lines.count
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,x=4,y=4", pixel))
        #expect(!rig.replies.lines.dropFirst(before).joined().contains("EINVAL"))
        #expect(rig.sources[1]?.frames.count == 3)
    }

    @Test func controlCommandsSetStateFrameAndGap() {
        let rig = animated()
        let before = rig.replies.lines.count
        rig.feed(apc("a=a,i=1,s=3,v=3"))
        #expect(rig.sources[1]?.state == 3 && rig.sources[1]?.loops == 3)
        rig.feed(apc("a=a,i=1,s=1,c=2"))
        #expect(rig.sources[1]?.state == 1 && rig.sources[1]?.current == 1)
        rig.feed(apc("a=a,i=1,r=2,z=70"))
        #expect(rig.sources[1]?.frames[1].gap == 70)
        rig.feed(apc("a=a,i=1,r=2,z=-5"))
        #expect(rig.sources[1]?.frames[1].gap == 0)
        rig.feed(apc("a=a,i=1,c=9,r=9,z=10,s=7"))
        #expect(rig.sources[1]?.current == 1 && rig.sources[1]?.state == 1)
        #expect(rig.replies.lines.count == before)
    }

    @Test func controlOfAMissingImageIsReported() {
        let rig = animated()
        let before = rig.replies.lines.count
        rig.feed(apc("a=a,i=9,s=3"))
        #expect(rig.replies.contain("i=9;ENOENT:Animation command refers to non-existent image with id: 9 and number: 0"))
        rig.feed(apc("a=a,s=3"))
        #expect(rig.replies.lines.count == before + 1)
    }

    @Test func idAndNumberTogetherAreRejected() {
        let rig = animated()
        rig.feed(apc("a=a,i=1,I=2,s=3"))
        #expect(rig.replies.contain("i=1,I=2;EINVAL:Must not specify both image id and image number"))
        #expect(rig.sources[1]?.state == 1)
    }

    @Test func composingFramesCopiesARectangle() {
        let rig = KittyRig()
        let blank = String(repeating: "A", count: 22) + "=="
        rig.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", blank))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,c=1", "/wAA"))
        rig.feed(apc("a=c,i=1,r=2,c=1,w=1,h=1,x=1,y=1,C=1"))
        guard let root = rig.sources[1]?.frames[0].image else {
            Issue.record("the root frame should exist")
            return
        }
        #expect(pixelBytes(root, 1, 1) == [255, 0, 0, 255])
        rig.feed(apc("a=c,i=1,r=2,c=1,w=1,h=1,x=5,y=5"))
        #expect(rig.replies.contain("EINVAL"))
    }

    @Test func frameRepliesCarryTheNumberAndPlacementInKittyOrder() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,I=3,C=1", pixel))
        rig.feed(apc("a=f,f=24,s=1,v=1,I=3,p=8", pixel))
        #expect(rig.replies.lines.last?.contains("I=3,p=8,r=2;OK") == true)
        #expect(rig.replies.lines.last?.contains("i=") == false)
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,p=8", pixel))
        #expect(rig.replies.lines.last?.contains("i=1,p=8,r=3;OK") == true)
    }

    @Test func newFramesFollowTheGapRules() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1", pixel))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,z=-1", pixel))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,z=25", pixel))
        #expect(rig.sources[1]?.frames.map(\.gap) == [0, 40, 0, 25])
    }

    @Test func frameNumberBeyondTheEndAppendsAndBadBaseIsRejected() {
        let rig = animated()
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,r=3", pixel))
        #expect(rig.sources[1]?.frames.count == 3)
        #expect(rig.replies.contain("i=1,r=3;OK"))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,c=9", pixel))
        #expect(rig.replies.contain("EINVAL:No frame with number: 9 found"))
        #expect(rig.sources[1]?.frames.count == 3)
    }

    @Test func composeErrorsUseKittyMessages() {
        let rig = animated()
        rig.feed(apc("a=c,i=1,r=7,c=1"))
        #expect(rig.replies.contain("ENOENT:No source frame number 7 exists in image id: 1"))
        rig.feed(apc("a=c,i=1,r=1,c=7"))
        #expect(rig.replies.contain("ENOENT:No destination frame number 7 exists in image id: 1"))
        rig.feed(apc("a=c,i=1,r=1,c=2,w=2"))
        #expect(rig.replies.contain("EINVAL:The destination rectangle is out of bounds"))
        rig.feed(apc("a=c,i=1,r=1,c=1"))
        #expect(rig.replies.contain("EINVAL:The source and destination rectangles overlap and the src and destination frames are the same"))
    }

    @Test func placementsShareTheAnimationAndKeepTheirCrop() {
        let rig = animated()
        rig.feed(apc("a=p,i=1,p=2,C=1"))
        #expect(rig.images.count == 2)
        #expect(rig.images.allSatisfy { animation($0)?.frames.count == 2 })
        #expect(animation(rig.images[0]) === animation(rig.images[1]))
    }

    @Test func playbackStartsAtTheEnginesClock() {
        let rig = animated()
        rig.feed(apc("a=a,i=1,r=1,z=100"))
        rig.feed(apc("a=a,i=1,r=2,z=100"))
        let start = rig.clock.date
        rig.feed(apc("a=a,i=1,s=3"))
        guard let source = rig.sources[1] else {
            Issue.record("the animated image should exist")
            return
        }
        #expect(source.frameIndex(at: start.addingTimeInterval(0.05)) == 0)
        #expect(source.frameIndex(at: start.addingTimeInterval(0.15)) == 1)
        #expect(source.frameIndex(at: start.addingTimeInterval(0.25)) == 0)
    }

    @Test func stoppingPlaybackFreezesTheFrameShownAtTheEnginesClock() {
        let rig = animated()
        rig.feed(apc("a=a,i=1,r=1,z=100"))
        rig.feed(apc("a=a,i=1,r=2,z=100"))
        rig.feed(apc("a=a,i=1,s=3"))
        rig.clock.advance(0.15)
        rig.feed(apc("a=a,i=1,s=1"))
        #expect(rig.sources[1]?.state == 1)
        #expect(rig.sources[1]?.current == 1)
    }

}

struct KittyDeleteFrameTests {
    private func threeFrames() -> KittyRig {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,z=10", pixel))
        rig.feed(apc("a=f,f=24,s=1,v=1,i=1,z=20", pixel))
        return rig
    }

    @Test func withoutAnIDNothingHappens() {
        let rig = threeFrames()
        let before = rig.replies.lines.count
        rig.feed(apc("a=d,d=f"))
        rig.feed(apc("a=d,d=F"))
        #expect(rig.sources[1]?.frames.count == 3)
        #expect(rig.replies.lines.count == before)
    }

    @Test func deletesExactlyOneFrameByIDOrNumber() {
        let rig = threeFrames()
        rig.feed(apc("a=d,d=f,i=1,r=2"))
        #expect(rig.sources[1]?.frames.map(\.gap) == [0, 20])
        let numbered = KittyRig()
        numbered.feed(apc("a=T,f=24,s=1,v=1,I=4,C=1", pixel))
        numbered.feed(apc("a=f,f=24,s=1,v=1,I=4,z=10", pixel))
        numbered.feed(apc("a=f,f=24,s=1,v=1,I=4,z=20", pixel))
        numbered.feed(apc("a=d,d=F,I=4,r=3"))
        #expect(numbered.sources[1]?.frames.map(\.gap) == [0, 10])
    }

    @Test func frameOneRemovalPromotesTheNextFrame() {
        let rig = threeFrames()
        rig.feed(apc("a=d,d=f,i=1"))
        #expect(rig.sources[1]?.frames.map(\.gap) == [10, 20])
        rig.feed(apc("a=d,d=f,i=1,r=1"))
        #expect(rig.sources[1]?.frames.map(\.gap) == [20])
    }

    @Test func oversizedFrameNumberRemovesTheLastFrame() {
        let rig = threeFrames()
        rig.feed(apc("a=d,d=f,i=1,r=50"))
        #expect(rig.sources[1]?.frames.map(\.gap) == [0, 10])
    }

    @Test func lowercaseKeepsASingleFrameImageAndUppercaseRemovesIt() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=d,d=f,i=1"))
        #expect(rig.sources[1] != nil && rig.images.count == 1)
        rig.feed(apc("a=d,d=F,i=1"))
        #expect(rig.sources[1] == nil)
        #expect(rig.images.isEmpty)
    }

    @Test func uppercaseOnAMultiFrameImageOnlyRemovesAFrame() {
        let rig = threeFrames()
        rig.feed(apc("a=d,d=F,i=1,r=2"))
        #expect(rig.sources[1]?.frames.count == 2)
        #expect(rig.images.count == 1)
    }

    @Test func idAndNumberTogetherAreRejected() {
        let rig = threeFrames()
        rig.feed(apc("a=d,d=f,i=1,I=2"))
        #expect(rig.replies.contain("EINVAL:Must not specify both image id and image number"))
        #expect(rig.sources[1]?.frames.count == 3)
    }

    @Test func removingTheShownFrameOfARunningAnimationKeepsItPlayable() {
        let rig = threeFrames()
        rig.feed(apc("a=a,i=1,s=3,c=3"))
        rig.feed(apc("a=d,d=f,i=1,r=3"))
        #expect(rig.sources[1]?.frames.count == 2)
        #expect(rig.sources[1]?.duration == 10)
        #expect((rig.sources[1]?.frameIndex(at: rig.clock.date) ?? 9) < 2)
    }
}

struct KittyMediumTests {
    private let png = Data(base64Encoded: pngPixel)!

    @Test func pngFileIsReadAndKept() {
        let url = scratchFile(png, protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(apc("a=T,f=100,t=f,i=1,C=1", base64(url.path)))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].pixelSize == CGSize(width: 1, height: 1))
        #expect(rig.sources[1] != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func temporaryFileIsRemovedAfterReading() {
        let url = scratchFile(Data(count: 3), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,t=t,i=2,C=1", base64(url.path)))
        #expect(rig.images.count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func temporaryFileWithoutTheProtocolNameIsReadButKept() {
        let url = scratchFile(Data(count: 3), protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,t=t,i=2,C=1", base64(url.path)))
        #expect(rig.images.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func transmitOnlyFileStillCapturesTheRootFrame() {
        let url = scratchFile(png, protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(apc("a=t,f=100,t=f,i=3", base64(url.path)))
        #expect(rig.images.isEmpty)
        #expect(rig.sources[3]?.frames.count == 1)
        rig.feed(apc("a=p,i=3,C=1"))
        #expect(rig.images.map(\.kittyID) == [3])
    }

    @Test func transmitOnlyTemporaryFileIsReadOnce() {
        let url = scratchFile(Data(count: 3), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=1,v=1,t=t,i=4", base64(url.path)))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(rig.sources[4] != nil)
        rig.feed(apc("a=p,i=4,C=1"))
        #expect(rig.images.count == 1)
    }

    @Test func frameDataCanComeFromAFile() {
        let url = scratchFile(Data(count: 3), protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=f,f=24,s=1,v=1,t=f,i=1", base64(url.path)))
        #expect(rig.sources[1]?.frames.count == 2)
    }

    @Test func croppedTemporaryFileIsReadOnce() {
        let url = scratchFile(Data(count: 12), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=2,v=2,t=t,x=0,y=0,w=1,h=2,i=4,C=1", base64(url.path)))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].pixelSize == CGSize(width: 1, height: 2))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: KittySharedMemory.works(), "POSIX shared memory cannot be created, mapped and re-opened read-only here"))
    func sharedMemoryIsReadAndUnlinked() {
        let name = KittySharedMemory.uniqueName()
        defer { KittySharedMemory.unlink(name) }
        #expect(KittySharedMemory.create(name, size: 3))
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,t=s,i=5,C=1", base64(name)))
        #expect(rig.images.count == 1)
        #expect(rig.sources[5] != nil)
        #expect(!KittySharedMemory.exists(name))
    }

    @Test func fileMediumsAreRefusedWhenLocalMediaIsDisallowed() {
        let url = scratchFile(Data(count: 3), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        for medium in ["f", "t"] {
            let rig = KittyRig()
            rig.host.allowsLocalMedia = false
            rig.feed(apc("a=T,f=24,s=1,v=1,t=\(medium),i=1,C=1", base64(url.path)))
            #expect(rig.replies.contain("i=1;EBADF:Failed to read image file"), "\(medium)")
            #expect(rig.images.isEmpty, "\(medium)")
            #expect(rig.sources[1] == nil, "\(medium)")
            #expect(FileManager.default.fileExists(atPath: url.path), "\(medium)")
        }
    }

    @Test func pngFileIsRefusedWhenLocalMediaIsDisallowed() {
        let url = scratchFile(png, protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.host.allowsLocalMedia = false
        rig.feed(apc("a=T,f=100,t=f,i=1,C=1", base64(url.path)))
        #expect(rig.replies.contain("EBADF:Failed to read image file"))
        #expect(rig.images.isEmpty)
    }

    @Test func frameFileIsRefusedWhenLocalMediaIsDisallowed() {
        let url = scratchFile(Data(count: 3), protocolName: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.host.allowsLocalMedia = false
        rig.feed(apc("a=f,f=24,s=1,v=1,t=f,i=1", base64(url.path)))
        #expect(rig.replies.contain("EBADF"))
        #expect(rig.sources[1]?.frames.count == 1)
    }

    @Test(.enabled(if: KittySharedMemory.works(), "POSIX shared memory cannot be created, mapped and re-opened read-only here"))
    func sharedMemoryIsRefusedAndKeptWhenLocalMediaIsDisallowed() {
        let name = KittySharedMemory.uniqueName()
        defer { KittySharedMemory.unlink(name) }
        #expect(KittySharedMemory.create(name, size: 3))
        let rig = KittyRig()
        rig.host.allowsLocalMedia = false
        rig.feed(apc("a=T,f=24,s=1,v=1,t=s,i=5,C=1", base64(name)))
        #expect(rig.replies.contain("i=5;EBADF:Failed to read image file"))
        #expect(rig.images.isEmpty)
        #expect(KittySharedMemory.exists(name))
    }

    @Test func directDataIsStillAcceptedWhenLocalMediaIsDisallowed() {
        let rig = KittyRig()
        rig.host.allowsLocalMedia = false
        rig.feed(put("i=1,C=1"))
        #expect(rig.images.count == 1)
        #expect(rig.replies.contain("i=1;OK"))
    }
}

struct KittyInternalIDTests {
    @Test func croppedTransmitWithoutAnIDGetsAnInternalOne() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=2,v=2,x=0,y=0,w=1,h=2,C=1", "AAAAAAAAAAAAAAAA"))
        #expect(rig.replies.lines.isEmpty)
        #expect(rig.images.count == 1)
        #expect(rig.images[0].pixelSize == CGSize(width: 1, height: 2))
        #expect(rig.images[0].placementID == nil)
        guard let id = rig.images[0].kittyID else {
            Issue.record("the placement should carry an internal id")
            return
        }
        #expect(rig.sources[id]?.frames.count == 1)
        #expect(animation(rig.images[0]) === rig.sources[id])
        rig.feed(apc("a=d"))
        #expect(rig.images.isEmpty)
    }
}

struct KittyErrorTests {
    private func reply(_ keys: String, _ payload: String = "AAAA") -> String {
        let rig = KittyRig()
        rig.feed(apc(keys, payload))
        return rig.replies.lines.joined()
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

    @Test func compressedDataIsInflatedBeforePlacement() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=2,v=2,o=z,i=1,C=1", zlibTwelveZeros))
        #expect(rig.images.count == 1)
        #expect(rig.images[0].pixelSize == CGSize(width: 2, height: 2))
        #expect(rig.replies.contain("i=1;OK"))
    }

    @Test func compressedChunksAreAssembledFirst() {
        let rig = KittyRig()
        let value = zlibTwelveZeros
        let split = value.index(value.startIndex, offsetBy: 8)
        rig.feed(apc("a=T,f=24,s=2,v=2,o=z,i=1,m=1,C=1", String(value[..<split])))
        rig.feed(apc("m=0", String(value[split...])))
        #expect(rig.images.count == 1)
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
        let result = reply("a=t,f=24,s=2,v=2,t=f,i=1", base64(url.path))
        #expect(result.contains("EBADF:Failed to read image file"))
        #expect(!result.contains("ENODATA"))
    }

    @Test func failedTemporaryFilesAreStillRemoved() {
        let url = scratchFile(Data(count: 3), protocolName: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = reply("a=t,f=24,s=2,v=2,t=t,i=1", base64(url.path))
        #expect(result.contains("EBADF"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func deviceFilesAreRefused() {
        #expect(reply("a=t,f=24,s=1,v=1,t=f,i=1", base64("/dev/zero")).contains("EBADF:Failed to read image file"))
    }

    @Test func badPNGDataIsReportedAsAPNGError() {
        #expect(reply("a=t,f=100,i=1", Data([1, 2, 3, 4, 5, 6, 7, 8]).base64EncodedString()).contains("EBADPNG:Not a PNG file"))
    }

    @Test func failedRetransmitDropsTheOldImage() {
        let rig = KittyRig()
        rig.feed(put("i=1,C=1"))
        rig.feed(apc("a=t,f=24,s=2,v=2,i=1", pixel))
        #expect(rig.images.isEmpty && rig.sources[1] == nil)
        rig.feed(apc("a=p,i=1"))
        #expect(rig.replies.contain("ENOENT:Put command refers to image with id: 1 that could not load its data"))
    }

    @Test func remainingChunksOfARejectedTransmitAreSwallowed() {
        let rig = KittyRig()
        rig.feed(apc("a=t,f=24,s=1,v=1,i=1,m=1", Data(count: 30).base64EncodedString()))
        rig.feed(apc("m=0", "AAAA"))
        #expect(rig.replies.lines.count == 1)
        #expect(rig.replies.contain("EFBIG"))
    }

    @Test func putOfAnUnknownImageUsesKittysMessage() {
        let rig = KittyRig()
        rig.feed(apc("a=p,i=9"))
        #expect(rig.replies.contain("i=9;ENOENT:Put command refers to non-existent image with id: 9 and number: 0"))
    }

    @Test func putWithoutAnIDOrNumberIsSilent() {
        let rig = KittyRig()
        rig.feed(apc("a=p"))
        #expect(rig.replies.lines.isEmpty)
        #expect(rig.images.isEmpty)
    }
}

struct KittyStorageTests {
    private let word = "AAAAAA=="

    private func transmitWord(_ id: Int, _ extra: String = "") -> [UInt8] {
        apc("a=t,f=32,s=1,v=1,i=\(id)\(extra)", word)
    }

    @Test func unreferencedImagesAreEvictedWhenTheLimitIsExceeded() {
        let rig = KittyRig(storageLimit: 10)
        rig.feed(transmitWord(1) + transmitWord(2))
        #expect(rig.engine.store.usedStorage == 8)
        rig.feed(transmitWord(3))
        #expect(rig.sources.keys.sorted() == [3])
    }

    @Test func referencedImagesAreEvictedOldestFirst() {
        let rig = KittyRig(storageLimit: 5)
        rig.feed(put("i=1,C=1"))
        rig.feed(transmitWord(2))
        #expect(rig.sources.keys.sorted() == [2])
        #expect(rig.images.isEmpty)
    }

    @Test func transientImagesGoFirst() {
        let rig = KittyRig(storageLimit: 5)
        rig.feed(put("i=1,C=1"))
        rig.feed(put("i=2,N=1,C=1"))
        #expect(rig.sources.keys.sorted() == [1])
        #expect(rig.images.map(\.kittyID) == [1])
    }

    @Test func imagesUnderTheLimitAreKept() {
        let rig = KittyRig()
        rig.feed(transmitWord(1) + transmitWord(2))
        #expect(rig.sources.keys.sorted() == [1, 2])
    }

    @Test func evictedImageCannotBePlacedAgain() {
        let rig = KittyRig(storageLimit: 5)
        rig.feed(transmitWord(1) + transmitWord(2))
        #expect(rig.sources[1] == nil)
        rig.feed(apc("a=p,i=1,C=1"))
        #expect(rig.replies.contain("i=1;ENOENT"))
        #expect(rig.images.isEmpty)
    }

    @Test func frameCacheIsBoundedAtFiveTimesTheLimit() {
        let rig = KittyRig(storageLimit: 16)
        let sixteen = String(repeating: "A", count: 22) + "=="
        rig.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", sixteen))
        for _ in 0..<4 { rig.feed(apc("a=f,f=32,s=2,v=2,i=1", sixteen)) }
        #expect(rig.sources[1]?.frames.count == 5)
        #expect(rig.engine.store.cacheSize == 80)
        rig.feed(apc("a=f,f=32,s=2,v=2,i=1", sixteen))
        #expect(rig.replies.contain("ENOSPC:Cache size exceeded cannot add new frames"))
        #expect(rig.sources[1]?.frames.count == 5)
    }
}

struct KittyByteAccountingTests {
    @Test func upToTenExtraRawBytesAreTrimmed() {
        let rig = KittyRig()
        rig.feed(apc("a=T,f=24,s=1,v=1,i=1,C=1", Data(count: 13).base64EncodedString()))
        #expect(rig.replies.contain("i=1;OK"))
        #expect(rig.images.count == 1)
    }

    @Test func rgbFramesCountThreeBytesPerPixel() {
        let rig = KittyRig()
        let twelve = Data(count: 12).base64EncodedString()
        rig.feed(apc("a=T,f=24,s=2,v=2,i=1,C=1", twelve))
        rig.feed(apc("a=f,f=24,s=2,v=2,i=1", twelve))
        #expect(rig.engine.store.usedStorage == 12)
        #expect(rig.engine.store.cacheSize == 24)
    }

    @Test func rgbaFramesCountFourBytesPerPixel() {
        let rig = KittyRig()
        let sixteen = Data(count: 16).base64EncodedString()
        rig.feed(apc("a=T,f=32,s=2,v=2,i=1,C=1", sixteen))
        rig.feed(apc("a=f,f=32,s=2,v=2,i=1", sixteen))
        #expect(rig.engine.store.usedStorage == 16)
        #expect(rig.engine.store.cacheSize == 32)
    }
}
