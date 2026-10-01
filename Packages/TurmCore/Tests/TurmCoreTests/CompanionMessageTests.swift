import Foundation
import Testing
@testable import TurmCore

struct CompanionMessageTests {
    private let id = UUID()
    private let block = UUID()

    private let git = CompanionGit(branch: "main", files: 3, added: 10, removed: 2)
    private var shortcut: Shortcut { Shortcut(id: id, kind: .directory, key: "proj", name: "Projects", value: "/Users/z/Projects") }

    private var summary: SessionSummary {
        SessionSummary(
            id: id, title: "build", location: "~/Projects", phase: .running, activity: .progress(percent: 42),
            remoteLabel: "prod", windowTitle: "Turm", branch: "main", directory: "/Users/z/Projects"
        )
    }

    private var everyMessage: [CompanionMessage] {
        [
            .pairBegin(deviceID: id, name: "Phone", commitment: Data(repeating: 1, count: 32)),
            .pairKey(macID: id, macName: "Mac", publicKey: Data(repeating: 2, count: 32)),
            .pairReveal(publicKey: Data(repeating: 5, count: 32), nonce: Data(repeating: 6, count: 32), confirmation: Data(repeating: 7, count: 32)),
            .pairDone(confirmation: Data(repeating: 3, count: 32)),
            .hello(version: .current, deviceID: id, name: "Phone", proof: Data(repeating: 4, count: 32)),
            .ping,
            .listSessions,
            .attach(id: id),
            .detach(id: id),
            .submit(id: id, text: "ls -la"),
            .input(id: id, bytes: Data([3, 27, 91, 65])),
            .interrupt(id: id),
            .resize(id: id, cols: 80, rows: 24),
            .create(directory: "~/Projects", command: "make"),
            .create(directory: nil, command: nil),
            .close(id: id, force: true),
            .welcome(version: .current, macName: "Mac"),
            .incompatible(version: CompanionVersion(app: "1.4.0", kinds: ["hello"], essential: ["hello"])),
            .addresses(hosts: ["192.168.1.5", "100.101.102.103", "mac.local"], port: 7337),
            .pong,
            .sessions([summary]),
            .sessionChanged(summary),
            .sessionClosed(id: id),
            .snapshot(
                id: id, cols: 100, rows: 30,
                history: [BlockSummary(
                    id: block, command: "ls", location: "~", exitCode: 0, text: "a\nb", directory: "/Users/z", git: git,
                    host: "prod", connectedTo: "box", duration: 1.5, styled: Data("\u{1B}[31ma\u{1B}[0m\r\nb".utf8)
                ), BlockSummary(id: UUID(), command: "pwd", location: "~", exitCode: 0, text: "/")],
                running: RunningBlock(
                    id: block, command: "top", location: "~", bytes: Data([0x1B, 0x5B, 0x48]), directory: "/Users/z", git: git, host: nil
                )
            ),
            .snapshot(id: id, cols: 100, rows: 30, history: [], running: nil),
            .blockStarted(id: id, blockID: block, command: "ls", location: "~", directory: "/Users/z", git: git, host: "prod"),
            .blockStarted(id: id, blockID: block, command: "ls", location: "~", directory: "/Users/z", git: nil, host: nil),
            .directoryShortcut(path: "/Users/z/Projects"),
            .commandShortcut(command: "make test"),
            .listShortcuts,
            .saveShortcut(shortcut),
            .removeShortcut(id: id),
            .listBranches(id: id),
            .switchBranch(id: id, name: "feature/x"),
            .revealInFinder(path: "/Users/z/Projects"),
            .directoryShortcutInfo(path: "/Users/z", existing: shortcut, draft: shortcut),
            .commandShortcutInfo(command: "make", existing: nil, draft: shortcut),
            .shortcuts([shortcut]),
            .branches(id: id, names: ["main", "dev"], current: "main"),
            .branchSwitched(id: id, name: "dev", failure: nil),
            .branchSwitched(id: id, name: "dev", failure: "error: pathspec"),
            .ok(request: "saveShortcut"),
            .output(id: id, blockID: block, bytes: Data([0, 255])),
            .blockFinished(id: id, blockID: block, exitCode: nil),
            .blockFinished(id: id, blockID: block, exitCode: 130),
            .phase(id: id, phase: .ready, directory: "/tmp"),
            .title(id: id, text: "vim"),
            .confirmClose(id: id, message: "Active job"),
            .error(code: CompanionErrorCode.notFound, text: "No such shell"),
        ]
    }

    @Test func everyMessageSurvivesJSON() throws {
        for message in everyMessage {
            let data = try JSONEncoder().encode(message)
            #expect(try JSONDecoder().decode(CompanionMessage.self, from: data) == message)
        }
    }

    @Test func theSampleCoversEveryKindAndEachEncodesUnderItsKind() throws {
        #expect(Set(everyMessage.map(\.kind)) == Set(CompanionMessage.Kind.allCases))
        for message in everyMessage {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
            #expect(object.map { Array($0.keys) } == [message.kind.rawValue])
        }
    }

    @Test func everyMessageSurvivesFraming() throws {
        var coder = CompanionFrameCoder()
        var stream = Data()
        let messages = everyMessage
        for message in messages { stream.append(try CompanionFrameCoder.encode(message)) }
        #expect(try coder.feed(stream) == messages)
    }

    @Test func absentOptionalBlockFieldsDecodeAsNil() throws {
        let json = #"{"id":"\#(UUID().uuidString)","command":"ls","location":"~","text":"x","directory":""}"#
        let decoded = try JSONDecoder().decode(BlockSummary.self, from: Data(json.utf8))
        #expect(decoded.git == nil && decoded.host == nil && decoded.exitCode == nil && decoded.styled == nil)
    }

    @Test func styledOutputSurvivesJSONAlongsideThePlainText() throws {
        let styled = Data("\u{1B}[31mred\u{1B}[0m".utf8)
        let summary = BlockSummary(id: block, command: "ls", location: "~", exitCode: 0, text: "red", styled: styled)
        let decoded = try JSONDecoder().decode(BlockSummary.self, from: try JSONEncoder().encode(summary))
        #expect(decoded.styled == styled)
        #expect(decoded.text == "red")
    }

    @Test func gitDirtyFollowsChangedFiles() {
        #expect(!CompanionGit(branch: "main", files: 0, added: 0, removed: 0).isDirty)
        #expect(git.isDirty)
    }

    @Test func bytesTravelAsBase64() throws {
        let data = try JSONEncoder().encode(CompanionMessage.input(id: id, bytes: Data([0xDE, 0xAD])))
        #expect(String(decoding: data, as: UTF8.self).contains("3q0="))
    }

    @Test func unknownMessageFailsToDecode() {
        let data = Data(#"{"launchMissiles":{}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CompanionMessage.self, from: data) }
    }
}
