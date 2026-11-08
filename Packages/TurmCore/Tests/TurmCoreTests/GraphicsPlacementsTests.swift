import CoreGraphics
import Foundation
import Testing

@testable import TurmCore

private func solid() -> CGImage {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func place(
    _ id: UInt32, _ placementID: UInt32? = nil, row: Int = 0, column: Int = 0, columns: Int = 1, rows: Int = 1,
    z: Int = 0, parent: KittyParent? = nil
) -> GraphicsPlacement {
    var placement = GraphicsPlacement(source: .still(solid()), origin: GridPoint(row: row, column: column))
    placement.kittyID = id
    placement.placementID = placementID
    placement.fromKitty = true
    placement.columnSpan = columns
    placement.rowSpan = rows
    placement.zIndex = z
    placement.parent = parent
    return placement
}

private func screen(top: Int = 0) -> GraphicsScreen {
    GraphicsScreen(columns: 40, rows: 10, top: top, alternate: false, cellWidth: 8, cellHeight: 16, scale: 1)
}

private func command(_ target: Character?, x: Int? = nil, y: Int? = nil, z: Int = 0, i: UInt32? = nil, p: UInt32? = nil, n: UInt32? = nil) -> KittyCommand {
    var command = KittyCommand()
    command.action = "d"
    command.deleteTarget = target
    command.x = x
    command.y = y
    command.zIndex = z
    command.imageID = i
    command.placementID = p
    command.imageNumber = n
    return command
}

private func context(
    cursor: GridPoint = GridPoint(row: 0, column: 0), numbers: [UInt32: UInt32] = [:], virtual: Set<KittyKey> = []
) -> KittyDeleteContext {
    KittyDeleteContext(cursor: cursor, screen: screen(), numbers: numbers, virtualKeys: virtual)
}

private func ids(_ placements: [GraphicsPlacement]) -> [UInt32] {
    placements.compactMap(\.kittyID)
}

struct KittyDeleteVariantTests {
    private func scene() -> [GraphicsPlacement] {
        [
            place(1, row: 0, column: 0, columns: 2, rows: 1),
            place(2, row: 2, column: 4, columns: 2, rows: 2, z: -1),
            place(3, row: 5, column: 9, columns: 1, rows: 1, z: 5),
        ]
    }

    @Test func everyDeleteFormRemovesTheRightPlacements() {
        let cases: [(KittyCommand, [UInt32])] = [
            (command("p", x: 6, y: 4), [1, 3]),
            (command("P", x: 1, y: 1), [2, 3]),
            (command("x", x: 5), [1, 3]),
            (command("X", x: 10), [1, 2]),
            (command("y", y: 6), [1, 2]),
            (command("Y", y: 1), [2, 3]),
            (command("z", z: -1), [1, 3]),
            (command("Z", z: 5), [1, 2]),
            (command("q", x: 6, y: 4, z: -1), [1, 3]),
            (command("q", x: 6, y: 4, z: 0), [1, 2, 3]),
            (command("r", x: 2, y: 3), [1]),
            (command("R", x: 1, y: 1), [2, 3]),
            (command("i", i: 2), [1, 3]),
            (command("I", i: 2), [1, 3]),
            (command("a"), []),
            (command("A"), []),
            (command(nil), []),
        ]
        for (delete, remaining) in cases {
            var placements = scene()
            placements.applyKittyDelete(delete, context: context())
            #expect(ids(placements) == remaining, "\(String(describing: delete.deleteTarget))")
        }
    }

    @Test func deleteAtTheCursorRemovesPlacementsUnderIt() {
        var placements = scene()
        placements.applyKittyDelete(command("c"), context: context(cursor: GridPoint(row: 5, column: 9)))
        #expect(ids(placements) == [1, 2])
        placements.applyKittyDelete(command("C"), context: context(cursor: GridPoint(row: 8, column: 8)))
        #expect(ids(placements) == [1, 2])
    }

    @Test func deleteAllOnlyTouchesPlacementsOnTheScreen() {
        var placements = [place(1, row: 0), place(2, row: 12)]
        placements.applyKittyDelete(command("a"), context: context())
        #expect(ids(placements) == [2])
    }

    @Test func positionsAreRelativeToTheScreenTop() {
        var placements = [place(1, row: 20, column: 0), place(2, row: 22, column: 0)]
        var scrolled = context()
        scrolled.screen = screen(top: 20)
        placements.applyKittyDelete(command("y", y: 3), context: scrolled)
        #expect(ids(placements) == [1])
    }

    @Test func deletingOnePlacementKeepsTheOthers() {
        var placements = [place(1, 1), place(1, 2)]
        placements.applyKittyDelete(command("i", i: 1, p: 2), context: context())
        #expect(placements.map(\.placementID) == [1])
    }

    @Test func deleteByNumberUsesTheNumberMap() {
        var placements = [place(1), place(2)]
        placements.applyKittyDelete(command("n", n: 5), context: context(numbers: [5: 2]))
        #expect(ids(placements) == [1])
        placements.applyKittyDelete(command("n", n: 9), context: context(numbers: [5: 2]))
        #expect(ids(placements) == [1])
    }

    @Test func unknownTargetChangesNothing() {
        var placements = scene()
        placements.applyKittyDelete(command("w"), context: context())
        #expect(ids(placements) == [1, 2, 3])
    }

    @Test func nonKittyPlacementsAreNeverDeleted() {
        var inline = place(1)
        inline.fromKitty = false
        var placements = [inline]
        placements.applyKittyDelete(command("a"), context: context())
        #expect(placements.count == 1)
    }
}

struct KittyRelativePlacementTests {
    private func parentAndChild() -> [GraphicsPlacement] {
        [
            place(1, 1, row: 3, column: 5),
            place(2, 1, parent: KittyParent(imageID: 1, placementID: 1, columns: 2, rows: 1)),
        ]
    }

    @Test func childIsPositionedFromItsParent() {
        let placements = parentAndChild()
        #expect(placements.origin(of: placements[0]) == GridPoint(row: 3, column: 5))
        #expect(placements.origin(of: placements[1]) == GridPoint(row: 4, column: 7))
    }

    @Test func deletingTheParentDeletesTheChild() {
        var placements = parentAndChild()
        placements.applyKittyDelete(command("i", i: 1, p: 1), context: context())
        #expect(placements.isEmpty)
    }

    @Test func orphansAreRemovedRepeatedly() {
        var placements = parentAndChild()
        placements.append(place(3, 1, parent: KittyParent(imageID: 2, placementID: 1, columns: 0, rows: 0)))
        placements.removeFirst()
        placements.removeOrphans()
        #expect(placements.isEmpty)
    }

    @Test func cyclesAreRejected() {
        let placements = parentAndChild()
        #expect(placements.chainDepth(from: 2, 1, replacing: (1, 1)) == nil)
        #expect(placements.chainDepth(from: 2, 1, replacing: (nil, 0)) == 2)
    }

    @Test func missingParentIsNotAPlacement() {
        let placements = parentAndChild()
        #expect(placements.hasPlacement(1, 1))
        #expect(!placements.hasPlacement(9, 9))
    }

    @Test func childCanFollowAVirtualParent() {
        let child = place(7, 1, parent: KittyParent(imageID: 42, placementID: 0, columns: 1, rows: 1))
        let virtual = [KittyKey(imageID: 42, placementID: 0): GridPoint(row: 0, column: 0)]
        #expect([child].origin(of: child, virtual: virtual) == GridPoint(row: 1, column: 1))
        #expect([child].origin(of: child) == nil)
    }

    @Test func virtualParentKeepsTheChildOnlyWhileItExists() {
        let child = place(7, 1, parent: KittyParent(imageID: 42, placementID: 0, columns: 0, rows: 0))
        var placements = [child]
        placements.removeOrphans(keeping: [KittyKey(imageID: 42, placementID: 0)])
        #expect(placements.count == 1)
        placements.removeOrphans()
        #expect(placements.isEmpty)
    }

    @Test func chainsBeyondTheLimitAreTooDeep() {
        var placements = [place(1, 1)]
        for id in UInt32(2)...17 {
            placements.append(place(id, 1, parent: KittyParent(imageID: id - 1, placementID: 1, columns: 0, rows: 1)))
        }
        #expect(placements.chainDepth(from: 16, 1, replacing: (17, 1)) == 16)
        #expect((placements.chainDepth(from: 17, 1, replacing: (18, 1)) ?? 0) > KittyGeometry.maxChainDepth)
    }

    @Test func overlongChainsHaveNoOrigin() {
        var placements = [place(1, 1)]
        for id in UInt32(2)...19 {
            placements.append(place(id, 1, parent: KittyParent(imageID: id - 1, placementID: 1, columns: 0, rows: 1)))
        }
        #expect(placements.origin(of: placements[16]) == GridPoint(row: 16, column: 0))
        #expect(placements.origin(of: placements[17]) == nil)
    }
}

struct KittyGeometryTests {
    @Test func explicitGridIsKept() {
        let grid = KittyGeometry.grid(pixels: CGSize(width: 10, height: 10), columns: 3, rows: 2, cell: (8, 16), offset: .zero)
        #expect(grid.columns == 3 && grid.rows == 2)
    }

    @Test func missingRowsFollowTheAspectRatio() {
        let grid = KittyGeometry.grid(pixels: CGSize(width: 100, height: 50), columns: 5, rows: 0, cell: (10, 10), offset: .zero)
        #expect(grid.columns == 5 && grid.rows == 3)
    }

    @Test func missingColumnsFollowTheAspectRatio() {
        let grid = KittyGeometry.grid(pixels: CGSize(width: 100, height: 50), columns: 0, rows: 2, cell: (10, 10), offset: .zero)
        #expect(grid.columns == 4 && grid.rows == 2)
    }

    @Test func naturalSizeRoundsUpAndIncludesTheOffset() {
        let grid = KittyGeometry.grid(pixels: CGSize(width: 25, height: 10), columns: 0, rows: 0, cell: (10, 10), offset: CGSize(width: 6, height: 0))
        #expect(grid.columns == 4 && grid.rows == 1)
    }

    @Test func degenerateInputsStillGiveOneCell() {
        let grid = KittyGeometry.grid(pixels: .zero, columns: 0, rows: 0, cell: (0, 0), offset: .zero)
        #expect(grid.columns == 1 && grid.rows == 1)
    }

    @Test func offsetsStayInsideTheCell() {
        #expect(KittyGeometry.clampedOffset(100, -5, cell: (8, 16)) == CGSize(width: 7, height: 0))
        #expect(KittyGeometry.clampedOffset(3, 4, cell: (0, 0)) == CGSize(width: 0, height: 0))
    }
}

struct KittyVirtualDeleteCoreTests {
    private func makeStore() -> KittyImageStore {
        let store = KittyImageStore()
        store.virtualPlacements = [place(42, 3, z: -3), place(43, 4, z: 2)]
        store.sources[42] = KittyAnimation(root: solid())
        store.sources[43] = KittyAnimation(root: solid())
        return store
    }

    private func run(_ store: KittyImageStore, _ delete: KittyCommand) -> [KittyEviction] {
        store.deletePlacements(delete, cursor: GridPoint(row: 0, column: 0), screen: screen())
    }

    @Test func deleteAllRemovesVirtualPlacementsAndKeepsTheData() {
        let store = makeStore()
        #expect(run(store, command("a")).isEmpty)
        #expect(store.virtualPlacements.isEmpty)
        #expect(store.sources[42] != nil && store.sources[43] != nil)
    }

    @Test func uppercaseDeleteAllAlsoFreesTheData() {
        let store = makeStore()
        store.engineIDs[42] = 900
        let evicted = run(store, command("A"))
        #expect(store.virtualPlacements.isEmpty)
        #expect(store.sources[42] == nil && store.sources[43] == nil)
        #expect(Set(evicted.map(\.imageID)) == [42, 43])
        #expect(evicted.first { $0.imageID == 42 }?.engineID == 900)
    }

    @Test func deleteWithoutATargetRemovesVirtualPlacements() {
        let store = makeStore()
        _ = run(store, command(nil))
        #expect(store.virtualPlacements.isEmpty)
        #expect(store.sources.count == 2)
    }

    @Test func deleteByZIndexRemovesOnlyMatchingVirtualPlacements() {
        let store = makeStore()
        _ = run(store, command("z", z: -3))
        #expect(store.virtualPlacements.map(\.kittyID) == [43])
        _ = run(store, command("Z", z: 2))
        #expect(store.virtualPlacements.isEmpty)
        #expect(store.sources[43] == nil)
    }

    @Test func positionBasedDeletesLeaveVirtualPlacementsAlone() {
        let store = makeStore()
        let forms = [
            command("p", x: 1, y: 1), command("P", x: 1, y: 1), command("c"), command("x", x: 1),
            command("y", y: 1), command("q", x: 1, y: 1, z: -3),
        ]
        for delete in forms {
            _ = run(store, delete)
            #expect(store.virtualPlacements.count == 2, "\(String(describing: delete.deleteTarget))")
        }
    }

    @Test func deleteByIDAndRangeStillRemoveVirtualPlacements() {
        let store = makeStore()
        _ = run(store, command("i", i: 42, p: 3))
        #expect(store.virtualPlacements.map(\.kittyID) == [43])
        _ = run(store, command("r", x: 40, y: 50))
        #expect(store.virtualPlacements.isEmpty)
    }

    @Test func deletingTheVirtualParentDeletesTheChild() {
        let store = makeStore()
        store.images = [place(7, 1, parent: KittyParent(imageID: 42, placementID: 3, columns: 0, rows: 0))]
        _ = run(store, command("i", i: 42))
        #expect(store.images.isEmpty)
    }

    @Test func uppercaseDeleteByNumberFreesThePlacedImage() {
        let store = KittyImageStore()
        store.images = [place(1)]
        store.sources[1] = KittyAnimation(root: solid())
        store.imageNumbers[5] = 1
        _ = run(store, command("n", n: 5))
        #expect(store.images.isEmpty)
        #expect(store.sources[1] != nil)
        _ = run(store, command("N", n: 5))
        #expect(store.sources[1] == nil)
        #expect(store.imageNumbers.isEmpty)
    }

    @Test func uppercaseDeleteKeepsImagesThatStillHavePlacements() {
        let store = KittyImageStore()
        store.images = [place(1, 1), place(1, 2)]
        store.sources[1] = KittyAnimation(root: solid())
        _ = run(store, command("I", i: 1, p: 2))
        #expect(store.images.count == 1)
        #expect(store.sources[1] != nil)
    }
}

struct KittyImageStoreTests {
    private func makeStore(limit: Int, ids: [UInt32]) -> KittyImageStore {
        let store = KittyImageStore()
        store.storageLimit = limit
        for id in ids {
            store.sources[id] = KittyAnimation(root: solid())
            store.touch(id)
        }
        return store
    }

    @Test func storageCountsRootAndAllFrames() {
        let store = makeStore(limit: 100, ids: [1, 2])
        #expect(store.usedStorage == 8)
        store.sources[1]?.append(solid(), gap: 10)
        #expect(store.usedStorage == 8)
        #expect(store.cacheSize == 12)
    }

    @Test func quotaDropsUnplacedImagesExceptTheOneBeingStored() {
        let store = makeStore(limit: 5, ids: [3, 4])
        let evicted = store.applyQuota(keeping: 4)
        #expect(evicted.map(\.imageID) == [3])
        #expect(store.sources.keys.sorted() == [4])
    }

    @Test func quotaEvictsTheLeastRecentlyTouchedPlacedImage() {
        let store = makeStore(limit: 6, ids: [1, 2])
        store.images = [place(1), place(2)]
        store.touch(1)
        let evicted = store.applyQuota(keeping: nil)
        #expect(evicted.map(\.imageID) == [2])
        #expect(store.images.map(\.kittyID) == [1])
    }

    @Test func quotaEvictsTransientImagesFirst() {
        let store = makeStore(limit: 6, ids: [1, 2])
        store.images = [place(1), place(2)]
        store.sources[2]?.transient = true
        store.touch(2)
        #expect(store.applyQuota(keeping: nil).map(\.imageID) == [2])
    }

    @Test func quotaLeavesStoreAloneUnderTheLimit() {
        let store = makeStore(limit: 100, ids: [1, 2])
        store.images = [place(1), place(2)]
        #expect(store.applyQuota(keeping: nil).isEmpty)
        #expect(store.sources.count == 2)
    }

    @Test func evictionForgetsEverythingAboutTheImage() {
        let store = makeStore(limit: 100, ids: [1])
        store.images = [place(1), place(2, 1, parent: KittyParent(imageID: 1, placementID: 0, columns: 0, rows: 0))]
        store.virtualPlacements = [place(1, 9)]
        store.imageNumbers = [5: 1, 6: 2]
        store.unloaded = [1]
        store.engineIDs[1] = 77
        let eviction = store.evict(1)
        #expect(eviction == KittyEviction(imageID: 1, engineID: 77))
        #expect(store.images.isEmpty && store.virtualPlacements.isEmpty)
        #expect(store.sources.isEmpty && store.unloaded.isEmpty)
        #expect(store.imageNumbers == [6: 2])
        #expect(store.engineIDs.isEmpty)
    }

    @Test func frameCacheMakesRoomByDroppingUnplacedImages() {
        let store = makeStore(limit: 2, ids: [1, 2])
        store.images = [place(2)]
        let untouched = store.makeRoom(forFrameBytes: 2, keeping: 9)
        #expect(untouched.fits && untouched.evicted.isEmpty)
        let room = store.makeRoom(forFrameBytes: 4, keeping: 9)
        #expect(room.evicted.map(\.imageID) == [1])
        #expect(room.fits)
        let full = store.makeRoom(forFrameBytes: 100, keeping: 9)
        #expect(!full.fits)
    }

    @Test func internalIDsCountUp() {
        let store = KittyImageStore()
        let first = store.allocateInternalID()
        #expect(store.allocateInternalID() == first + 1)
    }

    @Test func resolvePrefersTheIDOverTheNumber() {
        let store = KittyImageStore()
        store.imageNumbers[3] = 8
        #expect(store.resolve(imageID: 5, imageNumber: 3) == 5)
        #expect(store.resolve(imageID: nil, imageNumber: 3) == 8)
        #expect(store.resolve(imageID: nil, imageNumber: 4) == nil)
    }

    @Test func placedIDsIncludeVirtualPlacementsButNotInlineImages() {
        let store = KittyImageStore()
        var inline = place(5)
        inline.fromKitty = false
        store.images = [place(1), inline]
        store.virtualPlacements = [place(2)]
        #expect(store.placedIDs() == [1, 2])
    }
}
