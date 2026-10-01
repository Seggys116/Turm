import Foundation
import Testing
@testable import TurmCore

private func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

private func output(_ pieces: [StreamPiece]) -> [UInt8] {
    pieces.flatMap { piece -> [UInt8] in
        if case .output(let data) = piece { return data }
        return []
    }
}

private func events(_ pieces: [StreamPiece]) -> [ShellEvent] {
    pieces.compactMap { piece in
        if case .event(let event) = piece { return event }
        return nil
    }
}

private let token = "4242.1700000000.123456"

// A remote zsh session as it reaches the client: login noise, hello, first prompt, one command and its prompt.
private let recorded = bytes(
    "Welcome to host\r\n"
        + "\u{1B}]7777;H;\(token);zsh;dev@box\u{07}"
        + "\u{1B}]7777;R;\(token);;/home/dev\u{07}"
        + "ls\r\n"
        + "\u{1B}]7777;C\u{07}"
        + "\u{1B}[1mREADME\u{1B}[0m  src\r\n"
        + "\u{1B}]7777;R;\(token);0;/home/dev/a;b\u{07}"
)

private let recordedOutput = bytes("Welcome to host\r\nls\r\n\u{1B}[1mREADME\u{1B}[0m  src\r\n")

private let recordedEvents: [ShellEvent] = [
    .remoteHello(token: token, kind: "zsh", host: "dev@box"),
    .remotePrompt(token: token, exitCode: nil, directory: "/home/dev"),
    .commandStarted,
    .remotePrompt(token: token, exitCode: 0, directory: "/home/dev/a;b"),
]

struct ShellStreamParserTests {
    @Test func recordedRemoteSessionInOneChunk() {
        var parser = ShellStreamParser()
        let pieces = parser.consume(recorded)
        #expect(events(pieces) == recordedEvents)
        #expect(output(pieces) == recordedOutput)
    }

    @Test func recordedRemoteSessionSplitAtEveryByte() {
        for cut in 1..<recorded.count {
            var parser = ShellStreamParser()
            let pieces = parser.consume(recorded[..<cut]) + parser.consume(recorded[cut...])
            #expect(events(pieces) == recordedEvents, "cut at \(cut)")
            #expect(output(pieces) == recordedOutput, "cut at \(cut)")
        }
    }

    @Test func recordedRemoteSessionOneByteAtATime() {
        var parser = ShellStreamParser()
        let pieces = recorded.flatMap { parser.consume([$0]) }
        #expect(events(pieces) == recordedEvents)
        #expect(output(pieces) == recordedOutput)
    }

    @Test func eventsKeepTheirPlaceBetweenOutput() {
        var parser = ShellStreamParser()
        #expect(parser.consume(bytes("a\u{1B}]7777;C\u{07}b")) == [
            .output(bytes("a")),
            .event(.commandStarted),
            .output(bytes("b")),
        ])
    }

    @Test func foreignOscPassesThroughUntouched() {
        let input = bytes("\u{1B}]0;window title\u{07}x\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\")
        var parser = ShellStreamParser()
        let pieces = parser.consume(input)
        #expect(events(pieces).isEmpty)
        #expect(output(pieces) == input)
    }

    @Test func foreignOscSplitAcrossChunksPassesThrough() {
        let input = bytes("\u{1B}]2;title\u{07}rest")
        for cut in 1..<input.count {
            var parser = ShellStreamParser()
            let pieces = parser.consume(input[..<cut]) + parser.consume(input[cut...])
            #expect(output(pieces) == input, "cut at \(cut)")
        }
    }

    @Test func malformedRemoteMarkersAreNotEvents() {
        var parser = ShellStreamParser()
        let input = bytes("\u{1B}]7777;R;;0;/x\u{07}\u{1B}]7777;H;only\u{07}")
        #expect(events(parser.consume(input)).isEmpty)
    }

    @Test func environmentWithinLimitIsDecoded() {
        let encoded = Data("A=1\u{0}B=two\u{0}1BAD=x\u{0}".utf8).base64EncodedString()
        var parser = ShellStreamParser()
        #expect(events(parser.consume(bytes("\u{1B}]7777;E;\(encoded)\u{07}"))) == [.environment(["A": "1", "B": "two"])])
    }

    @Test func oversizedEnvironmentIsDiscardedAndParsingResumes() {
        let huge = String(repeating: "A", count: ShellStreamParser.maxEnvironmentPayload)
        var parser = ShellStreamParser()
        let pieces = parser.consume(bytes("\u{1B}]7777;E;\(huge)\u{07}after\u{1B}]7777;C\u{07}"))
        #expect(events(pieces) == [.commandStarted])
        #expect(output(pieces) == bytes("after"))
    }

    @Test func oversizedEnvironmentEndedByStringTerminatorIsDiscarded() {
        let huge = String(repeating: "A", count: ShellStreamParser.maxEnvironmentPayload + 10)
        var parser = ShellStreamParser()
        let pieces = parser.consume(bytes("\u{1B}]7777;E;\(huge)\u{1B}\\tail"))
        #expect(events(pieces).isEmpty)
        #expect(output(pieces) == bytes("tail"))
    }

    @Test func altScreenSwitchIsFound() {
        let enter = bytes("abc\u{1B}[?1049h")
        #expect(AltScreenSequence.firstSwitch(in: enter[...], entering: true) == enter.count)
        #expect(AltScreenSequence.firstSwitch(in: enter[...], entering: false) == nil)
        let other = bytes("\u{1B}[?25h")
        #expect(AltScreenSequence.firstSwitch(in: other[...], entering: true) == nil)
    }
}
