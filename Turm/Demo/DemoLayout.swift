#if DEBUG
import AppKit

enum DemoLayout {
    static let size = CGSize(width: 1280, height: 800)

    static func start() {
        seedDestinations()
        let turm = TerminalSession(directory: DemoHome.turm)
        let api = TerminalSession(directory: DemoHome.api)
        let infra = TerminalSession(directory: DemoHome.infra)
        let (left, top, bottom) = (PaneID(), PaneID(), PaneID())
        let layout = PaneNode.split(
            id: UUID(), axis: .horizontal, ratio: 0.55, first: .leaf(left),
            second: .split(id: UUID(), axis: .vertical, ratio: 0.5, first: .leaf(top), second: .leaf(bottom))
        )
        let shell = ShellTransfer(
            layout: layout, focusedPane: left, title: "turm", sessions: [left: turm, top: api, bottom: infra]
        )
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        WindowTransfer.shared.enqueue(shell, frame: frame)
        Task {
            await script(turm: turm, api: api, infra: infra)
            await finish()
        }
    }

    private static func seedDestinations() {
        let simulators = [
            XcodeDestination(
                kind: .iPhone, platform: "iOS", name: "iPhone 17 Pro", id: "6B1F0C52-3D8E-4C1A-9E57-0A4D7B2E91C3",
                isSimulator: true, isBooted: true, os: "27.0"
            ),
            XcodeDestination(
                kind: .iPhone, platform: "iOS", name: "iPhone 17", id: "A94E3B10-77C2-4F0D-8B6A-5E1C2D9F4A28",
                isSimulator: true, os: "27.0"
            ),
            XcodeDestination(
                kind: .iPad, platform: "iOS", name: "iPad Pro 13-inch (M5)", id: "0D5C8E71-2A94-4B3F-A1E6-93B7F4C2D860",
                isSimulator: true, os: "27.0"
            ),
        ]
        let cache = DestinationCache.shared
        cache.store(XcodeDestinations.sorted([XcodeDestination.mac] + simulators))
        keepSimctlFromRefreshing(cache)
    }

    private static func script(turm: TerminalSession, api: TerminalSession, infra: TerminalSession) async {
        async let first: Void = play(["swift test", "git log --oneline -3"], in: turm, waitsForGit: true)
        async let second: Void = play(["npm run build"], in: api, waitsForGit: true)
        async let third: Void = play(["terraform plan"], in: infra, waitsForGit: false)
        _ = await (first, second, third)
        await until { turm.phase == .ready && infra.phase == .ready && api.phase == .running }
        try? await Task.sleep(for: .seconds(1))
    }

    private static func play(_ commands: [String], in session: TerminalSession, waitsForGit: Bool) async {
        if waitsForGit { await until { session.git != nil } }
        for command in commands {
            await until { session.phase == .ready }
            session.submitWhenReady(command)
        }
    }

    private static func finish() async {
        await until { window != nil }
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        hideCaretAndInputIndicator(in: window)
        try? await Task.sleep(for: .seconds(1))
        mark("window-id", "\(window.windowNumber)")
        mark("ready", "")
    }

    private static func keepSimctlFromRefreshing(_ cache: DestinationCache) {
        _ = cache.beginRefresh()
    }

    private static func hideCaretAndInputIndicator(in window: NSWindow) {
        window.makeFirstResponder(nil)
        window.childWindows?.forEach { $0.orderOut(nil) }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private static func until(timeout: Duration = .seconds(30), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func mark(_ name: String, _ text: String) {
        try? text.write(toFile: DemoHome.root + "/" + name, atomically: true, encoding: .utf8)
    }
}
#endif
