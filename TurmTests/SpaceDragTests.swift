import CoreGraphics
import Foundation
import Testing
import TurmCore
@testable import Turm

@MainActor
@Suite(.serialized)
struct SpaceDragTests {
    init() {
        WorkspacePersistence.allowsDiskOverride = false
        WorkspacePersistence.storeOverride = WorkspaceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("turm-space-drag-\(UUID().uuidString)"))
    }

    private func makeWorkspace(shells: Int) -> Workspace {
        let workspace = Workspace(closeCoordinator: CloseCoordinator { _ in true })
        for _ in 1..<shells { workspace.newShell() }
        return workspace
    }

    private func openLibrary() throws -> (library: SpaceLibrary, host: WindowHost, workspace: Workspace) {
        let library = SpaceLibrary()
        let host = WindowHost()
        library.claim(host)
        let id = try #require(host.spaceID)
        let workspace = try #require(library.record(id)?.workspace)
        return (library, host, workspace)
    }

    private func makeDrag(home: UUID, others: [UUID: CGRect]) -> TileDrag {
        let drag = TileDrag()
        drag.windowBounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        drag.sidebarFrame = CGRect(x: 0, y: 0, width: 240, height: 600)
        drag.gridFrame = CGRect(x: 250, y: 0, width: 650, height: 600)
        drag.spaceBarFrame = CGRect(x: 0, y: 560, width: 240, height: 40)
        drag.homeSpace = { home }
        drag.canMoveToSpace = { _ in true }
        for (id, frame) in others { drag.setSpaceFrame(id, frame) }
        return drag
    }

    @Test func holdingAShellOverAnotherSpaceTargetsThatSpace() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let home = UUID()
        let other = UUID()
        let drag = makeDrag(home: home, others: [home: CGRect(x: 4, y: 564, width: 28, height: 28), other: CGRect(x: 36, y: 564, width: 28, height: 28)])
        drag.begin(.tab(workspace.tabs[1].id), title: "", in: workspace)

        drag.move(to: CGPoint(x: 50, y: 575), in: workspace)

        #expect(drag.spaceTarget == other)
        #expect(drag.drop == nil)
        #expect(!drag.breaksOut)
        #expect(!drag.tearsOff)
    }

    @Test func theSpaceTheWindowAlreadyShowsIsNotATarget() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let home = UUID()
        let drag = makeDrag(home: home, others: [home: CGRect(x: 4, y: 564, width: 28, height: 28)])
        drag.begin(.tab(workspace.tabs[1].id), title: "", in: workspace)

        drag.move(to: CGPoint(x: 10, y: 575), in: workspace)

        #expect(drag.spaceTarget == nil)
    }

    @Test func aSpaceButtonScrolledOutOfTheBarIsNotATarget() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let other = UUID()
        let drag = makeDrag(home: UUID(), others: [other: CGRect(x: 300, y: 564, width: 28, height: 28)])
        drag.begin(.tab(workspace.tabs[1].id), title: "", in: workspace)

        drag.move(to: CGPoint(x: 310, y: 575), in: workspace)

        #expect(drag.spaceTarget == nil)
    }

    @Test func aPaneOverASpaceMovesInsteadOfBreakingOutIntoTheSidebar() {
        let workspace = makeWorkspace(shells: 1)
        defer { workspace.terminateAll() }
        workspace.split(.horizontal)
        let pane = workspace.focusedPane
        let other = UUID()
        let drag = makeDrag(home: UUID(), others: [other: CGRect(x: 36, y: 564, width: 28, height: 28)])
        drag.begin(.pane(pane), title: "", in: workspace)

        drag.move(to: CGPoint(x: 50, y: 575), in: workspace)

        #expect(drag.spaceTarget == other)
        #expect(!drag.breaksOut)
    }

    @Test func releasingOverASpaceHandsTheItemToThatSpace() {
        let workspace = makeWorkspace(shells: 2)
        defer { workspace.terminateAll() }
        let other = UUID()
        let drag = makeDrag(home: UUID(), others: [other: CGRect(x: 36, y: 564, width: 28, height: 28)])
        var moved: (TileItem, UUID)?
        drag.moveToSpace = { item, id in
            moved = (item, id)
            return true
        }
        let item = TileItem.tab(workspace.tabs[1].id)
        drag.begin(item, title: "", in: workspace)
        drag.move(to: CGPoint(x: 50, y: 575), in: workspace)

        #expect(drag.end(in: workspace))

        #expect(moved?.0 == item)
        #expect(moved?.1 == other)
        #expect(!drag.isActive)
        #expect(drag.spaceTarget == nil)
    }

    @Test func aShellWithNowhereToGoIsNotOfferedASpace() {
        let workspace = makeWorkspace(shells: 1)
        defer { workspace.terminateAll() }
        let other = UUID()
        let drag = makeDrag(home: UUID(), others: [other: CGRect(x: 36, y: 564, width: 28, height: 28)])
        drag.canMoveToSpace = { workspace.canTearOff($0) }
        drag.begin(.tab(workspace.tabs[0].id), title: "", in: workspace)

        drag.move(to: CGPoint(x: 50, y: 575), in: workspace)

        #expect(drag.spaceTarget == nil)
    }

    @Test func aShellMovedToAnotherSpaceLeavesTheFirstAndLandsInTheSecond() throws {
        let (library, _, first) = try openLibrary()
        first.newShell()
        library.create(in: WindowHost(), name: "Second")
        let target = try #require(library.records.first { $0.name == "Second" })
        defer {
            first.terminateAll()
            library.records.forEach { $0.workspace?.terminateAll() }
        }
        let moving = first.tabs[1].id

        let shell = try #require(first.release(.tab(moving)))
        library.receive(shell, in: target.id)

        #expect(first.tabs.count == 1)
        #expect(!first.tabs.contains { $0.id == moving })
        #expect(library.record(target.id)?.workspace?.tabs.count == 2)
    }

    @Test func aShellTornOutOfTheWindowJoinsTmpInsteadOfMakingASpace() throws {
        let (library, _, source) = try openLibrary()
        source.newShell()
        defer {
            source.terminateAll()
            library.records.forEach { $0.workspace?.terminateAll() }
            while WindowTransfer.shared.take() != nil {}
        }
        let spacesBefore = library.records.count
        let tmp = try #require(library.records.first { $0.isTemporary })
        let tmpShells = tmp.workspace?.tabs.count ?? 0
        let shell = try #require(source.release(.tab(source.tabs[1].id)))

        let alreadyShown = library.park(shell, frame: CGRect(x: 10, y: 10, width: 400, height: 300))

        #expect(!alreadyShown)
        #expect(library.records.count == spacesBefore)
        #expect(library.temporaryWorkspace?.tabs.count == tmpShells + 1)
        let pending = try #require(WindowTransfer.shared.take())
        #expect(pending.spaceID == tmp.id)
        #expect(pending.shell == nil)
    }

    @Test func aWindowAlreadyShowingTmpReceivesTheShellWithoutANewWindow() throws {
        let (library, tmpHost, source) = try openLibrary()
        let tmp = try #require(library.records.first { $0.isTemporary })
        source.newShell()
        let shown = try #require(library.record(tmp.id)?.workspace)
        library.activate(tmp.id, in: tmpHost)
        defer { shown.terminateAll() }
        defer {
            source.terminateAll()
            library.records.forEach { $0.workspace?.terminateAll() }
            while WindowTransfer.shared.take() != nil {}
        }
        let shell = try #require(source.release(.tab(source.tabs[1].id)))

        let alreadyShown = library.park(shell, frame: .zero)

        #expect(alreadyShown)
        #expect(WindowTransfer.shared.take() == nil)
    }
}

@MainActor
struct SidebarHoverGroupTests {
    @Test func enteringAnotherRowReleasesTheOneStillMarkedHovered() {
        let group = HoverGroup()
        var released: [String] = []
        group.update("a", inside: true) { released.append("a") }
        group.update("b", inside: true) { released.append("b") }
        group.update("c", inside: true) { released.append("c") }

        #expect(released == ["a", "b"])
    }

    @Test func leavingARowDoesNotReleaseTheOneThatReplacedIt() {
        let group = HoverGroup()
        var firstReleased = 0
        var secondReleased = 0
        group.update("a", inside: true) { firstReleased += 1 }
        group.update("b", inside: true) { secondReleased += 1 }
        group.update("a", inside: false) { firstReleased += 1 }

        #expect(firstReleased == 1)
        #expect(secondReleased == 0)
    }

    @Test func theEdgeStripEndsHalfwayThroughTheBezel() {
        #expect(ChromeMetrics.sidebarHoverEdgeWidth == ChromeMetrics.cardInset)
    }
}
