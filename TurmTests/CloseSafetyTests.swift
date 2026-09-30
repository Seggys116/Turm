import AppKit
import Testing
@testable import Turm

@MainActor
@Suite(.serialized)
struct CloseSafetyTests {
    private func wait(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func idleShellClosesWithoutConfirmation() async throws {
        var requests: [CloseRequest] = []
        let workspace = Workspace(closeCoordinator: CloseCoordinator {
            requests.append($0)
            return false
        })
        defer { workspace.terminateAll() }
        let pane = workspace.focusedPane
        let session = try #require(workspace.session(for: pane))
        try #require(await wait { session.phase == .ready && !session.hasRunningJobs })
        var emptyCount = 0
        workspace.onEmpty = { emptyCount += 1 }

        workspace.closeFocused()
        workspace.closeFocused()

        #expect(requests.isEmpty)
        #expect(workspace.session(for: pane) == nil)
        #expect(!session.isOpen)
        #expect(emptyCount == 1)
    }

    @Test func cancellingBusyShellPreservesJobLayoutAndFocus() async throws {
        var requests: [CloseRequest] = []
        let workspace = Workspace(closeCoordinator: CloseCoordinator {
            requests.append($0)
            return false
        })
        defer { workspace.terminateAll() }
        let pane = workspace.focusedPane
        let session = try #require(workspace.session(for: pane))
        try #require(await wait { session.phase == .ready })
        session.submit("sleep 30")
        try #require(await wait { session.phase == .running })
        let layout = workspace.layout

        workspace.closeFocused()

        #expect(requests == [.shell])
        #expect(workspace.layout == layout)
        #expect(workspace.focusedPane == pane)
        #expect(workspace.session(for: pane) === session)
        #expect(session.isOpen && session.hasRunningJobs)
    }

    @Test func confirmingCloseOnlyRemovesTheRequestedPane() async throws {
        var requests: [CloseRequest] = []
        let workspace = Workspace(closeCoordinator: CloseCoordinator {
            requests.append($0)
            return true
        })
        defer { workspace.terminateAll() }
        let first = workspace.focusedPane
        workspace.split(.horizontal)
        let second = workspace.focusedPane
        let session = try #require(workspace.session(for: second))
        try #require(await wait { session.phase == .ready })
        session.submit("sleep 30")
        // Submitted commands need protection even before the preexec event arrives.
        workspace.closeFocused()

        #expect(requests == [.shell])
        #expect(workspace.layout.leaves == [first])
        #expect(workspace.focusedPane == first)
        #expect(!session.isOpen)
        #expect(workspace.session(for: first)?.isOpen == true)
    }

    @Test func detectsBackgroundJobsAfterPromptReturns() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        try #require(await wait { session.phase == .ready })
        session.submit("sleep 30 &")
        try #require(await wait { session.phase == .ready })

        #expect(!session.isRunning)
        #expect(session.hasRunningJobs)

        session.submit("kill $!; wait")
        try #require(await wait { session.phase == .ready && !session.hasRunningJobs })
        #expect(!session.hasRunningJobs)
    }

    @Test func detectsSuspendedJobsAfterPromptReturns() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        try #require(await wait { session.phase == .ready })
        session.submit("sleep 30")
        try #require(await wait { session.phase == .running })
        session.sendInput([0x1A])
        try #require(await wait { session.phase == .ready })

        #expect(!session.isRunning)
        #expect(session.hasRunningJobs)

        session.submit("kill -KILL %1; wait")
        try #require(await wait { session.phase == .ready && !session.hasRunningJobs })
    }

    @Test func naturalShellExitDoesNotAskForConfirmation() async throws {
        var requests: [CloseRequest] = []
        let workspace = Workspace(closeCoordinator: CloseCoordinator {
            requests.append($0)
            return false
        })
        defer { workspace.terminateAll() }
        let session = try #require(workspace.session(for: workspace.focusedPane))
        try #require(await wait { session.phase == .ready })
        var emptied = false
        workspace.onEmpty = { emptied = true }

        session.submit("exit")
        try #require(await wait { emptied })

        #expect(requests.isEmpty)
        #expect(workspace.openShellCount == 0)
        #expect(!session.hasRunningJobs)
        #expect(workspace.shouldCloseWindow())
    }

    @Test func blankShellsAreExcludedFromEveryCloseCheck() async throws {
        var requests: [CloseRequest] = []
        let coordinator = CloseCoordinator {
            requests.append($0)
            return false
        }
        let workspace = Workspace(closeCoordinator: coordinator)
        defer { coordinator.terminateAll() }

        // A newly opened shell is excluded even before its first prompt arrives.
        #expect(workspace.shouldCloseWindow())
        #expect(coordinator.shouldQuit())
        workspace.split(.horizontal)
        let newPane = workspace.focusedPane
        workspace.closeFocused()
        #expect(workspace.session(for: newPane) == nil)

        let session = try #require(workspace.focusedSession)
        try #require(await wait { session.phase == .ready })
        session.submit(" \n\t ")
        #expect(!session.hasSubmittedCommand)
        #expect(workspace.shouldCloseWindow())
        #expect(coordinator.shouldQuit())
        workspace.closeFocused()
        #expect(!session.isOpen)
        #expect(requests.isEmpty)
    }

    @Test func clearingOutputDoesNotMakeAUsedShellBlank() async throws {
        var requests: [CloseRequest] = []
        let coordinator = CloseCoordinator {
            requests.append($0)
            return false
        }
        let workspace = Workspace(closeCoordinator: coordinator)
        defer { coordinator.terminateAll() }
        let session = try #require(workspace.focusedSession)
        try #require(await wait { session.phase == .ready })
        session.submit(":")
        try #require(await wait { session.phase == .ready })
        session.clearBlocks()

        #expect(session.blocks.isEmpty)
        #expect(session.hasSubmittedCommand)
        #expect(!workspace.shouldCloseWindow())
        #expect(!coordinator.shouldQuit())
        #expect(requests == [.window(shellCount: 1), .application(shellCount: 1)])
    }

    @Test func windowAndQuitConfirmationsCountOnlyUsedShells() async throws {
        var requests: [CloseRequest] = []
        var accepted = false
        let coordinator = CloseCoordinator {
            requests.append($0)
            return accepted
        }
        let first = Workspace(closeCoordinator: coordinator)
        let second = Workspace(closeCoordinator: coordinator)
        defer { coordinator.terminateAll() }
        first.split(.vertical)
        let secondSession = try #require(second.focusedSession)
        let sessions = try first.layout.leaves.map { try #require(first.session(for: $0)) }
            + [secondSession]
        for session in sessions {
            try #require(await wait { session.phase == .ready })
            session.submit(":")
            try #require(await wait { session.phase == .ready })
        }
        first.split(.horizontal)

        #expect(!first.shouldCloseWindow())
        #expect(!coordinator.shouldQuit())
        #expect(first.openShellCount == 3)
        #expect(first.shellsRequiringConfirmationCount == 2)
        #expect(second.openShellCount == 1)
        #expect(requests == [.window(shellCount: 2), .application(shellCount: 3)])

        accepted = true
        #expect(first.shouldCloseWindow())
        first.terminateAll()
        #expect(coordinator.shouldQuit())
        #expect(requests.last == .application(shellCount: 1))
        coordinator.terminateAll()
        let requestCount = requests.count
        #expect(coordinator.shouldQuit())
        #expect(requests.count == requestCount)
    }

    @Test func reentrantCloseDoesNotCreateAnotherConfirmation() {
        var coordinator: CloseCoordinator!
        var count = 0
        coordinator = CloseCoordinator { _ in
            count += 1
            #expect(!coordinator.confirm(.shell))
            return false
        }
        #expect(!coordinator.confirm(.shell))
        #expect(count == 1)
    }

    @Test func windowGuardPreservesDelegateAndTerminatesOnlyItsWorkspace() async throws {
        let coordinator = CloseCoordinator { _ in false }
        let workspace = Workspace(closeCoordinator: coordinator)
        let other = Workspace(closeCoordinator: coordinator)
        defer { coordinator.terminateAll() }
        let session = try #require(workspace.focusedSession)
        try #require(await wait { session.phase == .ready })
        session.submit(":")
        try #require(await wait { session.phase == .ready })
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let delegate = OriginalWindowDelegate()
        window.delegate = delegate
        let guardView = WindowCloseView(workspace: workspace)
        window.contentView = guardView

        #expect(window.delegate === guardView)
        #expect(!guardView.windowShouldClose(window))
        #expect(delegate.closeChecks == 1)
        #expect(workspace.openShellCount == 1)

        guardView.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(workspace.openShellCount == 0)
        #expect(other.openShellCount == 1)
        #expect(delegate.closeNotifications == 1)
        guardView.detach()
        #expect(window.delegate === delegate)
    }
}

@MainActor
private final class OriginalWindowDelegate: NSObject, NSWindowDelegate {
    var closeChecks = 0
    var closeNotifications = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeChecks += 1
        return true
    }

    func windowWillClose(_ notification: Notification) {
        closeNotifications += 1
    }
}

@MainActor
struct HiddenTabFocusTests {
    @Test func aShellInAHiddenTabCannotPullItsTabToTheFront() throws {
        let coordinator = CloseCoordinator { _ in false }
        let workspace = Workspace(closeCoordinator: coordinator)
        defer { coordinator.terminateAll() }
        let shell = try #require(workspace.focusedSession)
        let pane = workspace.focusedPane
        workspace.openSettings()
        let settings = workspace.activeTabID

        shell.focus()
        #expect(workspace.activeTabID == settings)

        workspace.focus(pane)
        #expect(workspace.activeTabID != settings)
    }
}

struct FinderExtensionListingTests {
    @Test func readsTheElectedStateFromPluginkit() {
        #expect(ContextMenuService.isEnabled(inListing: "+    com.example.FinderSync(1.3.0)\n"))
        #expect(!ContextMenuService.isEnabled(inListing: "-    com.example.FinderSync(1.3.0)\n"))
        #expect(!ContextMenuService.isEnabled(inListing: "     com.example.FinderSync(1.3.0)\n"))
        #expect(!ContextMenuService.isEnabled(inListing: ""))
    }
}
