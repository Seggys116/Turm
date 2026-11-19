import Foundation
import SwiftTerm
import TurmCore

/// One completion the shell offered: the whole word to put in place of the word being typed.
nonisolated struct ShellOffer: Equatable, Sendable {
    let word: String
    let description: String
    /// What follows an accepted offer: a space, a slash for a directory, or nothing.
    let terminator: String
    /// False when the shell asked for the word to go in as it is, as zsh does for variables and branches.
    let needsQuoting: Bool
    let isFile: Bool
    let tag: String
}

/// The helpers frame every answer as `OSC 7778;B`, records, `OSC 7778;E`, and announce themselves once with `OSC 7778;R`.
nonisolated enum ShellReply {
    static let ready = Array("\u{1B}]7778;R\u{07}".utf8)
    static let begin = Array("\u{1B}]7778;B\u{07}".utf8)
    static let end = Array("\u{1B}]7778;E\u{07}".utf8)

    /// The first complete answer in `buffer`, and where scanning should continue.
    static func answer(in buffer: [UInt8]) -> (body: ArraySlice<UInt8>, consumed: Int)? {
        guard let start = find(begin, in: buffer[...]) else { return nil }
        let bodyStart = start + begin.count
        guard let stop = find(end, in: buffer[bodyStart...]) else { return nil }
        return (buffer[bodyStart..<stop], stop + end.count)
    }

    static func find(_ needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = haystack.startIndex
        let last = haystack.endIndex - needle.count
        while index <= last {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    /// Records are `0x1E word 0x1F description 0x1F terminator 0x1F quoted 0x1F file 0x1F tag`.
    static func offers(_ body: ArraySlice<UInt8>) -> [ShellOffer] {
        body.split(separator: 0x1E, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: 0x1F, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard let word = fields.first, !word.isEmpty else { return nil }
            func field(_ index: Int) -> String { fields.indices.contains(index) ? fields[index] : "" }
            return ShellOffer(
                word: word, description: field(1), terminator: field(2), needsQuoting: field(3) != "0", isFile: field(4) == "1",
                tag: field(5)
            )
        }
    }
}

/// Turns the shell's offers into the items the input bar shows and inserts.
nonisolated enum ShellCompletionMapper {
    static func result(offers: [ShellOffer], line: String, cursor: String.Index) -> CompletionResult? {
        let word = currentWord(in: line, cursor: cursor)
        let typed = String(line[word.range])
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for offer in offers {
            // directories carry their slash in the word, as Turm's own path completion does
            let insert = inserted(offer, quote: word.quote) + (offer.terminator == "/" && !offer.word.hasSuffix("/") ? "/" : "")
            guard seen.insert(insert + "\u{0}" + offer.terminator).inserted else { continue }
            let terminator = closing(offer, quote: word.quote)
            items.append(CompletionItem(
                insert: insert, display: offer.word, kind: kind(of: offer, commandPosition: word.isCommand),
                detail: offer.description.isEmpty ? nil : offer.description, terminator: terminator
            ))
            if items.count == CommandCompleter.maxItems { break }
        }
        // the shell may only echo the word back, which offers nothing
        if items.count == 1, items[0].insert == typed, items[0].terminator.isEmpty { return nil }
        guard !items.isEmpty else { return nil }
        return CompletionResult(range: word.range, items: items)
    }

    struct Word {
        let range: Range<String.Index>
        let quote: Character?
        let isCommand: Bool
    }

    /// The shell word that ends at the cursor, the quote it opened with if still open, and whether it names the command.
    static func currentWord(in line: String, cursor: String.Index) -> Word {
        let prefix = String(line[..<cursor])
        var tokens = ShellTokenizer.tokenize(prefix)
        var start = cursor
        var quote: Character?
        if let last = tokens.last, last.kind == .word, last.range.upperBound == prefix.endIndex {
            let offset = prefix.distance(from: prefix.startIndex, to: last.range.lowerBound)
            start = line.index(line.startIndex, offsetBy: offset)
            quote = openQuote(in: String(prefix[last.range]))
            tokens.removeLast()
        }
        var words = 0
        var redirected = false
        for token in tokens {
            if token.isSeparator {
                words = 0
            } else if token.isRedirect {
                redirected = true
            } else if token.kind == .word {
                // the word after a redirection is its target, not the command
                if redirected { redirected = false } else { words += 1 }
            }
        }
        return Word(range: start..<cursor, quote: quote, isCommand: words == 0 && !redirected)
    }

    private static func openQuote(in word: String) -> Character? {
        var open: Character?
        var escaped = false
        for character in word {
            if escaped { escaped = false; continue }
            if let quote = open {
                if character == quote { open = nil } else if character == "\\", quote == "\"" { escaped = true }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                open = character
            }
        }
        return open
    }

    /// Inside an open quote the shell hands back bare text, which goes in escaped for that quote; elsewhere a word
    /// the shell already quoted goes in as it is, and bash and fish words are escaped here.
    static func inserted(_ offer: ShellOffer, quote: Character?) -> String {
        guard quote != nil || offer.needsQuoting else { return offer.word }
        switch quote {
        case "'":
            return "'" + offer.word.replacingOccurrences(of: "'", with: "'\\''")
        case "\"":
            var result = "\""
            for character in offer.word {
                if "\"\\$`".contains(character) { result.append("\\") }
                result.append(character)
            }
            return result
        default:
            return PathCompleter.escape(offer.word)
        }
    }

    private static func closing(_ offer: ShellOffer, quote: Character?) -> String {
        switch offer.terminator {
        case "/":
            return ""
        case " ":
            if let quote { return String(quote) + " " }
            return " "
        default:
            return offer.terminator
        }
    }

    static func kind(of offer: ShellOffer, commandPosition: Bool) -> CompletionItem.Kind {
        let tag = offer.tag.lowercased()
        if offer.isFile || tag.contains("file") || tag.contains("director") {
            return offer.terminator == "/" || offer.word.hasSuffix("/") ? .directory : .file
        }
        if offer.word.hasPrefix("$") || tag.contains("parameter") || tag.contains("variable") { return .variable }
        if tag.contains("option") || (offer.word.hasPrefix("-") && !commandPosition) { return .flag }
        if tag.contains("alias") { return .alias }
        if tag.contains("function") { return .function }
        if tag.contains("builtin") { return .builtin }
        if tag.contains("remote") { return .remote }
        if tag.contains("tag") && tag.contains("git") || tag == "tags" { return .tag }
        if tag.contains("branch") || tag.contains("head") || tag.contains("ref") { return .branch }
        if tag.contains("host") { return .host }
        if tag.contains("user") { return .user }
        if tag.contains("process") || tag.contains("job") { return .process }
        if tag.contains("command") { return commandPosition ? .command : .subcommand }
        return commandPosition ? .command : .choice
    }
}

nonisolated extension CommandCompleter {
    /// SSH host routes and directory shortcuts are Turm's own syntax, which the shell knows nothing about.
    static func isTurmFeature(line: String, cursor: String.Index, directory: String, environment env: CompletionEnvironment) -> Bool {
        let typed = String(line[..<cursor])
        if SSHRoute.partial(typed) != nil { return true }
        if Shortcuts.partial(atEndOf: typed) != nil { return true }
        return !Shortcuts.scan(typed, in: env.shortcuts(in: directory)).isEmpty
    }
}

/// A hidden copy of the user's shell, loaded with their configuration, that answers one request at a time.
nonisolated final class ShellCompletionHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var isReady = false
    private var waiter: CheckedContinuation<[ShellOffer]?, Never>?
    private var waiterID = 0
    private var busySince: Date?
    private var dead = false
    private let kind: ShellIntegration.Kind
    private let requestURL: URL
    private var pty: LocalProcess?
    private var ptyDelegate: PtyDelegate?
    private var process: Process?
    private var input: FileHandle?

    init(kind: ShellIntegration.Kind) {
        self.kind = kind
        requestURL = FileManager.default.temporaryDirectory.appendingPathComponent("turm-complete-\(UUID().uuidString).req")
    }

    deinit {
        stop()
    }

    var ready: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady && !dead
    }

    var isDead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dead
    }

    func start() throws {
        let launch = try ShellIntegration.completionHelper(request: requestURL)
        if kind == .zsh {
            let delegate = PtyDelegate(owner: self)
            let local = LocalProcess(delegate: delegate, dispatchQueue: DispatchQueue(label: "turm.completion.zsh"))
            ptyDelegate = delegate
            pty = local
            SpawnGuard.forking {
                local.startProcess(
                    executable: launch.executable, args: launch.arguments, environment: launch.environment,
                    execName: launch.execName, currentDirectory: NSHomeDirectory()
                )
                let flags = fcntl(local.childfd, F_GETFD)
                if flags >= 0 { _ = fcntl(local.childfd, F_SETFD, flags | FD_CLOEXEC) }
            }
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: launch.executable)
        child.arguments = launch.arguments
        child.environment = Dictionary(launch.environment.compactMap { entry -> (String, String)? in
            guard let equals = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[..<equals]), String(entry[entry.index(after: equals)...]))
        }, uniquingKeysWith: { _, last in last })
        child.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let stdin = SpawnGuard.pipe()
        let stdout = SpawnGuard.pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.died()
            } else {
                self?.received(Array(data))
            }
        }
        child.terminationHandler = { [weak self] _ in self?.died() }
        try SpawnGuard.forking { try child.run() }
        input = stdin.fileHandleForWriting
        process = child
    }

    func stop() {
        lock.lock()
        let local = pty
        let child = process
        pty = nil
        process = nil
        dead = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
        local?.terminate()
        if let child, child.isRunning { child.terminate() }
        try? FileManager.default.removeItem(at: requestURL)
    }

    /// The offers for `line` with the cursor after `cursor` characters, or nil when the shell does not answer in time.
    func request(directory: String, cursor: Int, line: String, timeout: Duration) async -> [ShellOffer]? {
        lock.lock()
        // an answer that never came would leave the helper waiting forever, so a stuck one is replaced
        if let since = busySince, Date().timeIntervalSince(since) > 5 {
            lock.unlock()
            stop()
            return nil
        }
        guard isReady, !dead, busySince == nil else {
            lock.unlock()
            return nil
        }
        busySince = Date()
        waiterID += 1
        let id = waiterID
        lock.unlock()

        var payload = Array(directory.utf8) + [0]
        payload += Array(String(cursor).utf8) + [0]
        payload += Array(line.utf8) + [0]
        if kind == .zsh {
            do {
                try Data(payload).write(to: requestURL, options: .atomic)
            } catch {
                finish(id: id, with: nil)
                return nil
            }
            pty?.send(data: [0x18, 0x14][...])
        } else {
            input?.write(Data(payload))
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if waiterID == id, busySince != nil {
                waiter = continuation
                lock.unlock()
                Task.detached { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.abandon(id: id)
                }
            } else {
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }

    /// Gives up waiting; the late answer is still read and dropped, and the helper is free once it arrives.
    private func abandon(id: Int) {
        lock.lock()
        guard waiterID == id, let pending = waiter else {
            lock.unlock()
            return
        }
        waiter = nil
        lock.unlock()
        pending.resume(returning: nil)
    }

    private func finish(id: Int, with offers: [ShellOffer]?) {
        lock.lock()
        guard waiterID == id else {
            lock.unlock()
            return
        }
        busySince = nil
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: offers)
    }

    fileprivate func received(_ bytes: [UInt8]) {
        lock.lock()
        buffer.append(contentsOf: bytes)
        if !isReady, let found = ShellReply.find(ShellReply.ready, in: buffer[...]) {
            isReady = true
            buffer.removeFirst(found + ShellReply.ready.count)
        }
        var answers: [[ShellOffer]] = []
        while isReady, let answer = ShellReply.answer(in: buffer) {
            answers.append(ShellReply.offers(answer.body))
            buffer.removeFirst(answer.consumed)
        }
        if buffer.count > 4 << 20 { buffer.removeAll() }
        let id = waiterID
        lock.unlock()
        for offers in answers { finish(id: id, with: offers) }
    }

    fileprivate func died() {
        lock.lock()
        dead = true
        busySince = nil
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
    }

    private final class PtyDelegate: LocalProcessDelegate {
        weak var owner: ShellCompletionHelper?

        init(owner: ShellCompletionHelper) {
            self.owner = owner
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            owner?.died()
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            owner?.received(Array(slice))
        }

        func getWindowSize() -> winsize {
            winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
        }
    }
}

/// Asks the user's own shell for completions, keeping one helper alive and starting another if it dies.
nonisolated final class ShellCompletionService: @unchecked Sendable {
    static let shared = ShellCompletionService()

    private let lock = NSLock()
    private var helper: ShellCompletionHelper?
    private var lastStart: Date?
    private let kind: ShellIntegration.Kind

    init(kind: ShellIntegration.Kind = ShellIntegration.userKind) {
        self.kind = kind
    }

    /// Starts the helper early so the first completion does not wait for the user's configuration to load.
    func prepare() {
        _ = current()
    }

    private func current() -> ShellCompletionHelper? {
        lock.lock()
        defer { lock.unlock() }
        if let helper, !helper.isDead { return helper }
        // a configuration that kills the shell should not be retried on every keystroke
        if let lastStart, Date().timeIntervalSince(lastStart) < 10 { return nil }
        lastStart = Date()
        let made = ShellCompletionHelper(kind: kind)
        do {
            try made.start()
        } catch {
            return nil
        }
        helper = made
        return made
    }

    func complete(line: String, cursor: String.Index, directory: String, timeout: Duration) async -> CompletionResult? {
        guard let helper = current(), helper.ready else { return nil }
        let count = line[..<cursor].unicodeScalars.count
        guard let offers = await helper.request(directory: directory, cursor: count, line: line, timeout: timeout) else { return nil }
        return ShellCompletionMapper.result(offers: offers, line: line, cursor: cursor)
    }

    func stop() {
        lock.lock()
        let running = helper
        helper = nil
        lock.unlock()
        running?.stop()
    }
}
