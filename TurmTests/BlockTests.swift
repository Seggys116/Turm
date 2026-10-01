import Foundation
import SwiftTerm
import Testing
import TurmCore
@testable import Turm

private func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

private func collect(_ parser: inout ShellStreamParser, _ chunks: [[UInt8]]) -> [StreamPiece] {
    chunks.flatMap { parser.consume($0) }
}

private func joinedOutput(_ pieces: [StreamPiece]) -> [UInt8] {
    pieces.flatMap { piece -> [UInt8] in
        if case .output(let data) = piece { return data }
        return []
    }
}

struct ShellStreamParserTests {
    @Test func plainBytesPassThrough() {
        var parser = ShellStreamParser()
        #expect(parser.consume(bytes("hello\r\n")) == [.output(bytes("hello\r\n"))])
    }

    @Test func extractsCommandStartAndPrompt() {
        var parser = ShellStreamParser()
        let input = "a\u{1B}]7777;C\u{07}b\u{1B}]7777;P;0;/tmp/x y\u{07}"
        #expect(parser.consume(bytes(input)) == [
            .output(bytes("a")),
            .event(.commandStarted),
            .output(bytes("b")),
            .event(.promptReady(exitCode: 0, directory: "/tmp/x y")),
        ])
    }

    @Test func emptyExitCodeMeansNoPreviousCommand() {
        var parser = ShellStreamParser()
        #expect(parser.consume(bytes("\u{1B}]7777;P;;/home\u{07}")) == [
            .event(.promptReady(exitCode: nil, directory: "/home")),
        ])
    }

    @Test func directoryMayContainSemicolons() {
        var parser = ShellStreamParser()
        #expect(parser.consume(bytes("\u{1B}]7777;P;2;/a;b\u{07}")) == [
            .event(.promptReady(exitCode: 2, directory: "/a;b")),
        ])
    }

    @Test func acceptsStringTerminator() {
        var parser = ShellStreamParser()
        #expect(parser.consume(bytes("\u{1B}]7777;C\u{1B}\\")) == [.event(.commandStarted)])
    }

    @Test func foreignSequencesAreForwardedIntact() {
        var parser = ShellStreamParser()
        let input = "\u{1B}]0;title\u{07}\u{1B}[31mred\u{1B}[0m"
        #expect(joinedOutput(parser.consume(bytes(input))) == bytes(input))
    }

    @Test(arguments: 1...20)
    func chunkBoundariesDoNotMatter(split: Int) {
        let input = bytes("x\u{1B}]7777;C\u{07}y\u{1B}]7777;P;1;/d\u{07}z")
        var parser = ShellStreamParser()
        let cut = min(split, input.count)
        let pieces = collect(&parser, [Array(input[..<cut]), Array(input[cut...])])
        #expect(pieces.filter { if case .event = $0 { return true } else { return false } } == [
            .event(.commandStarted),
            .event(.promptReady(exitCode: 1, directory: "/d")),
        ])
        #expect(joinedOutput(pieces) == bytes("xyz"))
    }
}

struct GitInspectorTests {
    @Test func sumsNumstat() {
        let text = "10\t2\ta.swift\n-\t-\timage.png\n5\t0\tb.swift\n"
        let totals = GitInspector.parseNumstat(text)
        #expect(totals.files == 3)
        #expect(totals.added == 15)
        #expect(totals.removed == 2)
    }

    @Test func emptyDiff() {
        let totals = GitInspector.parseNumstat("")
        #expect(totals.files == 0 && totals.added == 0 && totals.removed == 0)
    }
}

struct CommandHistoryTests {
    @Test func parsesExtendedHistoryAndDeduplicates() {
        let text = ": 1700000000:0;ls\n: 1700000001:0;cd /tmp\n: 1700000002:0;ls\n"
        #expect(CommandHistory.parseZsh(text) == ["cd /tmp", "ls"])
    }

    @Test func joinsContinuationLines() {
        let text = ": 1:0;echo one\\\ntwo\nplain\n"
        #expect(CommandHistory.parseZsh(text) == ["echo one\ntwo", "plain"])
    }

    @Test func recordMovesRepeatToEnd() {
        let history = CommandHistory(entries: ["a", "b"])
        history.record("a")
        #expect(history.entries == ["b", "a"])
    }
}

struct BlockFormattingTests {
    @Test func formatsDurations() {
        #expect(Block.formatDuration(.milliseconds(27)) == "0.027s")
        #expect(Block.formatDuration(.milliseconds(10_780)) == "10.78s")
        #expect(Block.formatDuration(.milliseconds(128_350)) == "2m 8.35s")
    }

    @Test func abbreviatesHome() {
        let home = NSHomeDirectory()
        #expect(Block.abbreviate(home) == "~")
        #expect(Block.abbreviate(home + "/Projects") == "~/Projects")
        #expect(Block.abbreviate("/usr/bin") == "/usr/bin")
    }
}

struct PathCompleterTests {
    private func makeDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "turm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path + "/alpha", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path + "/zeta", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/alphabet.txt", contents: nil)
        FileManager.default.createFile(atPath: path + "/my file.txt", contents: nil)
        FileManager.default.createFile(atPath: path + "/.hidden", contents: nil)
        return path
    }

    @Test func extendsToCommonPrefix() throws {
        let dir = try makeDirectory()
        let result = try #require(PathCompleter.complete("cat al", directory: dir))
        #expect(result.replacement == "alpha")
        #expect(String("cat al"[result.range]) == "al")
    }

    @Test func uniqueDirectoryGetsSlash() throws {
        let dir = try makeDirectory()
        let result = try #require(PathCompleter.complete("cd ze", directory: dir))
        #expect(result.replacement == "zeta/")
    }

    @Test func escapesSpaces() throws {
        let dir = try makeDirectory()
        let result = try #require(PathCompleter.complete("open my", directory: dir))
        #expect(result.replacement == "my\\ file.txt")
    }

    @Test func hiddenFilesNeedDotPrefix() throws {
        let dir = try makeDirectory()
        #expect(PathCompleter.complete("ls ", directory: dir) == nil)
        #expect(try #require(PathCompleter.complete("ls .h", directory: dir)).replacement == ".hidden")
    }

    @Test func noMatchReturnsNil() throws {
        let dir = try makeDirectory()
        #expect(PathCompleter.complete("cat zzz", directory: dir) == nil)
    }
}

struct BlockEmulatorTests {
    @Test func rendersTextAndColours() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(bytes("plain\r\n\u{1B}[31mred\u{1B}[0m\r\n"))
        let text = String(emulator.render().characters)
        #expect(text == "plain\nred")
    }

    @Test func keepsScrollbackBeyondVisibleRows() {
        let emulator = BlockEmulator(cols: 40, rows: 5)
        emulator.feed(bytes((1...50).map { "line \($0)\r\n" }.joined()))
        let lines = String(emulator.render().characters).split(separator: "\n")
        #expect(lines.count == 50)
        #expect(lines.first == "line 1")
        #expect(lines.last == "line 50")
    }

    @Test func carriageReturnOverwrites() {
        let emulator = BlockEmulator(cols: 40, rows: 5)
        emulator.feed(bytes("10%\r50%\r100%\r\n"))
        #expect(String(emulator.render().characters) == "100%")
    }

    @Test func detectsAlternateScreen() {
        let emulator = BlockEmulator(cols: 40, rows: 5)
        #expect(!emulator.isAlternate)
        emulator.feed(bytes("\u{1B}[?1049h"))
        #expect(emulator.isAlternate)
        emulator.feed(bytes("\u{1B}[?1049l"))
        #expect(!emulator.isAlternate)
    }
}

@MainActor
@Suite(.serialized)
struct TerminalSessionTests {
    private func wait(timeout: Duration = .seconds(20), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func runsCommandsAsBlocks() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })

        session.submit("echo hello; false")
        #expect(await wait { session.phase == .ready && session.blocks.first?.isRunning == false })
        let first = try #require(session.blocks.first)
        #expect(first.plainOutput == "hello")
        #expect(first.exitCode == 1)

        session.submit("cd /tmp && pwd")
        #expect(await wait { session.blocks.count == 2 && session.phase == .ready })
        #expect(session.blocks[1].exitCode == 0)
        #expect(session.blocks[1].plainOutput.hasSuffix("/tmp"))
        #expect(session.directory.hasSuffix("/tmp"))
    }

    @Test func eachPaneRecallsOnlyItsOwnCommands() async throws {
        let first = TerminalSession()
        let second = TerminalSession()
        defer {
            first.terminate()
            second.terminate()
        }
        #expect(await wait { first.phase == .ready && second.phase == .ready })
        let marker = "echo pane-history-\(UUID().uuidString)"
        first.submit(marker)
        #expect(await wait { first.phase == .ready && first.blocks.count == 1 })

        #expect(first.history.entries.last == marker)
        #expect(!second.history.entries.contains(marker))
        #expect(CommandHistory.shared.entries.contains(marker))
        let later = TerminalSession()
        defer { later.terminate() }
        #expect(later.history.entries.contains(marker))
    }

    @Test func multiLineCommandRunsAsOneBlock() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })
        session.submit("for i in 1 2\ndo echo n$i\ndone")
        #expect(await wait { session.blocks.first?.isRunning == false })
        #expect(session.blocks.first?.plainOutput == "n1\nn2")
        #expect(session.blocks.count == 1)
    }

    @Test func forwardsInputToRunningCommand() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })
        session.submit("read line; echo got:$line")
        #expect(await wait { session.phase == .running })
        session.sendInput(Array("abc\r".utf8))
        #expect(await wait { session.blocks.first?.isRunning == false })
        #expect(session.blocks.first?.plainOutput.contains("got:abc") == true)
    }

    @Test func interruptStopsRunningCommand() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })
        session.submit("sleep 30")
        #expect(await wait { session.phase == .running })
        session.interrupt()
        #expect(await wait { session.blocks.first?.isRunning == false })
        #expect(session.blocks.first?.exitCode == 130)
    }

    private func output(of command: String) async throws -> String {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })
        session.submit(command)
        #expect(await wait { session.blocks.first?.isRunning == false })
        return try #require(session.blocks.first).plainOutput
    }

    @Test func programsSeeTheGhosttyIdentity() async throws {
        let text = try await output(of: #"printf '%s\n' "$TERM_PROGRAM $TERM_PROGRAM_VERSION $COLORTERM $TERM""#)
        #expect(text == "ghostty \(TerminalIdentity.version) truecolor xterm-256color")
    }

    @Test func versionQueryIsAnsweredWithTheIdentity() async throws {
        let text = try await output(of: #"printf '\e[>0q'; read -rs -t 3 -d '\\' reply; printf '%s\n' "${reply//$'\e'/ESC}""#)
        #expect(text.contains("ESCP>|\(TerminalIdentity.xtVersion)ESC"))
    }

    @Test func colorSchemeQueryIsAnswered() async throws {
        let text = try await output(of: #"printf '\e[?996n'; read -rs -t 3 -d n reply; printf '%s\n' "${reply//$'\e'/ESC}""#)
        #expect(text.contains("ESC[?997;1"))
    }

    @Test func capabilityQueryIsAnswered() async throws {
        let text = try await output(of: #"printf '\eP+q436F\e\\'; read -rs -t 3 -d '\\' reply; printf '%s\n' "${reply//$'\e'/ESC}""#)
        #expect(text.contains("ESCP1+r436F=323536"))
    }

    @Test func colorSchemeModeReportsAreRewritten() async throws {
        let text = try await output(of: #"printf '\e[?2031$p'; read -rs -t 3 -d y reply; printf '%s\n' "${reply//$'\e'/ESC}""#)
        #expect(text.contains("ESC[?2031;2$"))
    }

    @Test func alternateScreenHandsOverAndBack() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await wait { session.phase == .ready })
        session.submit("printf '\\033[?1049hinside'; sleep 2; printf '\\033[?1049l'; echo after")
        #expect(await wait { session.altScreen != nil })
        #expect(await wait { session.altScreen == nil && session.blocks.first?.isRunning == false })
        #expect(session.blocks.first?.plainOutput.contains("after") == true)
    }
}

struct AltScreenSequenceTests {
    @Test func findsEnterAndExit() {
        let enter = Array("ab\u{1B}[?1049hcd".utf8)
        #expect(AltScreenSequence.firstSwitch(in: enter[...], entering: true) == 10)
        #expect(AltScreenSequence.firstSwitch(in: enter[...], entering: false) == nil)
        let exit = Array("\u{1B}[?1049l".utf8)
        #expect(AltScreenSequence.firstSwitch(in: exit[...], entering: false) == exit.count)
    }

    @Test func ignoresUnrelatedPrivateModes() {
        let bytes = Array("\u{1B}[?25h\u{1B}[?2004h".utf8)
        #expect(AltScreenSequence.firstSwitch(in: bytes[...], entering: true) == nil)
    }

    @Test func acceptsCombinedParameters() {
        let bytes = Array("\u{1B}[?1;1049h".utf8)
        #expect(AltScreenSequence.firstSwitch(in: bytes[...], entering: true) == bytes.count)
    }
}

struct InputModelTests {
    @Test func attachingAddsEscapedPathAndThumbnailForImages() {
        let model = InputModel()
        model.draft = "open"
        let image = URL(fileURLWithPath: "/tmp/my shot.png")
        model.attach([image, URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(model.draft == "open /tmp/my\\ shot.png /tmp/notes.txt ")
        #expect(model.attachments == [image])
    }

    @Test func removingDropsThePathFromTheDraft() {
        let model = InputModel()
        let image = URL(fileURLWithPath: "/tmp/a.png")
        model.attach([image])
        model.remove(image)
        #expect(model.draft.isEmpty)
        #expect(model.attachments.isEmpty)
    }
}

struct ResponseFilterTests {
    @Test func replacesVersionReply() {
        let original = Array("\u{1B}P>|SwiftTerm 1.20.0+v1.20.0:\u{1B}\\".utf8)
        #expect(ResponseFilter.rewrite(original) == Array("\u{1B}P>|\(TerminalIdentity.xtVersion)\u{1B}\\".utf8))
    }

    @Test func leavesOtherInputAlone() {
        let keys = Array("ls -la\r".utf8)
        #expect(ResponseFilter.rewrite(keys) == keys)
        let deviceAttributes = Array("\u{1B}[?65;4c".utf8)
        #expect(ResponseFilter.rewrite(deviceAttributes) == deviceAttributes)
    }
}

struct NotificationParsingTests {
    @Test func extractsOsc777AndOsc9AndKeepsBytes() {
        var parser = ShellStreamParser()
        let osc777 = "\u{1B}]777;notify;Build;done; ok\u{07}"
        let pieces = parser.consume(Array(osc777.utf8))
        #expect(pieces.contains(.event(.notification(title: "Build", body: "done; ok"))))
        #expect(joinedOutput(pieces) == Array(osc777.utf8))

        var second = ShellStreamParser()
        let osc9 = "\u{1B}]9;hello\u{07}"
        #expect(second.consume(Array(osc9.utf8)).contains(.event(.notification(title: "", body: "hello"))))
    }

    @Test func progressReportsAreNotNotifications() {
        var parser = ShellStreamParser()
        let pieces = parser.consume(Array("\u{1B}]9;4;1;50\u{07}".utf8))
        #expect(!pieces.contains { if case .event = $0 { return true } else { return false } })
    }
}

struct InlineImageTests {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func imageSequence() -> [UInt8] {
        Array("\u{1B}]1337;File=inline=1:\(Self.png)\u{07}".utf8)
    }

    @Test func imagesInNormalOutputAreKept() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(imageSequence())
        #expect(emulator.images.count == 1)
    }

    @Test func imagesDrawnOnTheAlternateScreenAreDiscarded() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(Array("before\r\n".utf8))
        emulator.feed(Array("\u{1B}[?1049h".utf8))
        emulator.feed(imageSequence())
        emulator.feed(Array("\u{1B}[?1049l".utf8))
        #expect(emulator.images.isEmpty)
        #expect(emulator.renderSegments().allSatisfy { if case .image = $0 { return false } else { return true } })
    }
}

struct TerminalRequestTests {
    @Test func scansModesQueriesAndCapabilities() {
        let text = "\u{1B}[?2031h\u{1B}[?1004;2004h\u{1B}[?996n\u{1B}P+q544e;524742\u{1B}\\\u{1B}[?2031l"
        let requests = TerminalRequestScanner.scan(Array(text.utf8)[...])
        #expect(requests == [
            .privateMode(2031, enabled: true),
            .privateMode(1004, enabled: true),
            .privateMode(2004, enabled: true),
            .colorSchemeQuery,
            .capabilities(["TN", "RGB"]),
            .privateMode(2031, enabled: false),
        ])
    }

    @Test func ignoresOrdinarySequences() {
        let text = "\u{1B}[31mred\u{1B}[0m\u{1B}[2J\u{1B}[H"
        #expect(TerminalRequestScanner.scan(Array(text.utf8)[...]).isEmpty)
    }

    @Test func repliesMatchTheProtocol() {
        #expect(TerminalReply.colorScheme(dark: true) == Array("\u{1B}[?997;1n".utf8))
        #expect(TerminalReply.colorScheme(dark: false) == Array("\u{1B}[?997;2n".utf8))
        #expect(TerminalReply.capability("Co") == Array("\u{1B}P1+r436F=323536\u{1B}\\".utf8))
        #expect(TerminalReply.capability("Tc") == Array("\u{1B}P1+r5463\u{1B}\\".utf8))
        #expect(TerminalReply.capability("nonsense") == Array("\u{1B}P0+r\u{1B}\\".utf8))
    }

    @Test func modeReportIsRewrittenToRealState() {
        let unsupported = Array("\u{1B}[?2031;0$y".utf8)
        #expect(ResponseFilter.rewrite(unsupported, colorSchemeReporting: true) == Array("\u{1B}[?2031;1$y".utf8))
        #expect(ResponseFilter.rewrite(unsupported, colorSchemeReporting: false) == Array("\u{1B}[?2031;2$y".utf8))
    }
}

struct KeyEncoderTests {
    private func key(_ code: UInt16, _ chars: String = "", _ plain: String? = nil,
                     shift: Bool = false, control: Bool = false, option: Bool = false) -> KeyInput {
        KeyInput(keyCode: code, characters: chars, unmodified: plain ?? chars, shift: shift, control: control, option: option)
    }

    private func text(_ bytes: [UInt8]?) -> String {
        String(decoding: bytes ?? [], as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "ESC")
    }

    @Test func legacyKeys() {
        let modes = KeyModes()
        #expect(text(KeyEncoder.encode(key(126), modes: modes)) == "ESC[A")
        #expect(text(KeyEncoder.encode(key(126, control: true), modes: modes)) == "ESC[1;5A")
        #expect(text(KeyEncoder.encode(key(117), modes: modes)) == "ESC[3~")
        #expect(text(KeyEncoder.encode(key(36), modes: modes)) == "\r")
        #expect(text(KeyEncoder.encode(key(48, shift: true), modes: modes)) == "ESC[Z")
        #expect(text(KeyEncoder.encode(key(0, "a"), modes: modes)) == "a")
        #expect(text(KeyEncoder.encode(key(8, "\u{03}", "c", control: true), modes: modes)) == "\u{03}")
        #expect(text(KeyEncoder.encode(key(11, "∫", "b", option: true), modes: modes)) == "ESCb")
    }

    @Test func applicationCursorMode() {
        let modes = KeyModes(applicationCursor: true)
        #expect(text(KeyEncoder.encode(key(125), modes: modes)) == "ESCOB")
        #expect(text(KeyEncoder.encode(key(125, shift: true), modes: modes)) == "ESC[1;2B")
    }

    @Test func kittyDisambiguate() {
        let modes = KeyModes(kittyFlags: 1)
        #expect(text(KeyEncoder.encode(key(53), modes: modes)) == "ESC[27u")
        #expect(text(KeyEncoder.encode(key(36, shift: true), modes: modes)) == "ESC[13;2u")
        #expect(text(KeyEncoder.encode(key(36), modes: modes)) == "\r")
        #expect(text(KeyEncoder.encode(key(8, "\u{03}", "c", control: true), modes: modes)) == "ESC[99;5u")
        #expect(text(KeyEncoder.encode(key(0, "a"), modes: modes)) == "a")
    }

    @Test func kittyReportAllKeys() {
        let modes = KeyModes(kittyFlags: 1 | 8)
        #expect(text(KeyEncoder.encode(key(0, "a"), modes: modes)) == "ESC[97u")
        #expect(text(KeyEncoder.encode(key(0, "A", "a", shift: true), modes: modes)) == "ESC[97;2u")
        #expect(text(KeyEncoder.encode(key(36), modes: modes)) == "ESC[13u")
    }
}

struct KittyGraphicsTests {
    private let png = "AAAA"

    private func place(id: Int, columns: Int? = nil, rows: Int? = nil) -> [UInt8] {
        var keys = "a=T,f=24,s=1,v=1,i=\(id)"
        if let columns { keys += ",c=\(columns)" }
        if let rows { keys += ",r=\(rows)" }
        return Array("\u{1B}_G\(keys);\(png)\u{1B}\\".utf8)
    }

    @Test func parsesControlData() {
        let command = KittyGraphicsScanner.parse(Array("a=T,i=7,c=10,r=4,m=1".utf8)[...])
        #expect(command.action == "T" && command.imageID == 7 && command.columns == 10 && command.rows == 4 && command.more)
        let delete = KittyGraphicsScanner.parse(Array("a=d,d=i,i=7".utf8)[...])
        #expect(delete.deletesByID && !delete.deletesAll)
        #expect(KittyGraphicsScanner.parse(Array("a=d".utf8)[...]).deletesAll)
    }

    @Test func placementRecordsIdAndCellSize() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(place(id: 7, columns: 10, rows: 4))
        #expect(emulator.images.count == 1)
        #expect(emulator.images[0].kittyID == 7)
        guard case .cells(let width) = emulator.images[0].width, case .cells(let height) = emulator.images[0].height else {
            Issue.record("placement should request a size in cells")
            return
        }
        #expect(width == 10)
        #expect(height == 4)
    }

    @Test func deleteByIdRemovesOnlyThatImage() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(place(id: 1))
        emulator.feed(place(id: 2))
        emulator.feed(Array("\u{1B}_Ga=d,d=i,i=1\u{1B}\\".utf8))
        #expect(emulator.images.map(\.kittyID) == [2])
    }

    @Test func deleteAllRemovesEveryKittyImage() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(place(id: 1) + place(id: 2) + Array("\u{1B}_Ga=d\u{1B}\\".utf8))
        #expect(emulator.images.isEmpty)
    }

    @Test func imagePlacedAndDeletedInOneChunkIsGone() {
        let emulator = BlockEmulator(cols: 40, rows: 10)
        emulator.feed(place(id: 3) + Array("\u{1B}_Ga=d,d=I,i=3\u{1B}\\".utf8))
        #expect(emulator.images.isEmpty)
    }
}

struct ShellEnvironmentTests {
    @Test func identityVariablesOfOtherTerminalsAreDropped() {
        for key in ["VSCODE_GIT_IPC_HANDLE", "ITERM_SESSION_ID", "KITTY_WINDOW_ID", "WEZTERM_VERSION",
                    "TERM_PROGRAM", "TERMINAL_EMULATOR", "TMUX", "TERM_SESSION_ID", "__CFBundleIdentifier"] {
            #expect(ShellIntegration.isTerminalIdentity(key), "\(key) should be dropped")
        }
    }

    @Test func ordinaryVariablesAreKept() {
        for key in ["PATH", "HOME", "LANG", "EDITOR", "SSH_AUTH_SOCK", "TERMINFO"] {
            #expect(!ShellIntegration.isTerminalIdentity(key), "\(key) should be kept")
        }
    }
}
