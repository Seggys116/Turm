import Foundation
import Testing
import TurmCore
@testable import Turm

private func record(_ fields: String...) -> String {
    "\u{1E}" + fields.joined(separator: "\u{1F}")
}

private func offer(_ word: String, description: String = "", terminator: String = " ", quoted: Bool = true, file: Bool = false, tag: String = "") -> ShellOffer {
    ShellOffer(word: word, description: description, terminator: terminator, needsQuoting: quoted, isFile: file, tag: tag)
}

private func complete(_ offers: [ShellOffer], _ line: String) -> CompletionResult? {
    ShellCompletionMapper.result(offers: offers, line: line, cursor: line.endIndex)
}

struct ShellReplyTests {
    @Test func answersAreFoundBetweenTheMarkersAmidRedrawNoise() throws {
        let body = record("checkout", "switch branches", " ", "0", "0", "commands") + record("cherry", "", " ", "0", "0", "commands")
        let stream = Array(("\u{1B}[K junk " + "\u{1B}]7778;B\u{07}" + body + "\u{1B}]7778;E\u{07}" + "\u{1B}[0m").utf8)
        let answer = try #require(ShellReply.answer(in: stream))
        let offers = ShellReply.offers(answer.body)
        #expect(offers == [
            offer("checkout", description: "switch branches", quoted: false, tag: "commands"),
            offer("cherry", quoted: false, tag: "commands"),
        ])
        #expect(answer.consumed == stream.count - "\u{1B}[0m".utf8.count)
    }

    @Test func anUnfinishedAnswerWaits() {
        let stream = Array(("\u{1B}]7778;B\u{07}" + record("a", "", " ", "1", "0", "")).utf8)
        #expect(ShellReply.answer(in: stream) == nil)
    }

    @Test func recordsWithMissingFieldsStillParse() {
        let offers = ShellReply.offers(Array(record("word").utf8)[...])
        #expect(offers == [ShellOffer(word: "word", description: "", terminator: "", needsQuoting: true, isFile: false, tag: "")])
    }
}

struct ShellCompletionMapperTests {
    @Test func spacesAreEscapedAndTheWordIsReplaced() throws {
        let result = try #require(complete([offer("alpha one.txt", file: true)], "cat al"))
        #expect(result.items.map(\.insert) == ["alpha\\ one.txt"])
        #expect(result.items.first?.terminator == " ")
        #expect(result.items.first?.kind == .file)
        #expect(result.range.lowerBound == "cat al".index("cat al".startIndex, offsetBy: 4))
    }

    @Test func anOpenDoubleQuoteIsKeptAndClosed() throws {
        let result = try #require(complete([offer("alpha one.txt", file: true)], "cat \"al"))
        #expect(result.items.first?.insert == "\"alpha one.txt")
        #expect(result.items.first?.terminator == "\" ")
    }

    @Test func anOpenSingleQuoteIsKept() throws {
        let result = try #require(complete([offer("it's", file: true)], "cat 'it"))
        #expect(result.items.first?.insert == "'it'\\''s")
    }

    @Test func directoriesEndInASlashWithoutASpace() throws {
        let result = try #require(complete([offer("Packages", terminator: "/", file: true, tag: "local-directories")], "cd Pa"))
        #expect(result.items.first?.insert == "Packages/")
        #expect(result.items.first?.terminator == "")
        #expect(result.items.first?.kind == .directory)
    }

    @Test func wordsTheShellMarksAsLiteralAreNotEscaped() throws {
        let result = try #require(complete([offer("$HOME", quoted: false)], "echo $HO"))
        #expect(result.items.first?.insert == "$HOME")
        #expect(result.items.first?.kind == .variable)
    }

    @Test func duplicatesFromSeveralTagsAppearOnce() throws {
        let result = try #require(complete([
            offer("main", quoted: false, tag: "recent-branches"), offer("main", quoted: false, tag: "heads-local"), offer("dev", quoted: false, tag: "heads"),
        ], "git checkout ma"))
        #expect(result.items.map(\.insert) == ["main", "dev"])
        #expect(result.items.first?.kind == .branch)
    }

    @Test func descriptionsBecomeTheDetail() throws {
        let result = try #require(complete([offer("--amend", description: "amend the tip", quoted: false, tag: "options")], "git commit --am"))
        #expect(result.items.first?.detail == "amend the tip")
        #expect(result.items.first?.kind == .flag)
    }

    @Test func commandPositionFollowsSeparatorsAndRedirections() {
        #expect(ShellCompletionMapper.currentWord(in: "gi", cursor: "gi".endIndex).isCommand)
        #expect(!ShellCompletionMapper.currentWord(in: "git ch", cursor: "git ch".endIndex).isCommand)
        #expect(ShellCompletionMapper.currentWord(in: "ls | gr", cursor: "ls | gr".endIndex).isCommand)
        #expect(ShellCompletionMapper.currentWord(in: "cd x && ma", cursor: "cd x && ma".endIndex).isCommand)
        #expect(!ShellCompletionMapper.currentWord(in: "ls > ou", cursor: "ls > ou".endIndex).isCommand)
        #expect(!ShellCompletionMapper.currentWord(in: "git ", cursor: "git ".endIndex).isCommand)
    }

    @Test func anEchoOfTheTypedWordOffersNothing() {
        #expect(complete([offer("done", terminator: "")], "git done") == nil)
        #expect(complete([], "git x") == nil)
    }
}

/// Drives a real hidden shell, loaded the way a session loads it.
@MainActor
struct ShellCompletionHelperTests {
    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("turm-shell-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("alpha-dir"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("alpha one.txt"))
        try Data().write(to: folder.appendingPathComponent("beta.txt"))
        return folder
    }

    private static func service(shell: String) -> ShellCompletionService? {
        guard FileManager.default.isExecutableFile(atPath: shell), let kind = ShellIntegration.Kind(path: shell) else { return nil }
        let service = ShellCompletionService(kind: kind)
        ShellIntegration.forcedShell = shell
        service.prepare()
        ShellIntegration.forcedShell = nil
        return service
    }

    /// The first answer waits for the user's configuration to load.
    private static func answer(_ service: ShellCompletionService, _ line: String, in folder: URL) async -> CompletionResult? {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let result = await service.complete(line: line, cursor: line.endIndex, directory: folder.path, timeout: .seconds(3)) {
                return result
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func expectFiles(_ service: ShellCompletionService, in folder: URL) async throws {
        let files = try #require(await answer(service, "cat al", in: folder))
        let byInsert = Dictionary(files.items.map { ($0.insert, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byInsert["alpha\\ one.txt"]?.terminator == " ", "\(files.items)")
        #expect(byInsert["alpha-dir/"]?.terminator == "", "\(files.items)")
        #expect(byInsert["beta.txt"] == nil)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func zshAnswersWithItsOwnCompletion() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = try #require(Self.service(shell: "/bin/zsh"))
        defer { service.stop() }
        try await Self.expectFiles(service, in: folder)
        let directories = try #require(await Self.answer(service, "cd al", in: folder))
        #expect(directories.items.map(\.insert) == ["alpha-dir/"])
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            let subcommands = try #require(await Self.answer(service, "git chec", in: folder))
            let checkout = try #require(subcommands.items.first { $0.insert == "checkout" })
            #expect(checkout.detail?.isEmpty == false)
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/bash")))
    func bashAnswersWithCompgen() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = try #require(Self.service(shell: "/bin/bash"))
        defer { service.stop() }
        try await Self.expectFiles(service, in: folder)
    }

    private static let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: Self.fish != nil, "fish is not installed"))
    func fishAnswersWithCompleteC() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fish = try #require(Self.fish)
        let service = try #require(Self.service(shell: fish))
        defer { service.stop() }
        let files = try #require(await Self.answer(service, "cat al", in: folder))
        #expect(files.items.contains { $0.insert == "alpha\\ one.txt" }, "\(files.items)")
        #expect(files.items.contains { $0.display == "alpha-dir/" }, "\(files.items)")
    }

    @Test func turmsOwnSyntaxStaysWithTurm() {
        let env = FakeEnvironment.standard
        #expect(!CommandCompleter.isTurmFeature(line: "git ch", cursor: "git ch".endIndex, directory: "/tmp", environment: env))
    }
}
