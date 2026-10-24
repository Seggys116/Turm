import Foundation
import Testing
@testable import TurmCore

struct SpaceCatalogTests {
    @Test func anOlderFileWithoutSpacesBecomesOneSpacePerWindow() throws {
        let windowID = UUID()
        let tabID = UUID()
        let paneID = UUID()
        let window = SavedWindow(
            id: windowID, frame: SavedFrame(x: 1, y: 2, width: 3, height: 4),
            tabs: [SavedTab(id: tabID, title: "Dev", layout: .leaf(paneID), focusedPane: paneID)],
            activeTabID: tabID,
            panes: [SavedPane(id: paneID, content: .shell(SavedShell(directory: "/work", shell: .zsh, history: [])))]
        )
        let modern = try JSONEncoder().encode(WorkspaceDocument(windows: [window], keyWindowID: windowID))
        var object = try #require(JSONSerialization.jsonObject(with: modern) as? [String: Any])
        object.removeValue(forKey: "spaces")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: legacy)
        #expect(document.spaces.isEmpty)
        let catalog = document.spaceCatalog
        #expect(catalog.count == 1)
        #expect(catalog[0].id == windowID)
        #expect(catalog[0].name == "Dev")
        #expect(catalog[0].session.panes.count == 1)
        #expect(document.space(forKey: windowID)?.name == "Dev")
    }

    @Test func explicitSpacesRoundTripAndWinOverWindows() throws {
        let sessionID = UUID()
        let otherID = UUID()
        let tabID = UUID()
        let paneID = UUID()
        let session = SavedWindow(
            id: sessionID, frame: nil,
            tabs: [SavedTab(id: tabID, title: nil, layout: .leaf(paneID), focusedPane: paneID)],
            activeTabID: tabID,
            panes: [SavedPane(id: paneID, content: .shell(SavedShell(directory: "/tmp", shell: .zsh, history: [])))]
        )
        let space = SavedSpace(id: sessionID, name: "API", symbol: "hammer", session: session)
        let leftover = SavedWindow(id: otherID, frame: nil, tabs: [], activeTabID: UUID(), panes: [])
        let document = WorkspaceDocument(windows: [leftover], keyWindowID: sessionID, spaces: [space])
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
        #expect(decoded.spaceCatalog.map(\.name) == ["API"])
        #expect(decoded.removingWindow(sessionID).spaces.isEmpty)
        #expect(decoded.removingWindow(otherID).spaces.map(\.name) == ["API"])
    }

    @Test func aTemporarySpaceIsDroppedAndDoesNotBecomeTheNextLaunch() {
        let keptID = UUID()
        let tempID = UUID()
        let tab = UUID()
        let pane = UUID()
        func window(_ id: UUID, directory: String) -> SavedWindow {
            SavedWindow(
                id: id, frame: nil,
                tabs: [SavedTab(id: tab, title: nil, layout: .leaf(pane), focusedPane: pane)],
                activeTabID: tab,
                panes: [SavedPane(id: pane, content: .shell(SavedShell(directory: directory, shell: .zsh, history: ["ls"])))]
            )
        }
        let kept = SavedSpace(id: keptID, name: "Dev", symbol: "hammer", session: window(keptID, directory: "/work"))
        let temp = SavedSpace(
            id: tempID, name: SavedSpace.temporaryName, symbol: SavedSpace.temporarySymbol,
            session: window(tempID, directory: "/tmp"), isTemporary: true
        )
        let document = WorkspaceDocument(windows: [window(keptID, directory: "/work"), window(tempID, directory: "/tmp")], keyWindowID: tempID, spaces: [temp, kept])
        let discarded = document.discardingTemporarySpaces()
        #expect(discarded.spaces.map(\.name) == ["Dev"])
        #expect(discarded.windows.map(\.id) == [keptID])
        #expect(discarded.keyWindowID == keptID)
        #expect(discarded.spaceCatalog.map(\.name) == ["Dev"])
    }

    @Test func aWindowWithoutATitleIsNumbered() {
        let id = UUID()
        let tab = UUID()
        let pane = UUID()
        let window = SavedWindow(
            id: id, frame: nil,
            tabs: [SavedTab(id: tab, title: "  ", layout: .leaf(pane), focusedPane: pane)],
            activeTabID: tab, panes: []
        )
        let document = WorkspaceDocument(windows: [window], keyWindowID: nil)
        #expect(document.spaceCatalog.map(\.name) == ["Space 1"])
        #expect(document.space(forKey: nil)?.id == id)
    }
}
