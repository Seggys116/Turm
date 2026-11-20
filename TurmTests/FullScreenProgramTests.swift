import AppKit
import SwiftTerm
import SwiftUI
import Testing
import TurmCore
@testable import Turm

/// A full-screen pane inside a window that is never shown, redrawn only through the window's own display pass. Unlike
/// `RenderRig.snapshot()`, nothing forces a full repaint, so a capture shows what the screen would show after the
/// partial repaints real programs cause: a program that edits one line must leave every other line drawn.
@MainActor
private final class WindowedPane {
    let rig: RenderRig
    let window: NSWindow

    init(cols: Int = 40, rows: Int = 12) {
        rig = RenderRig(cols: cols, rows: rows)
        let size = rig.container.frame.size
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = rig.container
        rig.container.setFrameSize(size)
        // the view keeps room for a scroller, so widen the pane until the grid is the size the recordings were made at
        let cell = rig.host.cellPoints
        var width = size.width
        while rig.host.grid.cols < cols, width < size.width + 8 * cell.width {
            width += cell.width
            window.setContentSize(NSSize(width: width, height: size.height))
            rig.container.setFrameSize(NSSize(width: width, height: size.height))
        }
        settle()
    }

    /// Feeds the bytes and waits for the redraw SwiftTerm schedules on the main queue, then runs the display pass.
    func feed(_ text: String) async {
        rig.feed(text)
        try? await Task.sleep(for: .milliseconds(150))
        settle()
    }

    /// Runs the display pass a window runs before the screen updates.
    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        rig.host.view.layer?.displayIfNeeded()
        CATransaction.flush()
    }

    /// The share of a cell range's pixels that differ from the pane's background, composited the way the window
    /// shows the pane: the background fill, the images under the text, the text layer and the images above it.
    func ink(row: Int, columns: ClosedRange<Int>) -> Double {
        let view = rig.host.view
        let scale: CGFloat = 2
        let width = max(Int(view.bounds.width * scale), 1), height = max(Int(view.bounds.height * scale), 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.scaleBy(x: scale, y: scale)
        for layer in [view.graphicsBackdrop.layer, view.layer, view.graphicsOverlay.layer].compactMap({ $0 }) {
            layer.render(in: context)
        }
        let background = Theme.terminalBackground.resolved(dark: true).usingColorSpace(.sRGB)!
        let base = (Int(background.redComponent * 255), Int(background.greenComponent * 255), Int(background.blueComponent * 255))
        let cell = rig.host.cellPoints
        let top = Int(CGFloat(row) * cell.height * scale), bottom = Int(CGFloat(row + 1) * cell.height * scale)
        let left = Int(CGFloat(columns.lowerBound) * cell.width * scale), right = Int(CGFloat(columns.upperBound + 1) * cell.width * scale)
        var drawn = 0, total = 0
        for y in max(top, 0)..<min(bottom, height) {
            for x in max(left, 0)..<min(right, width) {
                total += 1
                let index = (y * width + x) * 4
                let differs = abs(Int(pixels[index]) - base.0) + abs(Int(pixels[index + 1]) - base.1) + abs(Int(pixels[index + 2]) - base.2)
                if differs > 60 { drawn += 1 }
            }
        }
        return total == 0 ? 0 : Double(drawn) / Double(total)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
struct FullScreenProgramTests {
    /// GNU nano 9.2 opening a three-line file in a 40x12 terminal, then typing X, moving down and typing Y, then asking
    /// to quit, as recorded through a pseudo-terminal with TERM=xterm-256color.
    private static let nano = [
        "\u{1B}[?2004h\u{1B}[?1049h\u{1B}[22;0;0t\u{1B}[1;12r\u{1B}(B\u{1B}[m\u{1B}[4l\u{1B}[?7h\u{1B}[39;49m\u{1B}[?1h\u{1B}=\u{1B}[?1h\u{1B}=\u{1B}[?25l\u{1B}[39;49m\u{1B}(B\u{1B}[m\u{1B}[H\u{1B}[2J\u{1B}[10;14H\u{1B}(B\u{1B}[0;7m[ Reading... ]\u{1B}(B\u{1B}[m\u{1B}[10;13H\u{1B}(B\u{1B}[0;7m[ Read 3 lines ]\u{1B}(B\u{1B}[m\u{1B}[H\u{1B}(B\u{1B}[0;7m  GNU nano 9.2   sample.txt             \u{1B}[1;39H\u{1B}(B\u{1B}[m\r\u{1B}[11d\u{1B}(B\u{1B}[0;7m^G\u{1B}(B\u{1B}[m Help   \u{1B}(B\u{1B}[0;7m^O\u{1B}(B\u{1B}[m Write O\u{1B}(B\u{1B}[0;7m^F\u{1B}(B\u{1B}[m Where I\u{1B}(B\u{1B}[0;7m^K\u{1B}(B\u{1B}[m Cut\r\u{1B}[12d\u{1B}(B\u{1B}[0;7m^X\u{1B}(B\u{1B}[m Exit   \u{1B}(B\u{1B}[0;7m^R\u{1B}(B\u{1B}[m Read Fi\u{1B}(B\u{1B}[0;7m^\\\u{1B}(B\u{1B}[m Replace\u{1B}(B\u{1B}[0;7m^U\u{1B}(B\u{1B}[m Paste\r\u{1B}[2dline one\r\u{1B}[3dline two\r\u{1B}[4dline three\r\u{1B}[2d\u{1B}[?12l\u{1B}[?25h",
        "\u{1B}[?25l\u{1B}[1;31H\u{1B}(B\u{1B}[0;7mModified\u{1B}(B\u{1B}[m\u{1B}[?12l\u{1B}[?25h\r\u{1B}[2dXline one\rX",
        "\u{1B}[?25l\u{1B}[?12l\u{1B}[?25h\u{1B}[3d",
        "\u{1B}[?25l\u{1B}[?12l\u{1B}[?25hYine two\rlY",
        "\u{1B}[?25l\r\u{1B}[10d\u{1B}(B\u{1B}[0;7mSave modified buffer?                   \u{1B}[11;1H Y\u{1B}(B\u{1B}[m Yes\u{1B}[K\r\u{1B}[12d\u{1B}(B\u{1B}[0;7m N\u{1B}(B\u{1B}[m No           \u{1B}(B\u{1B}[0;7m^C\u{1B}(B\u{1B}[m Cancel\u{1B}[K\u{1B}[10;23H\u{1B}[?12l\u{1B}[?25h",
    ]

    @Test func nanoStaysDrawnThroughEveryStep() async {
        let pane = WindowedPane()
        defer { pane.close() }
        #expect(pane.rig.host.grid.cols == 40 && pane.rig.host.grid.rows == 12, "\(pane.rig.host.grid)")
        for (step, bytes) in Self.nano.enumerated() {
            await pane.feed(bytes)
            // the title bar, the untouched third line and the shortcut bar must be on screen after every step
            #expect(pane.ink(row: 0, columns: 2...12) > 0.3, "title bar blank after step \(step)")
            #expect(pane.ink(row: 3, columns: 0...9) > 0.03, "\"line three\" blank after step \(step)")
            #expect(pane.ink(row: 11, columns: 0...1) > 0.3, "shortcut bar blank after step \(step)")
        }
    }

    @Test func editingOneLineLeavesTheOthersDrawn() async {
        let pane = WindowedPane()
        defer { pane.close() }
        await pane.feed("\u{1B}[H\u{1B}[2J" + (1...12).map { "\u{1B}[\($0);1Hrow \($0) text" }.joined())
        #expect(pane.ink(row: 5, columns: 0...9) > 0.03)
        await pane.feed("\u{1B}[1;1HX")
        await pane.feed("\u{1B}[?25l\u{1B}[?25h")
        for row in 0..<12 {
            #expect(pane.ink(row: row, columns: 0...9) > 0.03, "row \(row) blank after a one-cell edit")
        }
    }

    @Test func aFullRepaintStillShowsEverything() async {
        let pane = WindowedPane()
        defer { pane.close() }
        await pane.feed("\u{1B}[H\u{1B}[2J" + (1...12).map { "\u{1B}[\($0);1Hrow \($0) text" }.joined())
        pane.rig.host.view.needsDisplay = true
        pane.settle()
        for row in 0..<12 {
            #expect(pane.ink(row: row, columns: 0...9) > 0.03, "row \(row) blank after a full repaint")
        }
    }
}

// MARK: - Real programs in a real pane

/// A real session in the real pane view, inside a window that is never shown. The window's display pass runs on
/// demand, so what the pane would put on screen can be read back at any moment without anything appearing.
@MainActor
private final class LivePane {
    let session = TerminalSession()
    let window: NSWindow
    let folder: URL
    /// Everything the shell printed, kept to explain a session that never becomes ready.
    private var output: [UInt8] = []

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("turm-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = (1...200).map { "line \($0) of the sample file" }.joined(separator: "\n") + "\n"
        try lines.write(to: folder.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: TerminalPaneView(session: session, isFocused: true).frame(width: 640, height: 400))
        session.companionTap = { [weak self] event in
            if case .output(_, let bytes) = event { self?.output.append(contentsOf: bytes) }
        }
    }

    /// Waits for the shell's first prompt, and on failure says what the shell printed instead.
    func ready(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let ready = await wait { session.phase == .ready }
        let printed = String(decoding: output.suffix(600), as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "^[")
        #expect(ready, "shell not ready: phase \(session.phase), failure \(session.failure ?? "none"), printed: \(printed)", sourceLocation: sourceLocation)
        return ready
    }

    var sample: String { folder.appendingPathComponent("sample.txt").path }

    /// Lays out and draws the window the way the next screen update would.
    func pump() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// Keeps the window updating while waiting. Other suites can hold the main actor for a long while on a busy
    /// runner, so the deadline is generous.
    func wait(_ timeout: Duration = .seconds(120), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        // a stall can swallow the whole deadline, so a few checks are always made after it has passed
        var late = 0
        while ContinuousClock.now < deadline || late < 10 {
            if ContinuousClock.now >= deadline { late += 1 }
            pump()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(late > 0 ? 200 : 50))
        }
        pump()
        return condition()
    }

    /// The full-screen view's visible rows.
    var screen: [String] {
        guard let terminal = session.altScreen?.view.getTerminal() else { return [] }
        return (0..<terminal.rows).map { row in
            (0..<terminal.cols).map { column in terminal.getCharData(col: column, row: row).map { String($0.getCharacter()) } ?? " " }
                .joined().replacingOccurrences(of: "\u{0}", with: " ")
        }
    }

    var filledRows: Int {
        screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// The share of the window's pixels that differ from the pane's background, as the window would show them.
    func drawnShare() -> Double {
        guard let layer = window.contentView?.layer else { return 0 }
        let width = 640, height = 400
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        layer.render(in: context)
        let background = Theme.terminalBackground.resolved(dark: true).usingColorSpace(.sRGB)!
        let base = (Int(background.redComponent * 255), Int(background.greenComponent * 255), Int(background.blueComponent * 255))
        var drawn = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let differs = abs(Int(pixels[index]) - base.0) + abs(Int(pixels[index + 1]) - base.1) + abs(Int(pixels[index + 2]) - base.2)
            if differs > 60 { drawn += 1 }
        }
        return Double(drawn) / Double(width * height)
    }

    func type(_ text: String) {
        session.altScreen?.onInput(Array(text.utf8))
    }

    func close() {
        session.terminate()
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// One at a time: each test runs a shell and a window, and a busy runner starting many at once can starve them.
@MainActor
@Suite(.serialized)
struct LiveFullScreenProgramTests {
    struct Program: CustomTestStringConvertible, Sendable {
        let name: String
        let paths: [String]
        let arguments: String
        /// Text the program's first screen must show.
        let shows: String
        let quit: String

        var path: String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }
        var testDescription: String { name }
    }

    static let programs: [Program] = [
        Program(name: "nano", paths: ["/opt/homebrew/bin/nano", "/usr/local/bin/nano"], arguments: "SAMPLE", shows: "line 1 of", quit: "\u{18}"),
        Program(name: "pico", paths: ["/usr/bin/pico"], arguments: "SAMPLE", shows: "line 1 of", quit: "\u{18}"),
        Program(name: "vim", paths: ["/usr/bin/vim", "/opt/homebrew/bin/vim"], arguments: "-u NONE -N SAMPLE", shows: "line 1 of", quit: "\u{1B}:q!\r"),
        Program(name: "less", paths: ["/usr/bin/less"], arguments: "SAMPLE", shows: "line 1 of", quit: "q"),
        Program(name: "top", paths: ["/usr/bin/top"], arguments: "-s 1", shows: "Processes", quit: "q"),
        Program(name: "htop", paths: ["/opt/homebrew/bin/htop", "/usr/local/bin/htop"], arguments: "", shows: "Load average", quit: "q"),
    ]

    static let installed = programs.filter { $0.path != nil }

    /// Each program opens in the full-screen view, stays drawn in every frame for two seconds, takes a key, and on
    /// quitting hands the pane back to the block list.
    @Test(arguments: installed)
    func staysDrawnAndQuitsCleanly(_ program: Program) async throws {
        let pane = try LivePane()
        defer { pane.close() }
        guard await pane.ready() else { return }
        let path = try #require(program.path)
        // LESS and similar settings from the user's shell would change what the pager does with a short file
        pane.session.submit("env -u LESS -u LESSOPEN '\(path)' " + program.arguments.replacingOccurrences(of: "SAMPLE", with: "'\(pane.sample)'"))
        #expect(await pane.wait { pane.screen.contains { $0.contains(program.shows) } }, "\(program.name) never drew its first screen: \(pane.screen)")

        var blankFrames: [Int] = []
        for frame in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            pane.pump()
            if pane.session.altScreen == nil || pane.filledRows < 3 || pane.drawnShare() < 0.01 { blankFrames.append(frame) }
        }
        // every program is resized once as the full-screen view takes over, and a frame can catch that one repaint
        // half done; a resize loop instead leaves the pane blank most of the time and never settles
        #expect(blankFrames.count <= 4, "\(program.name) left the pane blank in frames \(blankFrames)")
        #expect(!blankFrames.contains { $0 >= 15 }, "\(program.name) had not settled: blank in frames \(blankFrames)")
        let view = try #require(pane.session.altScreen?.view)
        // text drawn below the window's scale is upscaled and blurry
        #expect(view.layer?.contentsScale == pane.window.backingScaleFactor, "\(program.name) text layer is at \(view.layer?.contentsScale ?? 0)x")

        pane.type(program.quit)
        #expect(await pane.wait { pane.session.altScreen == nil && pane.session.blocks.last?.isRunning == false }, "\(program.name) did not hand the pane back")
    }

    /// The pane's two views measure different grids, so a program that redraws on every resize the ncurses way, by
    /// leaving and re-entering the alternate screen, must not be resized again by that redraw.
    @Test func redrawingOnResizeDoesNotStartAResizeLoop() async throws {
        let pane = try LivePane()
        defer { pane.close() }
        let script = pane.folder.appendingPathComponent("redraw.sh")
        try #"""
        n=0
        trap 'n=$((n+1)); printf "\033[?1049l\033[?1049h\033[H\033[2Jredrawn %d\r\nsecond row\r\nthird row" "$n"' WINCH
        printf '\033[?1049h\033[H\033[2Jstarted\r\nsecond row\r\nthird row'
        i=0
        while [ ! -e "$1" ] && [ $i -lt 3000 ]; do sleep 0.1; i=$((i+1)); done
        printf '\033[?1049l'
        echo "resizes=$n"
        """#.write(to: script, atomically: true, encoding: .utf8)
        guard await pane.ready() else { return }
        // the script runs until told to stop, so a runner that stalls the main actor cannot end it early
        let stop = pane.folder.appendingPathComponent("stop")
        pane.session.submit("bash '\(script.path)' '\(stop.path)'")
        #expect(await pane.wait { pane.session.altScreen != nil && pane.filledRows >= 3 })
        var blankFrames = 0
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            pane.pump()
            if pane.filledRows < 3 { blankFrames += 1 }
        }
        try Data().write(to: stop)
        #expect(await pane.wait { pane.session.blocks.last?.isRunning == false })
        let output = pane.session.blocks.last?.plainOutput ?? ""
        let resizes = output.split(separator: "\n").first { $0.hasPrefix("resizes=") }.flatMap { Int($0.dropFirst("resizes=".count)) }
        #expect(resizes != nil, "\(output)")
        #expect((resizes ?? 99) <= 2, "the program was resized \(resizes ?? -1) times")
        #expect(blankFrames <= 1, "the pane was blank in \(blankFrames) of 20 frames")
        #expect(pane.session.altScreen == nil)
    }

    /// A program that leaves the alternate screen for good, such as an editor shelling out, gets the block list
    /// back shortly after, even while it keeps running.
    @Test func leavingTheAlternateScreenForGoodClosesTheFullScreenView() async throws {
        let pane = try LivePane()
        defer { pane.close() }
        guard await pane.ready() else { return }
        let stop = pane.folder.appendingPathComponent("stop").path
        pane.session.submit(#"printf '\033[?1049hfull screen\r\nrow two\r\nrow three'; sleep 1; printf '\033[?1049l'; echo back; i=0; while [ ! -e '"# + stop + #"' ] && [ $i -lt 3000 ]; do sleep 0.1; i=$((i+1)); done"#)
        #expect(await pane.wait { pane.session.altScreen != nil })
        #expect(await pane.wait { pane.session.altScreen == nil })
        #expect(pane.session.blocks.last?.isRunning == true)
        try Data().write(to: URL(fileURLWithPath: stop))
        #expect(await pane.wait { pane.session.blocks.last?.isRunning == false })
    }
}
