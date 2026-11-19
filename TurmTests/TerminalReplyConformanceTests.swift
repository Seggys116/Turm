import Foundation
import SwiftTerm
import Testing
import TurmCore
@testable import Turm

@MainActor
private func conformanceWait(timeout: Duration = .seconds(60), until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// Sends each query from a real shell in a real session and checks the reply programs rely on to detect features.
@MainActor
struct TerminalReplyConformanceTests {
    private struct Probe {
        let name: String
        let query: String
        /// The last byte of the reply, which `read -d` stops at.
        let terminator: Character
        let expected: String
        var prefixOnly = false
    }

    private static let probes: [Probe] = [
        Probe(name: "primary device attributes", query: #"\e[c"#, terminator: "c", expected: "ESC[?65;4;1;2;6;21;22;17;28c"),
        Probe(name: "alternate screen mode", query: #"\e[?1049$p"#, terminator: "y", expected: "ESC[?1049;2$y"),
        Probe(name: "alternate screen mode 1047", query: #"\e[?1047$p"#, terminator: "y", expected: "ESC[?1047;2$y"),
        Probe(name: "synchronized output mode", query: #"\e[?2026$p"#, terminator: "y", expected: "ESC[?2026;2$y"),
        Probe(name: "bracketed paste mode", query: #"\e[?2004$p"#, terminator: "y", expected: "ESC[?2004;2$y"),
        Probe(name: "kitty keyboard flags", query: #"\e[?u"#, terminator: "u", expected: "ESC[?0u"),
        Probe(name: "kitty keyboard after a push", query: #"\e[>5u\e[?u\e[<u"#, terminator: "u", expected: "ESC[?5u"),
        Probe(name: "graphic rendition status", query: #"\eP$qm\e\\"#, terminator: "\\", expected: "ESCP1$r0mESC\\"),
        Probe(name: "scroll margins status", query: #"\eP$qr\e\\"#, terminator: "\\", expected: "ESCP1$r1;", prefixOnly: true),
        Probe(name: "unknown status request", query: #"\eP$qx\e\\"#, terminator: "\\", expected: "ESCP0$rESC\\"),
        Probe(name: "termcap styled underline", query: #"\eP+q536D756C78\e\\"#, terminator: "\\", expected: "ESCP1+r536D756C78=", prefixOnly: true),
        Probe(name: "termcap unknown name", query: #"\eP+q7A7A7A\e\\"#, terminator: "\\", expected: "ESCP0+rESC\\"),
        Probe(name: "kitty graphics support", query: #"\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\"#, terminator: "\\", expected: "ESC_Gi=31;OKESC\\"),
        Probe(name: "background colour", query: #"\e]11;?\e\\"#, terminator: "\\", expected: "ESC]11;rgb:", prefixOnly: true),
        Probe(name: "256 colour cube entry", query: #"\e]4;196;?\e\\"#, terminator: "\\", expected: "ESC]4;196;rgb:ffff/0000/0000ESC\\"),
        Probe(name: "grey ramp entry", query: #"\e]4;244;?\e\\"#, terminator: "\\", expected: "ESC]4;244;rgb:8080/8080/8080ESC\\"),
        Probe(name: "cell size in pixels", query: #"\e[16t"#, terminator: "t", expected: "ESC[6;", prefixOnly: true),
        Probe(name: "text area in cells", query: #"\e[18t"#, terminator: "t", expected: "ESC[8;", prefixOnly: true),
        Probe(name: "colour scheme", query: #"\e[?996n"#, terminator: "n", expected: "ESC[?997;", prefixOnly: true),
        Probe(name: "sixel geometry", query: #"\e[?2;1;0S"#, terminator: "S", expected: "ESC[?2;0;", prefixOnly: true),
        Probe(name: "pointer shape", query: #"\e]22;?pointer,nonsense\e\\"#, terminator: "\\", expected: "ESC]22;1,0ESC\\"),
        Probe(name: "iTerm2 cell size", query: #"\e]1337;ReportCellSize\a"#, terminator: "\\", expected: "ESC]1337;ReportCellSize=", prefixOnly: true),
    ]

    @Test func everyQueryGetsTheReplyItsSpecificationGives() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("turm-replies-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: script) }
        var body = "stty -echo\n"
        for probe in Self.probes {
            let terminator = probe.terminator == "\\" ? #"'\\'"# : "'\(probe.terminator)'"
            body += "printf '\(probe.query)'; reply=; IFS= read -rs -t 3 -d \(terminator) reply; "
            body += "printf 'REPLY %s\\n' \"${reply//$'\\e'/ESC}\"\(probe.terminator == "\\" ? "'\\'" : "'\(probe.terminator)'")\n"
        }
        body += "stty echo\n"
        try body.write(to: script, atomically: true, encoding: .utf8)

        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await conformanceWait { session.phase == .ready })
        session.submit("bash '\(script.path)'")
        #expect(await conformanceWait(timeout: .seconds(120)) { session.blocks.first?.isRunning == false })
        let output = try #require(session.blocks.first).plainOutput
        let replies = output.split(separator: "\n").filter { $0.hasPrefix("REPLY ") }.map { String($0.dropFirst("REPLY ".count)) }
        #expect(replies.count == Self.probes.count, "\(output)")
        for (probe, reply) in zip(Self.probes, replies) {
            if probe.prefixOnly {
                #expect(reply.hasPrefix(probe.expected), "\(probe.name): \(reply)")
            } else {
                #expect(reply == probe.expected, "\(probe.name): \(reply)")
            }
        }
    }
}

@MainActor
struct BlockUnderlineTests {
    @Test func styledAndColouredUnderlinesSurviveTheBlockRewriter() throws {
        let emulator = BlockEmulator(cols: 20, rows: 4)
        emulator.feed(Array("\u{1B}[4:3m\u{1B}[58:2::255:0:0mA\u{1B}[58:2:0:0:255mB\u{1B}[0mC".utf8))
        let first = try #require(emulator.terminal.getCharData(col: 0, row: 0))
        #expect(first.attribute.underlineStyle == .curly)
        #expect(first.attribute.underlineColor == .trueColor(red: 255, green: 0, blue: 0))
        let second = try #require(emulator.terminal.getCharData(col: 1, row: 0))
        #expect(second.attribute.underlineColor == .trueColor(red: 0, green: 0, blue: 255))
        #expect(try #require(emulator.terminal.getCharData(col: 2, row: 0)).attribute.underlineStyle == .none)
    }
}
