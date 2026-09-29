import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import Turm

nonisolated struct FakeEnvironment: CompletionEnvironment {
    var homeDirectory = "/home/tester"
    var variables: [String: String] = ["HOME": "/home/tester", "HOSTNAME": "box", "PATH": "/usr/bin"]
    var symbols: [ShellSymbol] = []
    var loaded = true
    var files: [String: [DirectoryEntry]] = [:]
    var refs: GitRefs?
    var flagTable: [String: [FlagInfo]] = [:]
    var texts: [String: String] = [:]
    var procs: [ProcessEntry] = []
    var specs: [String: CommandSpec] = [:]
    var docker = DockerObjects()
    var listings: [CLIInvocation: [String]] = [:]
    var awsIndex: String?

    func awsIndexPath() -> String? { awsIndex }

    func cliListing(_ invocation: CLIInvocation) -> [String] { listings[invocation] ?? [] }

    func dockerObjects() -> DockerObjects { docker }

    func readText(atPath path: String) -> String? { texts[path] }
    func processes() -> [ProcessEntry] { procs }
    func commandSpec(forCommand command: String) -> CommandSpec {
        specs[command] ?? CommandSpec(subcommands: [], flags: flags(forCommand: command))
    }

    func commandSymbols() -> [ShellSymbol] { symbols }
    func commandsLoaded() -> Bool { loaded }

    func isExecutable(atPath path: String) -> Bool {
        path == "/work/./tool.sh"
    }

    func fileExists(atPath path: String) -> Bool {
        if files[path] != nil || texts[path] != nil { return true }
        return files.contains { directory, entries in entries.contains { directory + "/" + $0.name == path } }
    }

    func directoryEntries(atPath path: String) -> [DirectoryEntry]? {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        return files[normalized]
    }

    func gitRefs(in directory: String) -> GitRefs? { refs }
    func flags(forCommand command: String) -> [FlagInfo] { flagTable[command] ?? [] }

    static let standard: FakeEnvironment = {
        var env = FakeEnvironment()
        env.symbols = [
            ShellSymbol(name: "git", kind: .executable, detail: "/usr/bin"),
            ShellSymbol(name: "grep", kind: .executable, detail: "/usr/bin"),
            ShellSymbol(name: "gzip", kind: .executable, detail: "/usr/bin"),
            ShellSymbol(name: "ls", kind: .executable, detail: "/bin"),
            ShellSymbol(name: "cat", kind: .executable, detail: "/bin"),
            ShellSymbol(name: "ll", kind: .alias, detail: "ls -l"),
            ShellSymbol(name: "g", kind: .alias, detail: "git"),
            ShellSymbol(name: "mkcd", kind: .function, detail: nil),
            ShellSymbol(name: "_hidden_fn", kind: .function, detail: nil),
            ShellSymbol(name: "cd", kind: .builtin, detail: nil),
            ShellSymbol(name: "echo", kind: .builtin, detail: nil),
            ShellSymbol(name: "true", kind: .builtin, detail: nil),
            ShellSymbol(name: "sudo", kind: .executable, detail: "/usr/bin"),
            ShellSymbol(name: "man", kind: .executable, detail: "/usr/bin"),
            ShellSymbol(name: "if", kind: .keyword, detail: nil),
        ]
        env.files = [
            "/work": [
                DirectoryEntry(name: "src", isDirectory: true),
                DirectoryEntry(name: "docs", isDirectory: true),
                DirectoryEntry(name: "README.md", isDirectory: false),
                DirectoryEntry(name: "notes.txt", isDirectory: false),
                DirectoryEntry(name: "my file.txt", isDirectory: false),
                DirectoryEntry(name: ".hidden", isDirectory: false),
            ],
            "/work/src": [
                DirectoryEntry(name: "main.swift", isDirectory: false),
                DirectoryEntry(name: "util.swift", isDirectory: false),
                DirectoryEntry(name: "lib", isDirectory: true),
            ],
            "/home/tester": [
                DirectoryEntry(name: "Documents", isDirectory: true),
                DirectoryEntry(name: ".zshrc", isDirectory: false),
            ],
        ]
        env.refs = GitRefs(
            branches: ["main", "feature/login"],
            remoteBranches: ["origin/main", "origin/dev"],
            tags: ["v1.0"],
            remotes: ["origin"]
        )
        env.flagTable = [
            "ls": [
                FlagInfo(name: "-a", detail: "all"),
                FlagInfo(name: "-l", detail: "long"),
                FlagInfo(name: "--color", detail: "colorize", takesValue: true, usesEquals: true),
            ],
            "git-commit": [
                FlagInfo(name: "--amend", detail: "amend the last commit"),
                FlagInfo(name: "--message", detail: "message", takesValue: true),
            ],
        ]
        return env
    }()
}

private func complete(
    _ line: String,
    env: FakeEnvironment = .standard,
    history: [String] = [],
    directory: String = "/work"
) -> CompletionResult? {
    CommandCompleter.complete(line: line, cursor: line.endIndex, directory: directory, history: history, environment: env)
}

private func inserts(_ result: CompletionResult?) -> [String] {
    result?.items.map(\.insert) ?? []
}

struct ShellTokenizerTests {
    @Test func splitsWordsAndOperators() {
        let tokens = ShellTokenizer.tokenize("ls -la | grep foo && echo done")
        #expect(tokens.map { $0.text } == ["ls", "-la", "|", "grep", "foo", "&&", "echo", "done"])
        #expect(tokens.map { $0.kind } == [.word, .word, .op, .word, .word, .op, .word, .word])
    }

    @Test func quotedWordsKeepSpacesAndStripQuotes() {
        let tokens = ShellTokenizer.tokenize("echo \"a b\" 'c d'")
        #expect(tokens.count == 3)
        #expect(tokens[1].value == "a b")
        #expect(tokens[2].value == "c d")
        #expect(tokens[1].parts.first?.kind == .doubleQuoted)
    }

    @Test func doubleQuoteEscapes() {
        let tokens = ShellTokenizer.tokenize(#"echo "a\"b""#)
        #expect(tokens.count == 2)
        #expect(tokens[1].value == "a\"b")
        #expect(!tokens[1].unterminated)
    }

    @Test func unterminatedQuoteIsFlagged() {
        let tokens = ShellTokenizer.tokenize("echo \"abc")
        #expect(tokens.count == 2)
        #expect(tokens[1].unterminated)
        #expect(tokens[1].parts.first?.unterminated == true)
        #expect(tokens[1].value == "abc")
    }

    @Test func unterminatedQuoteWithVariableMarksOpeningPart() {
        let tokens = ShellTokenizer.tokenize("echo \"$HOME/x")
        let parts = tokens[1].parts
        #expect(parts.map { $0.kind } == [.doubleQuoted, .variable, .doubleQuoted])
        #expect(parts[0].unterminated)
    }

    @Test func backslashEscapesSpace() {
        let tokens = ShellTokenizer.tokenize("cat my\\ file")
        #expect(tokens.count == 2)
        #expect(tokens[1].value == "my file")
    }

    @Test func redirectionsIncludeDescriptors() {
        let tokens = ShellTokenizer.tokenize("cmd 2>&1 > out.txt < in >> log")
        let ops = tokens.filter { $0.kind == .op }
        #expect(ops.map { $0.text } == ["2>&1", ">", "<", ">>"])
        #expect(ops.allSatisfy { $0.isRedirect })
    }

    @Test func variableAndSubstitutionParts() {
        let tokens = ShellTokenizer.tokenize("echo $HOME/x ${A}b $(date +%s) x")
        #expect(tokens.count == 5)
        #expect(tokens[1].parts.map { $0.kind } == [.variable, .plain])
        #expect(tokens[2].parts.map { $0.kind } == [.variable, .plain])
        #expect(tokens[3].parts.map { $0.kind } == [.substitution])
        #expect(!tokens[3].unterminated)
    }

    @Test func unterminatedSubstitution() {
        let tokens = ShellTokenizer.tokenize("echo $(date")
        #expect(tokens[1].unterminated)
    }

    @Test func commentsRunToEndOfLine() {
        let tokens = ShellTokenizer.tokenize("ls # a note | x")
        #expect(tokens.map { $0.kind } == [.word, .comment])
        #expect(tokens[1].text == "# a note | x")
    }

    @Test func hashInsideWordIsNotAComment() {
        let tokens = ShellTokenizer.tokenize("echo a#b")
        #expect(tokens.count == 2)
    }

    @Test func detectsAssignments() {
        let tokens = ShellTokenizer.tokenize("FOO=bar ls a=b=c")
        #expect(tokens[0].isAssignment)
        #expect(!tokens[1].isAssignment)
    }

    @Test func newlineSeparatesCommands() {
        let tokens = ShellTokenizer.tokenize("ls\ncat x")
        #expect(tokens.map { $0.kind } == [.word, .newline, .word, .word])
        #expect(tokens[1].isSeparator)
    }

    @Test func processSubstitutionIsAWord() {
        let tokens = ShellTokenizer.tokenize("diff <(ls a) b")
        #expect(tokens.count == 3)
        #expect(tokens[1].parts.first?.kind == .substitution)
    }

    @Test func rangesMapBackToTheSourceLine() {
        let line = "echo héllo 'x y'"
        let tokens = ShellTokenizer.tokenize(line)
        #expect(tokens.map { String(line[$0.range]) } == ["echo", "héllo", "'x y'"])
    }
}

struct SyntaxHighlighterTests {
    private func spans(_ line: String, env: FakeEnvironment = .standard) -> [(text: String, kind: HighlightKind)] {
        let ns = line as NSString
        return SyntaxHighlighter.spans(for: line, directory: "/work", environment: env)
            .map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func has(_ list: [(text: String, kind: HighlightKind)], _ text: String, _ kind: HighlightKind) -> Bool {
        list.contains { $0.text == text && $0.kind == kind }
    }

    @Test func knownAndUnknownCommands() {
        let known = spans("ls -a")
        #expect(has(known, "ls", .command))
        #expect(has(known, "-a", .flag))
        #expect(has(spans("zzz foo"), "zzz", .unknownCommand))
    }

    @Test func builtinAliasFunctionKinds() {
        #expect(has(spans("cd src"), "cd", .builtin))
        #expect(has(spans("ll"), "ll", .alias))
        #expect(has(spans("mkcd x"), "mkcd", .function))
    }

    @Test func commandAfterOperatorIsChecked() {
        let list = spans("ls | nope && cat x")
        #expect(has(list, "|", .op))
        #expect(has(list, "&&", .op))
        #expect(has(list, "nope", .unknownCommand))
        #expect(has(list, "cat", .command))
    }

    @Test func notLoadedEnvironmentDoesNotFlagCommands() {
        var env = FakeEnvironment()
        env.loaded = false
        #expect(has(spans("zzz", env: env), "zzz", .command))
    }

    @Test func stringsAndUnterminatedStrings() {
        #expect(has(spans("echo \"hi there\""), "\"hi there\"", .string))
        let broken = spans("echo \"hi")
        #expect(has(broken, "\"hi", .string))
        #expect(has(broken, "\"", .error))
    }

    @Test func variablesAreHighlighted() {
        #expect(has(spans("echo $HOME"), "$HOME", .variable))
        #expect(has(spans("echo \"$HOME/x\""), "$HOME", .variable))
    }

    @Test func existingPathsAreMarked() {
        let list = spans("cat README.md nothing.txt")
        #expect(has(list, "README.md", .existingPath))
        #expect(!has(list, "nothing.txt", .existingPath))
    }

    @Test func redirectionTargetsAreNotCommands() {
        let list = spans("ls > out")
        #expect(has(list, ">", .redirect))
        #expect(!list.contains { $0.text == "out" && $0.kind == .unknownCommand })
    }

    @Test func commentsAreHighlighted() {
        #expect(has(spans("ls # hello"), "# hello", .comment))
    }

    @Test func unmatchedGroupingIsAnError() {
        #expect(has(spans("echo )"), ")", .error))
        #expect(has(spans("(ls"), "(", .error))
        let balanced = spans("(ls)")
        #expect(!balanced.contains { $0.kind == .error })
    }

    @Test func assignmentsKeepTheCommandPosition() {
        let list = spans("FOO=1 ls")
        #expect(has(list, "FOO", .variable))
        #expect(has(list, "ls", .command))
    }

    @Test func prefixCommandsForwardTheCommandPosition() {
        let list = spans("sudo nope")
        #expect(has(list, "sudo", .command))
        #expect(has(list, "nope", .unknownCommand))
    }

    @Test func keywords() {
        let list = spans("if true; then ls; fi")
        #expect(has(list, "if", .keyword))
        #expect(has(list, "then", .keyword))
        #expect(has(list, "fi", .keyword))
        #expect(has(list, "true", .builtin))
    }

    @Test func pathCommandsUseTheFilesystem() {
        #expect(has(spans("./tool.sh"), "./tool.sh", .command))
        #expect(has(spans("./missing.sh"), "./missing.sh", .unknownCommand))
    }

    @Test func emptyLineHasNoSpans() {
        #expect(spans("").isEmpty)
    }
}

struct CommandCompleterTests {
    @Test func completesCommandNames() throws {
        let result = try #require(complete("gr"))
        #expect(inserts(result) == ["grep"])
        #expect(result.items[0].kind == .command)
    }

    @Test func includesAliasesFunctionsAndBuiltinsAndHidesInternalFunctions() throws {
        let result = try #require(complete("l"))
        let kinds = Dictionary(uniqueKeysWithValues: result.items.map { ($0.insert, $0.kind) })
        #expect(kinds["ll"] == .alias)
        #expect(kinds["ls"] == .command)
        let mk = try #require(complete("mk"))
        #expect(mk.items.first?.kind == .function)
        #expect(complete("_h") != nil)
        #expect(!inserts(complete("h")).contains("_hidden_fn"))
    }

    @Test func emptyLineOffersNothing() {
        #expect(complete("") == nil)
    }

    @Test func historyLinesAreOfferedForCommandWord() throws {
        let history = ["git status", "ls", "git checkout main", "git status"]
        let result = try #require(complete("git", history: history))
        let historyItems = result.items.filter { $0.kind == .history }.map(\.insert)
        #expect(historyItems == ["git status", "git checkout main"])
        #expect(result.items.contains { $0.insert == "git" && $0.kind == .command })
    }

    @Test func commandAfterPipeAndPrefix() {
        #expect(inserts(complete("ls | gr")) == ["grep"])
        #expect(inserts(complete("sudo gr")) == ["grep"])
        #expect(inserts(complete("FOO=1 gr")) == ["grep"])
        #expect(inserts(complete("man gr")) == ["grep"])
    }

    @Test func cdCompletesDirectoriesOnly() throws {
        let result = try #require(complete("cd "))
        #expect(inserts(result) == ["docs/", "src/"])
        #expect(result.items.allSatisfy { $0.kind == .directory && $0.terminator.isEmpty })
    }

    @Test func uniqueDirectoryGetsSlash() throws {
        let result = try #require(complete("cd s"))
        #expect(inserts(result) == ["src/"])
    }

    @Test func pathsInsideSubfolder() throws {
        let line = "cat src/ma"
        let result = try #require(complete(line))
        #expect(inserts(result) == ["src/main.swift"])
        #expect(String(line[result.range]) == "src/ma")
    }

    @Test func pathsEscapeSpaces() throws {
        #expect(inserts(complete("open my")) == ["my\\ file.txt"])
    }

    @Test func tildeExpansion() throws {
        #expect(inserts(complete("ls ~/Do")) == ["~/Documents/"])
        #expect(inserts(complete("cd ~")) == ["~/"])
    }

    @Test func hiddenFilesNeedADot() throws {
        #expect(!inserts(complete("ls ")).contains(".hidden"))
        #expect(inserts(complete("ls .h")) == [".hidden"])
    }

    @Test func unterminatedQuoteCompletesInsideTheQuote() throws {
        let result = try #require(complete("cat \"my"))
        #expect(inserts(result) == ["\"my file.txt"])
        #expect(result.items[0].terminator == "\" ")
    }

    @Test func terminatedQuotedWordAndCommentsGiveNothing() {
        #expect(complete("cat \"abc\"") == nil)
        #expect(complete("ls # ab") == nil)
    }

    @Test func redirectTargetCompletesPaths() throws {
        #expect(inserts(complete("echo hi > no")) == ["notes.txt"])
    }

    @Test func environmentVariables() throws {
        let line = "echo $HO"
        let result = try #require(complete(line))
        #expect(inserts(result) == ["HOME", "HOSTNAME"])
        #expect(String(line[result.range]) == "HO")
        #expect(inserts(complete("echo ${HOM")) == ["HOME}"])
        #expect(complete("echo '$HO") == nil)
    }

    @Test func exportCompletesVariableNames() {
        #expect(inserts(complete("export HOS")) == ["HOSTNAME"])
    }

    @Test func gitSubcommands() throws {
        #expect(inserts(complete("git chec")) == ["checkout"])
        let all = try #require(complete("git "))
        #expect(all.items.contains { $0.insert == "commit" && $0.kind == .subcommand })
        #expect(inserts(complete("git -C x chec")) == ["checkout"])
    }

    @Test func gitCheckoutOffersRefs() throws {
        let result = try #require(complete("git checkout "))
        let refs = result.items.filter { [.branch, .tag].contains($0.kind) }.map(\.insert)
        #expect(refs == ["feature/login", "main", "origin/dev", "origin/main", "v1.0"])
        #expect(inserts(complete("git checkout f")) == ["feature/login"])
        #expect(inserts(complete("git switch ma")).contains("main"))
    }

    @Test func gitBranchDeleteOnlyLocalBranches() {
        #expect(inserts(complete("git branch -d ma")) == ["main"])
    }

    @Test func gitPushRemotesThenBranches() {
        #expect(inserts(complete("git push ")) == ["origin"])
        #expect(inserts(complete("git push origin ma")) == ["main"])
    }

    @Test func gitAfterDoubleDashCompletesPaths() {
        #expect(inserts(complete("git checkout -- REA")) == ["README.md"])
    }

    @Test func gitOutsideRepositoryFallsBackToPaths() {
        var env = FakeEnvironment.standard
        env.refs = nil
        #expect(inserts(complete("git checkout RE", env: env)) == ["README.md"])
        #expect(complete("git push ", env: env) != nil)
    }

    @Test func aliasesResolveToTheirCommand() {
        #expect(inserts(complete("g chec")) == ["checkout"])
    }

    @Test func gitStashActions() {
        #expect(inserts(complete("git stash po")) == ["pop"])
    }

    @Test func flagCompletion() throws {
        let all = try #require(complete("ls -"))
        #expect(inserts(all) == ["-a", "-l", "--color="])
        let color = try #require(complete("ls --co"))
        #expect(color.items[0].terminator.isEmpty)
        #expect(color.items[0].display == "--color")
        #expect(color.items[0].kind == .flag)
        #expect(inserts(complete("git commit --am")) == ["--amend"])
        #expect(complete("ls --color=") == nil)
    }

    @Test func flagsAreNotOfferedAfterDoubleDash() throws {
        let result = try #require(complete("ls -- s"))
        #expect(inserts(result) == ["src/"])
    }

    @Test func completesInTheMiddleOfALine() throws {
        let line = "cat sr && ls"
        let cursor = line.index(line.startIndex, offsetBy: 6)
        let result = try #require(
            CommandCompleter.complete(line: line, cursor: cursor, directory: "/work", history: [], environment: FakeEnvironment.standard)
        )
        #expect(inserts(result) == ["src/"])
        #expect(String(line[result.range]) == "sr")
    }

    @Test func commonPrefixHelper() {
        let items = [
            CompletionItem(insert: "feature/a", kind: .branch),
            CompletionItem(insert: "feature/b", kind: .branch),
        ]
        #expect(CommandCompleter.commonPrefix(of: items) == "feature/")
        let escaped = [
            CompletionItem(insert: "a\\ b", kind: .file),
            CompletionItem(insert: "a\\!c", kind: .file),
        ]
        #expect(CommandCompleter.commonPrefix(of: escaped) == "a")
        #expect(CommandCompleter.commonPrefix(of: []) == "")
    }
}

struct FlagParserTests {
    @Test func parsesManPageOptions() {
        let page = """
             -a      Include directory entries whose names begin with a dot.
             -C      Force multi-column output.
             -D format
                     Use format to print dates.
             --color[=when]
                     Colorize output.
             -f, --force  Force it.
        DESCRIPTION
             The -x flag is not an option line.
        """
        let flags = ManPageFlags.parse(page)
        let byName = Dictionary(uniqueKeysWithValues: flags.map { ($0.name, $0) })
        #expect(byName["-a"]?.detail == "Include directory entries whose names begin with a dot.")
        #expect(byName["-a"]?.takesValue == false)
        #expect(byName["-D"]?.takesValue == true)
        #expect(byName["-D"]?.detail == "Use format to print dates.")
        #expect(byName["--color"]?.usesEquals == true)
        #expect(byName["--color"]?.detail == "Colorize output.")
        #expect(byName["-f"] != nil)
        #expect(byName["--force"]?.detail == "Force it.")
        #expect(byName["-x"] == nil)
    }

    @Test func stripsOverstrikeFormatting() {
        let flags = ManPageFlags.parse("     -\u{8}-a\u{8}a      Show all.\n")
        #expect(flags.map { $0.name } == ["-a"])
        #expect(flags.first?.detail == "Show all.")
    }

    @Test func rejectsNonFlagNames() {
        #expect(ManPageFlags.parseSpec("-- something", description: "").isEmpty)
        #expect(ManPageFlags.parseSpec("---x", description: "").isEmpty)
        #expect(ManPageFlags.parseSpec("-", description: "").isEmpty)
    }

    @Test func safeManNames() {
        #expect(ManPageFlags.isSafeName("git-checkout"))
        #expect(!ManPageFlags.isSafeName("a b"))
        #expect(!ManPageFlags.isSafeName("-k"))
        #expect(!ManPageFlags.isSafeName("../x"))
    }

    @Test func parsesZshArgumentSpecs() {
        let source = """
        _arguments -s \\
          '(-A)-a[list entries starting with .]' \\
          '-d[list directory entries]' \\
          '(-h --help)'{-h,--help}'[show help]' \\
          '--color=-[colorize]:when:(always never)' \\
          '-o[output]:file:_files'
        """
        let byName = Dictionary(uniqueKeysWithValues: ZshCompletionFlags.parse(source).map { ($0.name, $0) })
        #expect(byName["-a"]?.detail == "list entries starting with .")
        #expect(byName["-d"]?.takesValue == false)
        #expect(byName["-h"]?.detail == "show help")
        #expect(byName["--help"]?.detail == "show help")
        #expect(byName["--color"]?.takesValue == true)
        #expect(byName["--color"]?.usesEquals == true)
        #expect(byName["-o"]?.takesValue == true)
    }

    @Test func readsTheSystemZshFunctionForLs() {
        let path = "/usr/share/zsh/5.9/functions/_ls"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let flags = ZshCompletionFlags.load(command: "ls")
        #expect(flags.contains { $0.name == "-a" })
    }
}

struct AutosuggestionTests {
    @Test func picksTheMostRecentMatch() {
        let entries = ["git status", "git stash", "ls"]
        #expect(CommandHistory.suggestion(for: "git st", in: entries) == "ash")
        #expect(CommandHistory.suggestion(for: "git stat", in: entries) == "us")
    }

    @Test func ignoresExactAndEmptyAndMultiline() {
        #expect(CommandHistory.suggestion(for: "ls", in: ["ls"]) == nil)
        #expect(CommandHistory.suggestion(for: "", in: ["ls"]) == nil)
        #expect(CommandHistory.suggestion(for: "echo a", in: ["echo a\nb"]) == nil)
    }

    @MainActor @Test func instanceMethodUsesEntries() {
        let history = CommandHistory(entries: ["cargo build --release"])
        #expect(history.suggestion(for: "cargo b") == "uild --release")
    }
}

struct ShellProbeTests {
    @Test func parsesProbeOutput() {
        let m = "\u{1}"
        let output = [
            "banner from rc file",
            "\(m)a\(m)gs\(m)git status",
            "\(m)f\(m)mkcd",
            "\(m)b\(m)cd",
            "\(m)k\(m)if",
            "\(m)v\(m)MYVAR",
            "\(m)p\(m)/opt/bin:/usr/bin",
        ].joined(separator: "\n")
        let environment = SystemCompletionEnvironment()
        environment.parseProbe(output)
        let symbols = environment.commandSymbols()
        #expect(symbols.contains(ShellSymbol(name: "gs", kind: .alias, detail: "git status")))
        #expect(symbols.contains { $0.name == "mkcd" && $0.kind == .function })
        #expect(environment.lookupCommand("cd", directory: "/") == .builtin)
        #expect(environment.lookupCommand("gs", directory: "/") == .alias)
        #expect(environment.lookupCommand("if", directory: "/") == .keyword)
        #expect(environment.lookupCommand("nothing-here", directory: "/") == .unknown)
        #expect(environment.variables["MYVAR"] != nil)
    }
}

private func env(_ configure: (inout FakeEnvironment) -> Void) -> FakeEnvironment {
    var value = FakeEnvironment.standard
    configure(&value)
    return value
}

struct WrapperTests {
    @Test func scannerFindsTheRealCommand() {
        func index(_ line: String) -> Int? {
            let words = ShellTokenizer.tokenize(line).filter { $0.kind == .word }
            return CommandScanner.commandIndex(in: words).index
        }
        #expect(index("sudo -u alice -E -H git status") == 5)
        #expect(index("sudo git") == 1)
        #expect(index("env FOO=1 BAR=2 git") == 3)
        #expect(index("env -u FOO git") == 3)
        #expect(index("time -p git") == 2)
        #expect(index("command git") == 1)
        #expect(index("exec -a name git") == 3)
        #expect(index("nohup git") == 1)
        #expect(index("xargs -n 1 -I {} git") == 5)
        #expect(index("watch -n 2 git") == 3)
        #expect(index("nice -n 10 git") == 3)
        #expect(index("FOO=1 git") == 1)
        #expect(index("sudo env A=1 nice git") == 4)
        #expect(index("timeout 5 git") == 2)
        #expect(index("sudo") == nil)
        #expect(index("sudo -u") == nil)
    }

    @Test func completesCommandsAfterWrappers() {
        for prefix in [
            "sudo -u alice ", "sudo -E -H ", "sudo -- ", "env FOO=bar ", "env -u X ", "time ", "command ", "exec ", "nohup ",
            "xargs -n 1 ", "watch -n 2 ", "nice -n 5 ", "sudo env A=1 ", "timeout 5 ", "FOO=1 BAR=2 ",
        ] {
            #expect(inserts(complete(prefix + "gr")) == ["grep"], "prefix: \(prefix)")
        }
    }

    @Test func completesArgumentsOfTheWrappedCommand() {
        #expect(inserts(complete("sudo -u alice git chec")) == ["checkout"])
        #expect(inserts(complete("env FOO=1 git chec")) == ["checkout"])
        #expect(inserts(complete("sudo cd s")) == ["src/"])
    }

    @Test func wrapperOptionValuesUseTheirKind() throws {
        let users = env { $0.texts["/etc/passwd"] = "root:x:0:0:r:/:/bin/sh\n_www:x:70:70::/:/x\nalice:x:501:20::/h:/bin/zsh\n" }
        let result = try #require(complete("sudo -u al", env: users))
        #expect(inserts(result) == ["alice"])
        #expect(result.items[0].kind == .user)
        #expect(inserts(complete("sudo -u ", env: users)) == ["alice", "root"])
        let groups = env { $0.texts["/etc/group"] = "wheel:*:0:root\n_ard:*:1:\nstaff:*:20:\n" }
        #expect(inserts(complete("sudo -g s", env: groups)) == ["staff"])
        #expect(inserts(complete("sudo -D s")) == ["src/"])
        #expect(inserts(complete("env -C d")) == ["docs/"])
    }

    @Test func wrapperFlagsComeFromTheSpec() {
        let withFlags = env { $0.specs["sudo"] = CommandSpec(subcommands: [], flags: [FlagInfo(name: "-E", detail: "preserve"), FlagInfo(name: "-H")]) }
        #expect(inserts(complete("sudo -", env: withFlags)) == ["-E", "-H"])
    }

    @Test func highlightsWrappedCommands() {
        let ns = { (line: String) -> [(text: String, kind: HighlightKind)] in
            SyntaxHighlighter.spans(for: line, directory: "/work", environment: FakeEnvironment.standard).map {
                ((line as NSString).substring(with: $0.range), $0.kind)
            }
        }
        let sudo = ns("sudo -u root nope")
        #expect(sudo.contains { $0.text == "-u" && $0.kind == .flag })
        #expect(sudo.contains { $0.text == "nope" && $0.kind == .unknownCommand })
        #expect(!sudo.contains { $0.text == "root" && $0.kind == .unknownCommand })
        let wrapped = ns("env A=1 ls")
        #expect(wrapped.contains { $0.text == "A" && $0.kind == .variable })
        #expect(wrapped.contains { $0.text == "ls" && $0.kind == .command })
        #expect(ns("sudo -E -H git").contains { $0.text == "git" && $0.kind == .command })
        #expect(ns("time -p nope").contains { $0.text == "nope" && $0.kind == .unknownCommand })
        #expect(ns("timeout 5 ls").contains { $0.text == "ls" && $0.kind == .command })
    }
}

struct ArgumentSourceTests {
    private static let sshEnv: FakeEnvironment = env { value in
        value.texts["/home/tester/.ssh/config"] = """
        Host alpha beta
          HostName 10.1.1.1
        Host *.wild
        Host !skip
        Include config.d/*
        Include ~/extra
        """
        value.files["/home/tester/.ssh/config.d"] = [DirectoryEntry(name: "one.conf", isDirectory: false)]
        value.texts["/home/tester/.ssh/config.d/one.conf"] = "Host gamma\n"
        value.texts["/home/tester/extra"] = "Host delta\n"
        value.texts["/home/tester/.ssh/known_hosts"] = """
        server1.example.com,10.0.0.5 ssh-ed25519 AAA
        |1|hashedhost|hashedsalt ssh-rsa BBB
        [git.example.com]:2222 ssh-rsa CCC
        @cert-authority *.corp ssh-rsa DDD
        # comment
        """
    }

    @Test func collectsHostsFromConfigIncludesAndKnownHosts() {
        let hosts = ArgumentSources.sshHosts(Self.sshEnv)
        #expect(hosts == ["10.0.0.5", "alpha", "beta", "delta", "gamma", "git.example.com", "server1.example.com"])
        #expect(!hosts.contains { $0.contains("*") || $0.contains("skip") || $0.contains("hashed") })
    }

    @Test func sshCompletesHosts() throws {
        #expect(inserts(complete("ssh al", env: Self.sshEnv)) == ["alpha"])
        #expect(inserts(complete("ssh git", env: Self.sshEnv)) == ["git.example.com"])
        let withUser = try #require(complete("ssh me@be", env: Self.sshEnv))
        #expect(inserts(withUser) == ["me@beta"])
        #expect(withUser.items[0].kind == .host)
        #expect(inserts(complete("sftp de", env: Self.sshEnv)) == ["delta"])
    }

    @Test func scpAndRsyncCompleteHostsWithColon() throws {
        let result = try #require(complete("scp al", env: Self.sshEnv))
        let host = try #require(result.items.first { $0.kind == .host })
        #expect(host.insert == "alpha:")
        #expect(host.terminator.isEmpty)
        #expect(complete("rsync -a alpha:/tmp/x", env: Self.sshEnv) == nil)
    }

    @Test func sshIdentityFileOptionCompletesFiles() {
        #expect(inserts(complete("ssh -i no")) == ["notes.txt"])
        #expect(inserts(complete("ssh -J al", env: Self.sshEnv)) == ["alpha"])
    }

    @Test func wildcardMatching() {
        #expect(ArgumentSources.wildcardMatch("*.conf", "a.conf"))
        #expect(ArgumentSources.wildcardMatch("a?c", "abc"))
        #expect(!ArgumentSources.wildcardMatch("*.conf", "a.txt"))
    }

    private static let packageEnv: FakeEnvironment = env {
        $0.texts["/work/package.json"] = #"{"name":"x","scripts":{"build":"vite build","dev":"vite","test":"vitest"}}"#
    }

    @Test func npmRunScripts() throws {
        let result = try #require(complete("npm run b", env: Self.packageEnv))
        #expect(inserts(result) == ["build"])
        #expect(result.items[0].kind == .script)
        #expect(result.items[0].detail == "vite build")
        #expect(inserts(complete("npm run ", env: Self.packageEnv)) == ["build", "dev", "test"])
        #expect(inserts(complete("pnpm run t", env: Self.packageEnv)) == ["test"])
        #expect(inserts(complete("bun run d", env: Self.packageEnv)) == ["dev"])
        #expect(inserts(complete("npm run-script t", env: Self.packageEnv)) == ["test"])
    }

    @Test func yarnOffersScriptsAndSubcommands() {
        let list = inserts(complete("yarn d", env: Self.packageEnv))
        #expect(list.contains("dev"))
        #expect(list.contains("dlx"))
        #expect(inserts(complete("npm ins")) == ["install"])
    }

    @Test func packageJsonIsFoundInParentDirectories() {
        #expect(inserts(complete("npm run bu", env: Self.packageEnv, directory: "/work/src")) == ["build"])
    }

    private static let makeEnv: FakeEnvironment = env {
        $0.texts["/work/Makefile"] = ".PHONY: all\nCC := gcc\nall: build test\nbuild:\n\tcc\ntest: build\n%.o: %.c\nVAR = a:b\n"
        $0.texts["/work/src/Makefile"] = "tst:\n\ttrue\n"
    }

    @Test func makeTargets() throws {
        #expect(ArgumentSources.makeTargets(try #require(Self.makeEnv.texts["/work/Makefile"])) == ["all", "build", "test"])
        let result = try #require(complete("make bu", env: Self.makeEnv))
        #expect(inserts(result) == ["build"])
        #expect(result.items[0].kind == .target)
        #expect(inserts(complete("make -C src t", env: Self.makeEnv)) == ["tst"])
    }

    @Test func justRecipes() throws {
        let fixture = env {
            $0.texts["/work/justfile"] = "set shell := [\"bash\"]\nalias b := build\nbuild flag='x':\n  cargo build\n_private:\n  true\ntest: build\n  cargo test\n"
        }
        #expect(inserts(complete("just ", env: fixture)) == ["build", "test"])
        #expect(inserts(complete("just b", env: fixture)) == ["build"])
    }

    private static let cargoEnv: FakeEnvironment = env { value in
        value.texts["/work/Cargo.toml"] = "[package]\nname = \"demo\"\n[[bin]]\nname = \"tool\"\npath = \"src/tool.rs\"\n[[example]]\nname = \"hello\"\n"
        value.files["/work/src"]?.append(DirectoryEntry(name: "main.rs", isDirectory: false))
        value.files["/work/src/bin"] = [DirectoryEntry(name: "extra.rs", isDirectory: false)]
        value.files["/work/examples"] = [DirectoryEntry(name: "demo2.rs", isDirectory: false)]
        value.symbols.append(ShellSymbol(name: "cargo-audit", kind: .executable, detail: "/bin"))
    }

    @Test func cargoTargetsAndSubcommands() throws {
        #expect(inserts(complete("cargo run --bin ", env: Self.cargoEnv)) == ["demo", "extra", "tool"])
        #expect(inserts(complete("cargo run --example ", env: Self.cargoEnv)) == ["demo2", "hello"])
        let equals = "cargo run --bin=t"
        let result = try #require(complete(equals, env: Self.cargoEnv))
        #expect(inserts(result) == ["tool"])
        #expect(String(equals[result.range]) == "t")
        #expect(inserts(complete("cargo bu", env: Self.cargoEnv)) == ["build"])
        let plugin = try #require(complete("cargo au", env: Self.cargoEnv))
        #expect(plugin.items.first?.detail == "cargo plugin")
    }

    private static let brewEnv: FakeEnvironment = env { value in
        value.files["/opt/homebrew/Cellar"] = [DirectoryEntry(name: "wget", isDirectory: true), DirectoryEntry(name: "git", isDirectory: true)]
        value.files["/opt/homebrew/Caskroom"] = [DirectoryEntry(name: "firefox", isDirectory: true)]
        value.texts["/home/tester/Library/Caches/Homebrew/api/formula_names.txt"] = "wget\nwgrib\nzstd\n"
        value.texts["/home/tester/Library/Caches/Homebrew/api/cask_names.txt"] = "firefox\nfigma\n"
        value.files["/opt/homebrew/Library/Taps"] = [DirectoryEntry(name: "acme", isDirectory: true)]
        value.files["/opt/homebrew/Library/Taps/acme"] = [DirectoryEntry(name: "homebrew-tools", isDirectory: true)]
        value.files["/opt/homebrew/Library/Taps/acme/homebrew-tools/Formula"] = [
            DirectoryEntry(name: "tool.rb", isDirectory: false), DirectoryEntry(name: "t", isDirectory: true),
        ]
        value.files["/opt/homebrew/Library/Taps/acme/homebrew-tools/Formula/t"] = [DirectoryEntry(name: "thing.rb", isDirectory: false)]
    }

    @Test func brewInstalledAndAvailablePackages() throws {
        let uninstall = try #require(complete("brew uninstall w", env: Self.brewEnv))
        #expect(inserts(uninstall) == ["wget"])
        #expect(uninstall.items[0].kind == .package)
        #expect(uninstall.items[0].detail == "installed formula")
        #expect(inserts(complete("brew install w", env: Self.brewEnv)) == ["wget", "wgrib"])
        #expect(inserts(complete("brew install --cask fi", env: Self.brewEnv)) == ["figma", "firefox"])
        #expect(inserts(complete("brew install to", env: Self.brewEnv)) == ["tool"])
        #expect(inserts(complete("brew install th", env: Self.brewEnv)) == ["thing"])
        #expect(inserts(complete("brew inst", env: Self.brewEnv)) == ["install"])
    }

    @Test func dockerAndKubectlSubcommands() {
        #expect(inserts(complete("docker ru")) == ["run"])
        #expect(inserts(complete("kubectl desc")) == ["describe"])
        let installed = env { $0.specs["docker"] = CommandSpec(subcommands: [SubcommandInfo(name: "swarm", detail: "Manage Swarm")], flags: []) }
        let result = complete("docker sw", env: installed)
        #expect(inserts(result) == ["swarm"])
        #expect(result?.items.first?.detail == "Manage Swarm")
    }

    @Test func processesAndSignals() {
        let procs = env { $0.procs = [ProcessEntry(pid: 12, name: "launchd"), ProcessEntry(pid: 130, name: "Finder"), ProcessEntry(pid: 4001, name: "zsh")] }
        let pids = complete("kill 1", env: procs)
        #expect(inserts(pids) == ["12", "130"])
        #expect(pids?.items.first?.detail == "launchd")
        #expect(inserts(complete("kill -TE", env: procs)) == ["-TERM"])
        #expect(inserts(complete("killall Fi", env: procs)) == ["Finder"])
        #expect(inserts(complete("pkill zs", env: procs)) == ["zsh"])
    }

    @Test func usersAndGroupsAreDerivedFromSystemFiles() {
        let fixture = env {
            $0.texts["/etc/passwd"] = "root:x:0:0:r:/:/bin/sh\n_www:x:70:70::/:/x\n#c\nalice:x:501:20::/h:/bin/zsh\n"
            $0.files["/Users"] = [
                DirectoryEntry(name: "alice", isDirectory: true), DirectoryEntry(name: "bob", isDirectory: true),
                DirectoryEntry(name: "Shared", isDirectory: true), DirectoryEntry(name: ".localized", isDirectory: false),
            ]
            $0.texts["/etc/group"] = "wheel:*:0:root\n_ard:*:1:\nstaff:*:20:\n"
        }
        #expect(ArgumentSources.users(fixture) == ["alice", "bob", "root"])
        #expect(ArgumentSources.groups(fixture) == ["staff", "wheel"])
    }
}

struct ValueKindTests {
    private static let generic: FakeEnvironment = env { value in
        value.specs["frob"] = CommandSpec(
            subcommands: [SubcommandInfo(name: "init", detail: "Initialise"), SubcommandInfo(name: "install", detail: "Install")],
            flags: [
                FlagInfo(name: "--config", takesValue: true, valueKind: .file),
                FlagInfo(name: "--user", takesValue: true, valueKind: .user),
                FlagInfo(name: "--host", takesValue: true, valueKind: .host),
                FlagInfo(name: "--mode", takesValue: true, valueKind: .choices(["fast", "slow"])),
                FlagInfo(name: "--dir", takesValue: true, valueKind: .directory),
                FlagInfo(name: "--pid", takesValue: true, valueKind: .pid),
                FlagInfo(name: "--var", takesValue: true, valueKind: .variable),
                FlagInfo(name: "--verbose"),
            ]
        )
        value.specs["frob-init"] = CommandSpec(subcommands: [], flags: [FlagInfo(name: "--force", detail: "overwrite")])
        value.texts["/etc/passwd"] = "root:x:0:0:r:/:/bin/sh\n"
        value.texts["/home/tester/.ssh/config"] = "Host alpha\n"
        value.procs = [ProcessEntry(pid: 12, name: "launchd"), ProcessEntry(pid: 130, name: "Finder")]
    }

    @Test func genericSubcommandsFromTheSpec() {
        #expect(inserts(complete("frob in", env: Self.generic)) == ["init", "install"])
        #expect(inserts(complete("frob ", env: Self.generic)) == ["init", "install"])
        #expect(inserts(complete("frob init --f", env: Self.generic)) == ["--force"])
        #expect(inserts(complete("frob no", env: Self.generic)) == ["notes.txt"])
    }

    @Test func valuesAfterFlags() throws {
        #expect(inserts(complete("frob --config no", env: Self.generic)) == ["notes.txt"])
        #expect(inserts(complete("frob --user ro", env: Self.generic)) == ["root"])
        #expect(inserts(complete("frob --host al", env: Self.generic)) == ["alpha"])
        let mode = try #require(complete("frob --mode f", env: Self.generic))
        #expect(inserts(mode) == ["fast"])
        #expect(mode.items[0].kind == .choice)
        #expect(inserts(complete("frob --dir s", env: Self.generic)) == ["src/"])
        #expect(inserts(complete("frob --pid 1", env: Self.generic)) == ["12", "130"])
        #expect(inserts(complete("frob --var HOS", env: Self.generic)) == ["HOSTNAME"])
    }

    @Test func valuesAfterEqualsReplaceOnlyTheValue() throws {
        let line = "frob --config=no"
        let result = try #require(complete(line, env: Self.generic))
        #expect(inserts(result) == ["notes.txt"])
        #expect(String(line[result.range]) == "no")
        let choice = "frob --mode=s"
        let mode = try #require(complete(choice, env: Self.generic))
        #expect(inserts(mode) == ["slow"])
        #expect(String(choice[mode.range]) == "s")
    }

    @Test func booleanFlagsDoNotConsumeTheNextWord() {
        #expect(inserts(complete("frob --verbose no", env: Self.generic)) == ["notes.txt"])
    }

    @Test func guessesKindsFromPlaceholders() {
        #expect(ValueKind.guess("FILE") == .file)
        #expect(ValueKind.guess("identity_file") == .file)
        #expect(ValueKind.guess("dir") == .directory)
        #expect(ValueKind.guess("DIRECTORY") == .directory)
        #expect(ValueKind.guess("user") == .user)
        #expect(ValueKind.guess("group") == .group)
        #expect(ValueKind.guess("hostname") == .host)
        #expect(ValueKind.guess("pid") == .pid)
        #expect(ValueKind.guess("N") == .text)
        #expect(ValueKind.guess("") == .text)
    }

    @Test func mapsZshActions() {
        #expect(ValueKind.fromZshAction("_files") == .file)
        #expect(ValueKind.fromZshAction("_files -/") == .directory)
        #expect(ValueKind.fromZshAction("_users") == .user)
        #expect(ValueKind.fromZshAction("_groups") == .group)
        #expect(ValueKind.fromZshAction("_hosts") == .host)
        #expect(ValueKind.fromZshAction("_pids") == .pid)
        #expect(ValueKind.fromZshAction("(always never auto)") == .choices(["always", "never", "auto"]))
        #expect(ValueKind.fromZshAction("_something_else") == .text)
    }

    @Test func manPageOptionsCarryValueKinds() throws {
        let flags = ManPageFlags.parseSpec("-i identity_file", description: "key")
            + ManPageFlags.parseSpec("-C directory", description: "")
            + ManPageFlags.parseSpec("--user=NAME", description: "")
            + ManPageFlags.parseSpec("-p port", description: "")
        let byName = Dictionary(uniqueKeysWithValues: flags.map { ($0.name, $0) })
        #expect(byName["-i"]?.valueKind == .file)
        #expect(byName["-C"]?.valueKind == .directory)
        #expect(byName["--user"]?.usesEquals == true)
        #expect(byName["-p"]?.valueKind == .text)
    }

    @Test func zshSpecsCarryValueKinds() {
        let source = """
        '-o[output]:file:_files' \\
        '-u[user]:user:_users' \\
        '--color=-[colorize]:when:(always never)' \\
        '--dir=[dir]:directory:_files -/' \\
        '--maybe=-[opt]::when:(a b)'
        """
        let byName = Dictionary(uniqueKeysWithValues: ZshCompletionFlags.parse(source).map { ($0.name, $0) })
        #expect(byName["-o"]?.valueKind == .file)
        #expect(byName["-u"]?.valueKind == .user)
        #expect(byName["--color"]?.valueKind == .choices(["always", "never"]))
        #expect(byName["--dir"]?.valueKind == .directory)
        #expect(byName["--maybe"]?.valueKind == .choices(["a", "b"]))
    }
}

struct SubcommandParserTests {
    @Test func extractsSubcommandsFromZshFunctions() {
        let source = """
        local -a commands
        commands=(
          "attach:Attach to a running container"
          'build:Build an image from a Dockerfile'
          'run:Run a command in a new container'
        )
        _arguments '1:command:_files' '*:file:_files' '-x[flag]:name:_files'
        _describe -t commands 'docker commands' commands
        """
        let subs = ZshCompletionFlags.parseSubcommands(source)
        #expect(subs.map { $0.name } == ["attach", "build", "run"])
        #expect(subs[1].detail == "Build an image from a Dockerfile")
    }

    @Test func extractsSubcommandsFromManSections() {
        let page = """
        NAME
             tool

        COMMANDS
             init      Create a new project
             build     Compile the project
             -x        not a command

        OPTIONS
             --help    Show help
        """
        let subs = ManPageFlags.parseSubcommands(page)
        #expect(subs.map { $0.name } == ["init", "build"])
        #expect(subs[0].detail == "Create a new project")
    }
}

struct AutoCompletionTests {
    @Test func neverTriggersOnEmptyOrTrailingSpace() {
        #expect(!AutoTrigger.eligible(""))
        #expect(!AutoTrigger.eligible("git "))
        #expect(!AutoTrigger.eligible("ls\n"))
        #expect(AutoTrigger.eligible("git c"))
    }

    @Test func showsOnlyForNonEmptyWordsAndUsefulResults() {
        let items = [CompletionItem(insert: "checkout", kind: .subcommand), CompletionItem(insert: "cherry-pick", kind: .subcommand)]
        let text = "git c"
        #expect(AutoTrigger.shouldShow(text: text, range: NSRange(location: 4, length: 1), items: items))
        #expect(!AutoTrigger.shouldShow(text: text, range: NSRange(location: 5, length: 0), items: items))
        #expect(!AutoTrigger.shouldShow(text: text, range: NSRange(location: 4, length: 1), items: []))
        let exact = [CompletionItem(insert: "git", kind: .command)]
        #expect(!AutoTrigger.shouldShow(text: "git", range: NSRange(location: 0, length: 3), items: exact))
        #expect(AutoTrigger.shouldShow(text: "echo $", range: NSRange(location: 6, length: 0), items: items))
    }

    @MainActor @Test func enterIsOnlyConsumedAfterTheUserEngages() {
        let model = CompletionModel()
        let items = [CompletionItem(insert: "a", kind: .file), CompletionItem(insert: "b", kind: .file), CompletionItem(insert: "c", kind: .file)]
        model.show(items, engaged: false)
        #expect(model.isOpen)
        #expect(!model.consumesEnter)
        model.move(by: 1)
        #expect(model.consumesEnter)
        #expect(model.selected == 0)
        model.move(by: 1)
        #expect(model.selected == 1)
        model.move(by: 2)
        #expect(model.selected == 0)
        model.close()
        #expect(!model.isOpen)
        #expect(!model.consumesEnter)
    }

    @MainActor @Test func upEngagesFromTheLastItem() {
        let model = CompletionModel()
        model.show([CompletionItem(insert: "a", kind: .file), CompletionItem(insert: "b", kind: .file)], engaged: false)
        model.move(by: -1)
        #expect(model.selected == 1)
        #expect(model.consumesEnter)
    }

    @MainActor @Test func tabOpenedPopupConsumesEnter() {
        let model = CompletionModel()
        model.show([CompletionItem(insert: "a", kind: .file)], engaged: true)
        #expect(model.consumesEnter)
    }
}

struct ShellKindProbeTests {
    @Test func probeScriptsExistForSupportedShells() throws {
        let fish = try #require(SystemCompletionEnvironment.probeScript(shellName: "fish"))
        #expect(fish.contains("functions -n"))
        #expect(fish.contains("builtin -n"))
        #expect(fish.contains("abbr --show"))
        #expect(try #require(SystemCompletionEnvironment.probeScript(shellName: "zsh")).contains("${(k)aliases}"))
        #expect(try #require(SystemCompletionEnvironment.probeScript(shellName: "bash")).contains("compgen -a"))
        #expect(SystemCompletionEnvironment.probeScript(shellName: "tcsh") == nil)
    }

    @Test func parsesFishStyleProbeOutput() {
        let m = "\u{1}"
        let output = [
            "\(m)f\(m)fish_prompt",
            "\(m)b\(m)begin",
            "\(m)a\(m)gco\(m)git checkout",
            "\(m)v\(m)fish_pid",
            "\(m)p\(m)/opt/homebrew/bin:/usr/bin",
        ].joined(separator: "\n")
        let environment = SystemCompletionEnvironment()
        environment.parseProbe(output)
        #expect(environment.lookupCommand("gco", directory: "/") == .alias)
        #expect(environment.lookupCommand("fish_prompt", directory: "/") == .function)
        #expect(environment.lookupCommand("begin", directory: "/") == .builtin)
        #expect(environment.variables["fish_pid"] != nil)
    }
}

nonisolated final class TinyUnixServer: @unchecked Sendable {
    struct Route {
        let status: Int
        let body: String
        let chunked: Bool
    }

    let path: String
    private let listener: Int32

    init?(routes: [String: Route], connections: Int, silent: Bool = false) {
        let socketPath = "/tmp/turm-" + String(UUID().uuidString.prefix(8)).lowercased() + ".sock"
        guard var address = DockerEngine.makeAddress(socketPath) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            return nil
        }
        path = socketPath
        listener = descriptor
        Thread.detachNewThread { Self.serve(descriptor, routes, connections, silent) }
    }

    private static func serve(_ descriptor: Int32, _ routes: [String: Route], _ connections: Int, _ silent: Bool) {
        for _ in 0..<connections {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let capacity = 4096
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = recv(client, &buffer, capacity, 0)
            let request = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if silent {
                usleep(700_000)
                close(client)
                continue
            }
            var response: String
            if let route = routes[target] {
                if route.chunked {
                    let middle = route.body.index(route.body.startIndex, offsetBy: route.body.count / 2)
                    let first = String(route.body[..<middle])
                    let second = String(route.body[middle...])
                    let body = String(first.utf8.count, radix: 16) + "\r\n" + first + "\r\n"
                        + String(second.utf8.count, radix: 16) + "\r\n" + second + "\r\n0\r\n\r\n"
                    response = "HTTP/1.1 \(route.status) X\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + body
                } else {
                    response = "HTTP/1.1 \(route.status) X\r\nContent-Length: \(route.body.utf8.count)\r\nConnection: close\r\n\r\n" + route.body
                }
            } else {
                response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            let bytes = Array(response.utf8)
            var sent = 0
            while sent < bytes.count {
                let written = bytes.withUnsafeBytes { send(client, $0.baseAddress! + sent, bytes.count - sent, 0) }
                if written <= 0 { break }
                sent += written
            }
            close(client)
        }
    }

    func stop() {
        close(listener)
        unlink(path)
    }
}

private let dockerFixture: FakeEnvironment = env { value in
    value.docker = DockerObjects(
        images: [
            DockerImage(id: "abc", names: ["nginx:latest", "nginx:1.25"]),
            DockerImage(id: "def", names: ["redis:7"]),
            DockerImage(id: "ghi", names: []),
        ],
        containers: [
            DockerContainer(id: "c1", names: ["web"], image: "nginx:latest", state: "running"),
            DockerContainer(id: "c2", names: ["db"], image: "redis:7", state: "exited"),
            DockerContainer(id: "c3", names: ["cache"], image: "redis:7", state: "running"),
        ],
        volumes: ["data", "cache-vol"],
        networks: ["bridge", "appnet"],
        available: true
    )
    value.texts["/home/tester/.docker/config.json"] = #"{"currentContext":"colima"}"#
    value.files["/home/tester/.docker/contexts/meta"] = [
        DirectoryEntry(name: "h1", isDirectory: true), DirectoryEntry(name: "h2", isDirectory: true),
    ]
    value.texts["/home/tester/.docker/contexts/meta/h1/meta.json"] = #"{"Name":"colima","Endpoints":{"docker":{"Host":"unix:///x/docker.sock"}}}"#
    value.texts["/home/tester/.docker/contexts/meta/h2/meta.json"] = #"{"Name":"remote","Endpoints":{"docker":{"Host":"ssh://me@box"}}}"#
    value.texts["/work/compose.yaml"] = "name: demo\nservices:\n  web:\n    image: nginx\n  db:\n    image: postgres\n  x-common: {}\nvolumes:\n  data:\n"
    value.texts["/work/other.yml"] = "services:\n  svc:\n    image: a\n"
}

@Suite(.serialized) struct DockerSourceTests {
    @Test func imagesForRunCreatePullRmi() throws {
        let run = try #require(complete("docker run ng", env: dockerFixture))
        #expect(inserts(run) == ["nginx:1.25", "nginx:latest"])
        #expect(run.items[0].kind == .image)
        #expect(inserts(complete("docker run -d -p 80:80 --name x re", env: dockerFixture)) == ["redis:7"])
        #expect(complete("docker run --name ", env: dockerFixture) == nil)
        #expect(inserts(complete("docker pull ng", env: dockerFixture)) == ["nginx:1.25", "nginx:latest"])
        #expect(inserts(complete("docker rmi re", env: dockerFixture)) == ["redis:7"])
        #expect(inserts(complete("docker image rm ng", env: dockerFixture)) == ["nginx:1.25", "nginx:latest"])
        #expect(inserts(complete("docker image pull re", env: dockerFixture)) == ["redis:7"])
    }

    @Test func containersRespectRunningState() throws {
        let exec = try #require(complete("docker exec w", env: dockerFixture))
        #expect(inserts(exec) == ["web"])
        #expect(exec.items[0].kind == .container)
        #expect(exec.items[0].detail == "nginx:latest - running")
        #expect(complete("docker exec d", env: dockerFixture) == nil)
        #expect(inserts(complete("docker start d", env: dockerFixture)) == ["db"])
        #expect(complete("docker start w", env: dockerFixture) == nil)
        #expect(inserts(complete("docker logs c", env: dockerFixture)) == ["cache"])
        #expect(inserts(complete("docker rm ", env: dockerFixture)) == ["cache", "db", "web"])
        #expect(inserts(complete("docker stop web ca", env: dockerFixture)) == ["cache"])
        #expect(inserts(complete("docker container stop w", env: dockerFixture)) == ["web"])
        #expect(inserts(complete("docker restart d", env: dockerFixture)) == ["db"])
    }

    @Test func inspectOffersBoth() {
        #expect(inserts(complete("docker inspect w", env: dockerFixture)) == ["web"])
        #expect(inserts(complete("docker inspect re", env: dockerFixture)) == ["redis:7"])
        #expect(inserts(complete("docker inspect ", env: dockerFixture)).count == 7)
    }

    @Test func containerAndImageNamespacesOfferSubcommands() {
        #expect(inserts(complete("docker container ", env: dockerFixture)).contains("ls"))
        #expect(inserts(complete("docker image pu", env: dockerFixture)) == ["pull", "push"])
    }

    @Test func contextsFromTheDockerConfig() {
        #expect(inserts(complete("docker context use co", env: dockerFixture)) == ["colima"])
        #expect(inserts(complete("docker --context re", env: dockerFixture)) == ["remote"])
        #expect(inserts(complete("docker context ", env: dockerFixture)).contains("use"))
    }

    @Test func composeServicesFromTheComposeFile() throws {
        let up = try #require(complete("docker compose up w", env: dockerFixture))
        #expect(inserts(up) == ["web"])
        #expect(up.items[0].kind == .service)
        #expect(inserts(complete("docker compose logs ", env: dockerFixture)) == ["web", "db"])
        #expect(inserts(complete("docker-compose up d", env: dockerFixture)) == ["db"])
        #expect(inserts(complete("docker compose -f other.yml up s", env: dockerFixture)) == ["svc"])
        #expect(inserts(complete("docker compose ", env: dockerFixture)).contains("up"))
        #expect(inserts(complete("docker compose do", env: dockerFixture)) == ["down"])
        #expect(CommandCompleter.composeServices("services:\n  a:\n  b:\nvolumes:\n  c:\n") == ["a", "b"])
    }

    @Test func socketDiscoveryOrder() {
        let none: (String) -> String? = { _ in nil }
        #expect(DockerEngine.socketPath(variables: ["DOCKER_HOST": "unix:///tmp/x.sock"], home: "/h", readText: none, exists: { $0 == "/tmp/x.sock" }) == "/tmp/x.sock")
        #expect(DockerEngine.socketPath(variables: [:], home: "/h", readText: none, exists: { $0 == "/h/.docker/run/docker.sock" }) == "/h/.docker/run/docker.sock")
        #expect(DockerEngine.socketPath(variables: [:], home: "/h", readText: none, exists: { $0 == "/h/.orbstack/run/docker.sock" }) == "/h/.orbstack/run/docker.sock")
        #expect(DockerEngine.socketPath(variables: [:], home: "/h", readText: none, exists: { $0 == "/var/run/docker.sock" }) == "/var/run/docker.sock")
        #expect(DockerEngine.socketPath(variables: ["DOCKER_HOST": "tcp://1.2.3.4:2375"], home: "/h", readText: none, exists: { $0 == "/var/run/docker.sock" }) == nil)
        #expect(DockerEngine.socketPath(variables: [:], home: "/h", readText: none, exists: { _ in false }) == nil)
    }

    @Test func contextSocketUsesTheHashedMetaDirectory() {
        let digest = SHA256.hash(data: Data("colima".utf8)).map { String(format: "%02x", $0) }.joined()
        let files = [
            "/h/.docker/config.json": #"{"currentContext":"colima"}"#,
            "/h/.docker/contexts/meta/\(digest)/meta.json": #"{"Name":"colima","Endpoints":{"docker":{"Host":"unix:///h/.colima/docker.sock"}}}"#,
        ]
        let read: (String) -> String? = { files[$0] }
        #expect(DockerEngine.contextSocket(variables: [:], home: "/h", readText: read) == "/h/.colima/docker.sock")
        #expect(DockerEngine.socketPath(variables: [:], home: "/h", readText: read, exists: { $0 == "/h/.colima/docker.sock" }) == "/h/.colima/docker.sock")
        #expect(DockerEngine.contextSocket(variables: ["DOCKER_CONTEXT": "default"], home: "/h", readText: read) == nil)
    }

    @Test func parsesEngineJSON() {
        let images = DockerEngine.parseImages(Data(#"[{"Id":"sha256:0123456789abcdef","RepoTags":["a:1","<none>:<none>"]},{"Id":"sha256:fedcba9876543210","RepoTags":null}]"#.utf8))
        #expect(images.map { $0.names } == [["a:1"], []])
        #expect(images.map { $0.id } == ["0123456789ab", "fedcba987654"])
        let containers = DockerEngine.parseContainers(Data(#"[{"Id":"abcdef0123456789","Names":["/web","/alias/web"],"Image":"nginx","State":"running"}]"#.utf8))
        #expect(containers == [DockerContainer(id: "abcdef012345", names: ["web", "alias/web"], image: "nginx", state: "running")])
        #expect(DockerEngine.parseImages(Data("not json".utf8)).isEmpty)
    }

    @Test func decodesPlainAndChunkedResponses() {
        let plain = Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n[]".utf8)
        #expect(DockerEngine.decodeHTTP(plain)?.status == 200)
        #expect(String(decoding: DockerEngine.decodeHTTP(plain)?.body ?? Data(), as: UTF8.self) == "[]")
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n[{\"\r\n4;ext=1\r\na\":1\r\n0\r\n\r\n".utf8)
        #expect(String(decoding: DockerEngine.decodeHTTP(chunked)?.body ?? Data(), as: UTF8.self) == "[{\"a\":1")
        #expect(DockerEngine.decodeHTTP(Data("garbage".utf8)) == nil)
    }

    @Test func talksToAUnixSocketServer() throws {
        let images = #"[{"Id":"sha256:aaaaaaaaaaaaaaaa","RepoTags":["nginx:latest"]}]"#
        let containers = #"[{"Id":"bbbbbbbbbbbbbbbb","Names":["/web"],"Image":"nginx:latest","State":"running"}]"#
        let server = try #require(TinyUnixServer(
            routes: [
                "/images/json": .init(status: 200, body: images, chunked: false),
                "/containers/json?all=1": .init(status: 200, body: containers, chunked: true),
                "/volumes": .init(status: 200, body: #"{"Volumes":[]}"#, chunked: false),
                "/networks": .init(status: 200, body: "[]", chunked: false),
            ],
            connections: 4
        ))
        defer { server.stop() }
        let objects = DockerEngine.load(socket: server.path, timeout: 10)
        #expect(objects.images.map { $0.names } == [["nginx:latest"]])
        #expect(objects.containers.map { $0.names } == [["web"]])
        #expect(objects.containers.first?.state == "running")
    }

    @Test func errorsAndSilenceReturnNothing() throws {
        let failing = try #require(TinyUnixServer(routes: [:], connections: 1))
        defer { failing.stop() }
        #expect(DockerEngine.fetch("/images/json", socket: failing.path, timeout: 1) == nil)
        let silent = try #require(TinyUnixServer(routes: [:], connections: 1, silent: true))
        defer { silent.stop() }
        let started = Date()
        #expect(DockerEngine.fetch("/images/json", socket: silent.path, timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(DockerEngine.fetch("/images/json", socket: "/tmp/turm-does-not-exist.sock") == nil)
        #expect(DockerEngine.load(socket: "/tmp/turm-does-not-exist.sock") == DockerObjects())
    }
}

private let kubeConfigText = """
apiVersion: v1
clusters:
- cluster:
    server: https://a
  name: prod-cluster
- cluster:
    server: https://b
  name: dev-cluster
contexts:
- context:
    cluster: prod-cluster
    namespace: payments
    user: alice
  name: prod
- context:
    cluster: dev-cluster
    user: bob
  name: dev
current-context: prod
kind: Config
users:
- name: alice
  user:
    exec:
      args:
      - --token=a:b
- name: bob
  user:
    token: x
"""

private let kubeFixture: FakeEnvironment = env { value in
    value.texts["/home/tester/.kube/config"] = kubeConfigText
}

private let kubeCacheFixture: FakeEnvironment = env { value in
    let root = "/home/tester/.kube/cache/discovery/example.com_443"
    value.files["/home/tester/.kube/cache/discovery"] = [DirectoryEntry(name: "example.com_443", isDirectory: true)]
    value.files[root] = [DirectoryEntry(name: "v1", isDirectory: true), DirectoryEntry(name: "apps", isDirectory: true)]
    value.files[root + "/apps"] = [DirectoryEntry(name: "v1", isDirectory: true)]
    value.texts[root + "/v1/serverresources.json"] = #"{"kind":"APIResourceList","groupVersion":"v1","resources":[{"name":"pods","shortNames":["po"],"kind":"Pod","namespaced":true},{"name":"pods/log","kind":"Pod"},{"name":"widgets","shortNames":["wd"],"kind":"Widget"}]}"#
    value.texts[root + "/apps/v1/serverresources.json"] = #"{"groupVersion":"apps/v1","resources":[{"name":"deployments","shortNames":["deploy"],"kind":"Deployment"},{"name":"statefulsets","shortNames":["sts"],"kind":"StatefulSet"}]}"#
    value.texts["/home/tester/.kube/config"] = kubeConfigText
}

struct KubectlSourceTests {
    @Test func parsesKubeconfig() {
        let config = KubeSources.parseConfig(kubeConfigText)
        #expect(config.currentContext == "prod")
        #expect(config.contexts == [
            KubeContext(name: "prod", cluster: "prod-cluster", user: "alice", namespace: "payments"),
            KubeContext(name: "dev", cluster: "dev-cluster", user: "bob", namespace: nil),
        ])
        #expect(config.clusters == ["prod-cluster", "dev-cluster"])
        #expect(config.users == ["alice", "bob"])
    }

    @Test func mergesSeveralKubeconfigFiles() {
        let files = [
            "/k/a": "contexts:\n- context:\n    cluster: c1\n  name: one\ncurrent-context: one\n",
            "/k/b": "contexts:\n- context:\n    cluster: c2\n    namespace: ns2\n  name: two\n",
        ]
        let config = KubeSources.loadConfig(variables: ["KUBECONFIG": "/k/a:/k/b:/k/missing"], home: "/h", readText: { files[$0] })
        #expect(config.contexts.map { $0.name } == ["one", "two"])
        #expect(config.currentContext == "one")
        let fixture = env { $0.variables["KUBECONFIG"] = "/k/a:/k/b"; $0.texts = files }
        #expect(inserts(complete("kubectl config use-context t", env: fixture)) == ["two"])
        #expect(inserts(complete("kubectl -n ns", env: fixture)) == ["ns2"])
    }

    @Test func contextClusterUserAndNamespaceOptions() throws {
        #expect(inserts(complete("kubectl --context pr", env: kubeFixture)) == ["prod"])
        #expect(inserts(complete("kubectl get pods --cluster de", env: kubeFixture)) == ["dev-cluster"])
        #expect(inserts(complete("kubectl --user al", env: kubeFixture)) == ["alice"])
        #expect(inserts(complete("kubectl -n pa", env: kubeFixture)) == ["payments"])
        let line = "kubectl get pods --namespace=ku"
        let result = try #require(complete(line, env: kubeFixture))
        #expect(inserts(result) == ["kube-node-lease", "kube-public", "kube-system"])
        #expect(String(line[result.range]) == "ku")
        #expect(inserts(complete("kubectl get -o j", env: kubeFixture)) == ["json", "jsonpath="])
        #expect(inserts(complete("kubectl --kubeconfig no", env: kubeFixture)) == ["notes.txt"])
    }

    @Test func configSubcommands() {
        #expect(inserts(complete("kubectl config ", env: kubeFixture)).contains("use-context"))
        #expect(inserts(complete("kubectl config use-context d", env: kubeFixture)) == ["dev"])
        #expect(inserts(complete("kubectl config delete-cluster p", env: kubeFixture)) == ["prod-cluster"])
        #expect(inserts(complete("kubectl config delete-user b", env: kubeFixture)) == ["bob"])
    }

    @Test func resourceKindsFromTheDiscoveryCache() throws {
        let deploy = try #require(complete("kubectl get de", env: kubeCacheFixture))
        #expect(inserts(deploy) == ["deploy", "deployments"])
        #expect(deploy.items[0].detail == "short name for deployments")
        #expect(deploy.items[1].detail == "Deployment (apps)")
        #expect(inserts(complete("kubectl describe w", env: kubeCacheFixture)) == ["wd", "widgets"])
        #expect(inserts(complete("kubectl get pods/", env: kubeCacheFixture)) == [])
        #expect(complete("kubectl get se", env: kubeCacheFixture) == nil)
        #expect(!inserts(complete("kubectl get p", env: kubeCacheFixture)).contains("pods/log"))
    }

    @Test func fallsBackToCoreKindsWithoutACache() {
        let list = inserts(complete("kubectl get po", env: kubeFixture))
        #expect(list.contains("po"))
        #expect(list.contains("pods"))
        #expect(inserts(complete("kubectl delete sv", env: kubeFixture)) == ["svc"])
        #expect(inserts(complete("kubectl get pods,se", env: kubeFixture)).contains("pods,services"))
        #expect(inserts(complete("kubectl -n dev get depl", env: kubeFixture)) == ["deploy", "deployments"])
    }

    @Test func instanceNamesAreNotGuessed() {
        #expect(complete("kubectl get pods ", env: kubeFixture) == nil)
        #expect(complete("kubectl exec ", env: kubeFixture) == nil)
        #expect(complete("kubectl describe pod my", env: kubeFixture) == nil)
    }

    @Test func logsTopRolloutAndCreate() {
        #expect(inserts(complete("kubectl logs po", env: kubeFixture)) == ["pod/"])
        #expect(inserts(complete("kubectl top ", env: kubeFixture)) == ["pod", "node"])
        #expect(inserts(complete("kubectl rollout ", env: kubeFixture)).contains("restart"))
        #expect(inserts(complete("kubectl rollout status de", env: kubeFixture)).contains("deployments"))
        #expect(inserts(complete("kubectl create dep", env: kubeFixture)) == ["deployment"])
    }
}

struct ToolSourceTests {
    @Test func ghSubcommandGroups() {
        #expect(inserts(complete("gh re")) == ["repo", "release"])
        #expect(inserts(complete("gh pr ch")) == ["checkout", "checks"])
        #expect(inserts(complete("gh issue cl")) == ["close"])
        #expect(inserts(complete("gh run wa")) == ["watch"])
    }

    @Test func awsProfilesAndServices() throws {
        let fixture = env {
            $0.texts["/home/tester/.aws/config"] = "[default]\nregion = x\n[profile dev]\n[sso-session s]\n[profile prod-admin]\n"
            $0.texts["/home/tester/.aws/credentials"] = "[legacy]\naws_access_key_id = x\n[default]\n"
        }
        #expect(inserts(complete("aws --profile ", env: fixture)) == ["default", "dev", "legacy", "prod-admin"])
        let line = "aws --profile=p"
        let result = try #require(complete(line, env: fixture))
        #expect(inserts(result) == ["prod-admin"])
        #expect(String(line[result.range]) == "p")
        #expect(complete("aws s", env: fixture)?.items.contains { $0.insert == "s3" } == true)
        let custom = env { $0.variables["AWS_CONFIG_FILE"] = "/cfg/aws"; $0.texts["/cfg/aws"] = "[profile only]\n" }
        #expect(inserts(complete("aws --profile o", env: custom)) == ["only"])
    }

    @Test func terraformWorkspaces() {
        let fixture = env {
            $0.files["/work/terraform.tfstate.d"] = [DirectoryEntry(name: "staging", isDirectory: true), DirectoryEntry(name: "prod", isDirectory: true)]
            $0.texts["/work/.terraform/environment"] = "staging\n"
        }
        #expect(inserts(complete("terraform pl", env: fixture)) == ["plan"])
        #expect(inserts(complete("terraform workspace ", env: fixture)).contains("select"))
        #expect(inserts(complete("terraform workspace select ", env: fixture)) == ["default", "prod", "staging"])
        #expect(inserts(complete("tofu workspace delete pr", env: fixture)) == ["prod"])
    }

    @Test func pythonPackagesFromVirtualEnvironments() {
        let fixture = env {
            $0.variables["VIRTUAL_ENV"] = "/venv"
            $0.files["/venv/lib"] = [DirectoryEntry(name: "python3.12", isDirectory: true)]
            $0.files["/venv/lib/python3.12/site-packages"] = [
                DirectoryEntry(name: "Flask-3.0.0.dist-info", isDirectory: true),
                DirectoryEntry(name: "requests-2.31.0.dist-info", isDirectory: true),
                DirectoryEntry(name: "foo_bar-1.0.egg-info", isDirectory: true),
                DirectoryEntry(name: "flask", isDirectory: true),
            ]
        }
        #expect(inserts(complete("pip uninstall Fl", env: fixture)) == ["Flask"])
        #expect(inserts(complete("pip3 show req", env: fixture)) == ["requests"])
        #expect(inserts(complete("uv pip uninstall foo", env: fixture)) == ["foo_bar"])
        #expect(inserts(complete("pip ins", env: fixture)) == ["install", "inspect"])
        #expect(inserts(complete("uv pip in", env: fixture)) == ["install"])
    }

    @Test func condaEnvironments() {
        let fixture = env {
            $0.texts["/home/tester/.conda/environments.txt"] = "/home/tester/miniconda3\n/home/tester/miniconda3/envs/ml\n/other/envs/data\n"
            $0.files["/home/tester/miniconda3/envs"] = [DirectoryEntry(name: "web", isDirectory: true)]
        }
        #expect(inserts(complete("conda activate ", env: fixture)) == ["base", "data", "ml", "web"])
        #expect(inserts(complete("conda activate m", env: fixture)) == ["ml"])
        #expect(inserts(complete("conda remove -n w", env: fixture)) == ["web"])
        #expect(inserts(complete("mamba activate d", env: fixture)) == ["data"])
        #expect(inserts(complete("conda env re", env: fixture)) == ["remove"])
    }

    @Test func nodeAndPythonVersionManagers() {
        let fixture = env {
            $0.files["/home/tester/.nvm/versions/node"] = [DirectoryEntry(name: "v18.19.0", isDirectory: true), DirectoryEntry(name: "v20.10.0", isDirectory: true)]
            $0.files["/home/tester/.nvm/alias"] = [DirectoryEntry(name: "default", isDirectory: false), DirectoryEntry(name: "lts", isDirectory: true)]
            $0.files["/home/tester/.local/share/fnm/node-versions"] = [DirectoryEntry(name: "v22.1.0", isDirectory: true)]
            $0.files["/home/tester/.pyenv/versions"] = [DirectoryEntry(name: "3.11.4", isDirectory: true), DirectoryEntry(name: "3.12.0", isDirectory: true)]
        }
        #expect(inserts(complete("nvm use v2", env: fixture)) == ["v20.10.0"])
        #expect(inserts(complete("nvm use d", env: fixture)) == ["default"])
        #expect(inserts(complete("fnm use v2", env: fixture)) == ["v22.1.0"])
        #expect(inserts(complete("pyenv global 3.1", env: fixture)) == ["3.11.4", "3.12.0"])
        #expect(inserts(complete("pyenv shell sy", env: fixture)) == ["system"])
        #expect(inserts(complete("nvm ls-r", env: fixture)) == ["ls-remote"])
    }
}

nonisolated final class RecordingRunner: @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var output: String?

    init(output: String?) {
        self.output = output
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> String? {
        lock.lock()
        recorded.append(Call(executable: executable, arguments: arguments, timeout: timeout))
        lock.unlock()
        return output
    }
}

nonisolated final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

@Suite(.serialized) struct CLIListingTests {
    @Test func kubectlArgumentVector() {
        let full = CLIListing.kubectl(kind: "pods", context: "prod", namespace: "payments", kubeconfig: "/k/config")
        #expect(full.tool == "kubectl")
        #expect(full.arguments == ["get", "pods", "-o", "name", "--request-timeout=2s", "--context", "prod", "-n", "payments", "--kubeconfig", "/k/config"])
        let minimal = CLIListing.kubectl(kind: "deployments.apps", context: nil, namespace: nil, kubeconfig: nil)
        #expect(minimal.arguments == ["get", "deployments.apps", "-o", "name", "--request-timeout=2s"])
        #expect(!full.arguments.contains("-A"))
    }

    @Test func helmAndDockerArgumentVectors() {
        let helm = CLIListing.helmReleases(namespace: "prod", context: "c1", kubeconfig: "/k")
        #expect(helm.tool == "helm")
        #expect(helm.arguments == ["list", "-q", "--namespace", "prod", "--kube-context", "c1", "--kubeconfig", "/k"])
        #expect(CLIListing.helmReleases(namespace: nil, context: nil, kubeconfig: nil).arguments == ["list", "-q"])
        #expect(CLIListing.docker(.images, context: nil).arguments == ["images", "--format", "{{.Repository}}:{{.Tag}}"])
        #expect(CLIListing.docker(.allContainers, context: "remote").arguments == ["--context", "remote", "ps", "-a", "--format", "{{.Names}}"])
        #expect(CLIListing.docker(.runningContainers, context: nil).arguments == ["ps", "--format", "{{.Names}}"])
        #expect(CLIListing.docker(.volumes, context: nil).arguments == ["volume", "ls", "--format", "{{.Name}}"])
        #expect(CLIListing.docker(.networks, context: nil).arguments == ["network", "ls", "--format", "{{.Name}}"])
        #expect(CLIListing.docker(.images, context: nil).tool == "docker")
    }

    @Test func onlyTheExactReadOnlyShapesAreAllowed() {
        #expect(CLIListing.isAllowed(CLIListing.kubectl(kind: "pods", context: "c", namespace: "n", kubeconfig: "/k")))
        #expect(CLIListing.isAllowed(CLIListing.helmReleases(namespace: "n", context: nil, kubeconfig: nil)))
        #expect(CLIListing.isAllowed(CLIListing.docker(.networks, context: "c")))
        let bad: [CLIInvocation] = [
            CLIInvocation(tool: "kubectl", arguments: ["delete", "pods", "-o", "name", "--request-timeout=2s"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "pods", "-o", "yaml", "--request-timeout=2s"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "pods", "-o", "name"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "pods", "-o", "name", "--request-timeout=2s", "-A"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "pods", "-o", "name", "--request-timeout=2s", "--all-namespaces", "x"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "Pods", "-o", "name", "--request-timeout=2s"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "pods,svc", "-o", "name", "--request-timeout=2s"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "pods", "-o", "name", "--request-timeout=2s", "-n", "-x"]),
            CLIInvocation(tool: "kubectl", arguments: ["get", "pods", "-o", "name", "--request-timeout=2s", "-n", "a", "-n", "b"]),
            CLIInvocation(tool: "kubectl", arguments: ["exec", "pod", "--", "ls"]),
            CLIInvocation(tool: "helm", arguments: ["install", "x", "y"]),
            CLIInvocation(tool: "helm", arguments: ["list", "-q", "--all-namespaces", "x"]),
            CLIInvocation(tool: "docker", arguments: ["run", "-it", "alpine"]),
            CLIInvocation(tool: "docker", arguments: ["ps", "-a", "--format", "{{.Names}}", "extra"]),
            CLIInvocation(tool: "docker", arguments: ["--context", "-x", "ps"]),
            CLIInvocation(tool: "sh", arguments: ["-c", "true"]),
        ]
        for invocation in bad {
            #expect(!CLIListing.isAllowed(invocation), "\(invocation)")
        }
    }

    @Test func parsesKubectlNames() {
        let names = CLIListing.kubectlNames("pod/web-1\ndeployment.apps/api\n\nbogus\nnode/n1\n")
        #expect(names.map { $0.name } == ["web-1", "api", "n1"])
        #expect(names.map { $0.kind } == ["pod", "deployment.apps", "node"])
    }

    @Test func cacheRunsWithTheHardDeadlineAndCachesForTenSeconds() {
        let runner = RecordingRunner(output: "pod/a\n\n pod/b \n")
        let clock = TestClock()
        let cache = CLIListingCache(locate: { "/fake/bin/" + $0 }, runner: { runner.run($0, $1, $2) }, now: { clock.date })
        let invocation = CLIListing.kubectl(kind: "pods", context: "prod", namespace: "payments", kubeconfig: nil)
        #expect(cache.lines(invocation) == ["pod/a", "pod/b"])
        #expect(runner.calls == [
            .init(
                executable: "/fake/bin/kubectl",
                arguments: ["get", "pods", "-o", "name", "--request-timeout=2s", "--context", "prod", "-n", "payments"],
                timeout: 3
            ),
        ])
        #expect(CLIListing.deadline == 3)
        #expect(CLIListing.ttl == 10)
        clock.advance(9.5)
        #expect(cache.lines(invocation) == ["pod/a", "pod/b"])
        #expect(runner.calls.count == 1)
        let other = CLIListing.kubectl(kind: "pods", context: "prod", namespace: "other", kubeconfig: nil)
        _ = cache.lines(other)
        #expect(runner.calls.count == 2)
        let otherKind = CLIListing.kubectl(kind: "services", context: "prod", namespace: "payments", kubeconfig: nil)
        _ = cache.lines(otherKind)
        #expect(runner.calls.count == 3)
        clock.advance(1)
        _ = cache.lines(invocation)
        #expect(runner.calls.count == 4)
    }

    @Test func failuresAreCachedAndAbsentToolsNeverRun() {
        let runner = RecordingRunner(output: nil)
        let clock = TestClock()
        let cache = CLIListingCache(locate: { "/fake/" + $0 }, runner: { runner.run($0, $1, $2) }, now: { clock.date })
        let invocation = CLIListing.docker(.images, context: nil)
        #expect(cache.lines(invocation).isEmpty)
        #expect(cache.lines(invocation).isEmpty)
        #expect(runner.calls.count == 1)
        clock.advance(11)
        #expect(cache.lines(invocation).isEmpty)
        #expect(runner.calls.count == 2)

        let absentRunner = RecordingRunner(output: "x\n")
        let absent = CLIListingCache(locate: { _ in nil }, runner: { absentRunner.run($0, $1, $2) })
        #expect(absent.lines(invocation).isEmpty)
        #expect(absentRunner.calls.isEmpty)
    }

    @Test func disallowedInvocationsAreNeverExecuted() {
        let runner = RecordingRunner(output: "x\n")
        let cache = CLIListingCache(locate: { "/fake/" + $0 }, runner: { runner.run($0, $1, $2) })
        #expect(cache.lines(CLIInvocation(tool: "kubectl", arguments: ["delete", "pod", "x"])).isEmpty)
        #expect(cache.lines(CLIInvocation(tool: "rm", arguments: ["-rf", "/"])).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test func processRunnerEnforcesTheHardDeadline() {
        let started = Date()
        #expect(ProcessRunner.run("/bin/sleep", arguments: ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 2)
        let stubborn = Date()
        #expect(ProcessRunner.run("/bin/sh", arguments: ["-c", "trap '' TERM; sleep 5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(stubborn) < 2)
    }

    @Test func processRunnerReturnsOutputAndHonoursExitStatus() {
        #expect(ProcessRunner.run("/bin/echo", arguments: ["hi"], timeout: 10) == "hi\n")
        #expect(ProcessRunner.run("/usr/bin/false", arguments: [], timeout: 2) == "")
        #expect(ProcessRunner.run("/usr/bin/false", arguments: [], timeout: 2, requireSuccess: true) == nil)
        #expect(ProcessRunner.run("/nonexistent/tool", arguments: [], timeout: 1) == nil)
    }
}

private let kubeListingFixture: FakeEnvironment = env { value in
    value.texts["/home/tester/.kube/config"] = "contexts:\n- context:\n    cluster: c\n  name: prod\ncurrent-context: prod\n"
    value.listings[CLIListing.kubectl(kind: "pods", context: nil, namespace: nil, kubeconfig: nil)] = ["pod/web-1", "pod/db-0"]
    value.listings[CLIListing.kubectl(kind: "deployments", context: nil, namespace: nil, kubeconfig: nil)] = ["deployment.apps/api", "deployment.apps/worker"]
    value.listings[CLIListing.kubectl(kind: "nodes", context: nil, namespace: nil, kubeconfig: nil)] = ["node/n1", "node/n2"]
    value.listings[CLIListing.kubectl(kind: "pods", context: "prod", namespace: "payments", kubeconfig: nil)] = ["pod/pay-1"]
    value.listings[CLIListing.kubectl(kind: "pods", context: nil, namespace: nil, kubeconfig: "/k/c")] = ["pod/from-file"]
    value.listings[CLIListing.kubectl(kind: "namespaces", context: nil, namespace: nil, kubeconfig: nil)] = ["namespace/team-a", "namespace/team-b"]
    value.listings[CLIListing.kubectl(kind: "namespaces", context: "prod", namespace: nil, kubeconfig: nil)] = ["namespace/prod-ns"]
}

struct KubectlInstanceTests {
    @Test func namesAfterGetDescribeDeleteEdit() {
        #expect(inserts(complete("kubectl describe pod w", env: kubeListingFixture)) == ["web-1"])
        #expect(inserts(complete("kubectl get pods d", env: kubeListingFixture)) == ["db-0"])
        #expect(inserts(complete("kubectl delete po ", env: kubeListingFixture)) == ["db-0", "web-1"])
        #expect(inserts(complete("kubectl edit deployment a", env: kubeListingFixture)) == ["api"])
        #expect(inserts(complete("kubectl get deployments ", env: kubeListingFixture)) == ["api", "worker"])
        #expect(inserts(complete("kubectl scale deploy w", env: kubeListingFixture)) == ["worker"])
        #expect(inserts(complete("kubectl label pods d", env: kubeListingFixture)) == ["db-0"])
        #expect(inserts(complete("kubectl annotate pod w", env: kubeListingFixture)) == ["web-1"])
        #expect(inserts(complete("kubectl patch pod w", env: kubeListingFixture)) == ["web-1"])
        #expect(inserts(complete("kubectl wait pod w", env: kubeListingFixture)) == ["web-1"])
    }

    @Test func slashForms() {
        #expect(inserts(complete("kubectl describe pod/d", env: kubeListingFixture)) == ["pod/db-0"])
        #expect(inserts(complete("kubectl logs deployment/a", env: kubeListingFixture)) == ["deployment/api"])
        #expect(inserts(complete("kubectl port-forward pod/w", env: kubeListingFixture)) == ["pod/web-1"])
        #expect(inserts(complete("kubectl rollout restart deployment/w", env: kubeListingFixture)) == ["deployment/worker"])
    }

    @Test func podCommands() throws {
        #expect(inserts(complete("kubectl logs w", env: kubeListingFixture)) == ["web-1"])
        let logs = inserts(complete("kubectl logs ", env: kubeListingFixture))
        #expect(logs.contains("web-1"))
        #expect(logs.contains("db-0"))
        #expect(logs.contains("deployment/"))
        #expect(inserts(complete("kubectl exec w", env: kubeListingFixture)) == ["web-1"])
        #expect(complete("kubectl exec web-1 ", env: kubeListingFixture) == nil)
        #expect(inserts(complete("kubectl attach d", env: kubeListingFixture)) == ["db-0"])
        #expect(inserts(complete("kubectl port-forward w", env: kubeListingFixture)) == ["web-1"])
        let cp = try #require(complete("kubectl cp w", env: kubeListingFixture))
        let pod = try #require(cp.items.first { $0.display == "web-1" })
        #expect(pod.insert == "web-1:")
        #expect(pod.terminator.isEmpty)
        #expect(complete("kubectl cp web-1:/etc/x", env: kubeListingFixture) == nil)
    }

    @Test func topRolloutAndNodes() {
        #expect(inserts(complete("kubectl top pod w", env: kubeListingFixture)) == ["web-1"])
        #expect(inserts(complete("kubectl top node ", env: kubeListingFixture)) == ["n1", "n2"])
        #expect(inserts(complete("kubectl rollout restart deployment a", env: kubeListingFixture)) == ["api"])
        #expect(inserts(complete("kubectl drain n", env: kubeListingFixture)) == ["n1", "n2"])
    }

    @Test func typedContextNamespaceAndKubeconfigSelectTheListing() {
        #expect(inserts(complete("kubectl -n payments --context prod get pods p", env: kubeListingFixture)) == ["pay-1"])
        #expect(inserts(complete("kubectl get pods --namespace=payments --context=prod p", env: kubeListingFixture)) == ["pay-1"])
        #expect(inserts(complete("kubectl --kubeconfig /k/c get pods f", env: kubeListingFixture)) == ["from-file"])
        #expect(inserts(complete("kubectl get pods -A w", env: kubeListingFixture)) == ["web-1"])
    }

    @Test func namespacesFromTheClusterWhenTheKubeconfigHasNone() {
        #expect(inserts(complete("kubectl -n team", env: kubeListingFixture)) == ["team-a", "team-b"])
        #expect(inserts(complete("kubectl --context prod -n prod-", env: kubeListingFixture)) == ["prod-ns"])
        let withNamespace = env { $0.texts["/home/tester/.kube/config"] = "contexts:\n- context:\n    namespace: mine\n  name: c\n" }
        #expect(inserts(complete("kubectl -n mi", env: withNamespace)) == ["mine"])
    }

    @Test func nothingExtraWhenKubectlIsUnavailable() {
        #expect(complete("kubectl get pods w", env: kubeFixture) == nil)
        #expect(complete("kubectl logs zzz", env: kubeFixture) == nil)
        #expect(complete("kubectl exec ", env: kubeFixture) == nil)
    }
}

@Suite(.serialized) struct DockerVolumeNetworkTests {
    @Test func volumeAndNetworkSubcommands() {
        #expect(inserts(complete("docker volume rm da", env: dockerFixture)) == ["data"])
        #expect(inserts(complete("docker volume inspect ", env: dockerFixture)) == ["data", "cache-vol"])
        #expect(inserts(complete("docker volume ", env: dockerFixture)).contains("prune"))
        #expect(inserts(complete("docker network rm app", env: dockerFixture)) == ["appnet"])
        #expect(inserts(complete("docker network connect app", env: dockerFixture)) == ["appnet"])
        #expect(inserts(complete("docker network connect appnet w", env: dockerFixture)) == ["web"])
        #expect(inserts(complete("docker network ", env: dockerFixture)).contains("connect"))
    }

    @Test func volumeAndNetworkOptions() throws {
        let volume = try #require(complete("docker run -v da", env: dockerFixture))
        let item = try #require(volume.items.first { $0.kind == .volume })
        #expect(item.insert == "data:")
        #expect(item.terminator.isEmpty)
        #expect(complete("docker run -v data:/x", env: dockerFixture) == nil)
        #expect(inserts(complete("docker run --network b", env: dockerFixture)) == ["bridge"])
        #expect(inserts(complete("docker run --net=app", env: dockerFixture)) == ["appnet"])
        #expect(inserts(complete("docker run --volumes-from w", env: dockerFixture)) == ["web"])
    }

    @Test func engineParsesVolumesAndNetworks() {
        #expect(DockerEngine.parseVolumes(Data(#"{"Volumes":[{"Name":"a"},{"Name":"b"}],"Warnings":null}"#.utf8)) == ["a", "b"])
        #expect(DockerEngine.parseVolumes(Data(#"{"Volumes":null}"#.utf8)).isEmpty)
        #expect(DockerEngine.parseNetworks(Data(#"[{"Name":"bridge","Id":"1"},{"Name":"host"}]"#.utf8)) == ["bridge", "host"])
    }

    @Test func socketServerServesVolumesAndNetworks() throws {
        let server = try #require(TinyUnixServer(
            routes: [
                "/images/json": .init(status: 200, body: "[]", chunked: false),
                "/containers/json?all=1": .init(status: 200, body: "[]", chunked: false),
                "/volumes": .init(status: 200, body: #"{"Volumes":[{"Name":"data"}]}"#, chunked: true),
                "/networks": .init(status: 200, body: #"[{"Name":"bridge"},{"Name":"appnet"}]"#, chunked: false),
            ],
            connections: 4
        ))
        defer { server.stop() }
        let objects = DockerEngine.load(socket: server.path, timeout: 10)
        #expect(objects.available)
        #expect(objects.volumes == ["data"])
        #expect(objects.networks == ["bridge", "appnet"])
    }

    @Test func remoteDaemonsAreNeverGuessedFromLocalSockets() {
        let none: (String) -> String? = { _ in nil }
        #expect(DockerEngine.socketPath(variables: ["DOCKER_HOST": "ssh://me@box"], home: "/h", readText: none, exists: { _ in true }) == nil)
        let digest = SHA256.hash(data: Data("remote".utf8)).map { String(format: "%02x", $0) }.joined()
        let files = [
            "/h/.docker/config.json": #"{"currentContext":"remote"}"#,
            "/h/.docker/contexts/meta/\(digest)/meta.json": #"{"Name":"remote","Endpoints":{"docker":{"Host":"tcp://10.0.0.5:2376"}}}"#,
        ]
        #expect(DockerEngine.socketPath(variables: [:], home: "/h", readText: { files[$0] }, exists: { _ in true }) == nil)
        #expect(DockerEngine.contextHost(variables: [:], home: "/h", readText: { files[$0] }) == "tcp://10.0.0.5:2376")
    }

    @Test func cliFallbackWhenNoSocketIsReachable() {
        let fixture = env { value in
            value.docker = DockerObjects()
            value.listings[CLIListing.docker(.images, context: nil)] = ["nginx:latest", "<none>:<none>", "redis:7"]
            value.listings[CLIListing.docker(.allContainers, context: nil)] = ["web", "db"]
            value.listings[CLIListing.docker(.runningContainers, context: nil)] = ["web"]
            value.listings[CLIListing.docker(.volumes, context: nil)] = ["vol1"]
            value.listings[CLIListing.docker(.networks, context: nil)] = ["net1"]
            value.listings[CLIListing.docker(.images, context: "remote")] = ["remote-only:1"]
        }
        #expect(inserts(complete("docker run ng", env: fixture)) == ["nginx:latest"])
        #expect(inserts(complete("docker exec w", env: fixture)) == ["web"])
        #expect(inserts(complete("docker start d", env: fixture)) == ["db"])
        #expect(complete("docker start w", env: fixture) == nil)
        #expect(inserts(complete("docker rm ", env: fixture)) == ["db", "web"])
        #expect(inserts(complete("docker volume rm v", env: fixture)) == ["vol1"])
        #expect(inserts(complete("docker network rm n", env: fixture)) == ["net1"])
        #expect(inserts(complete("docker --context remote rmi re", env: fixture)) == ["remote-only:1"])
        let mixed = env { value in
            value.docker = dockerFixture.docker
            value.listings[CLIListing.docker(.images, context: "remote")] = ["remote-only:1"]
        }
        #expect(inserts(complete("docker --context remote rmi re", env: mixed)) == ["remote-only:1"])
        #expect(inserts(complete("docker rmi re", env: mixed)) == ["redis:7"])
    }
}

private let composeFixture: FakeEnvironment = env { value in
    value.texts["/work/compose.yaml"] = """
    include:
      - other.yml
      - path: extra/compose.yaml
        env_file: .env
    services:
      web:
        image: a
        profiles: [debug, dev]
      worker:
        extends:
          service: base
          file: common.yml
        profiles:
          - batch
    volumes:
      x:
    """
    value.texts["/work/other.yml"] = "include:\n  - compose.yaml\nservices:\n  cache:\n    image: r\n"
    value.texts["/work/extra/compose.yaml"] = "services:\n  proxy:\n    image: p\n"
    value.texts["/work/alt.yml"] = "services:\n  alt-one:\n    image: z\n"
}

struct ComposeProjectTests {
    @Test func parsesProfilesExtendsAndIncludes() {
        let parsed = CommandCompleter.parseCompose(composeFixture.texts["/work/compose.yaml"] ?? "")
        #expect(parsed.services == [
            ComposeService(name: "web", profiles: ["debug", "dev"], extends: nil),
            ComposeService(name: "worker", profiles: ["batch"], extends: "base"),
        ])
        #expect(parsed.includes == ["other.yml", "extra/compose.yaml"])
    }

    @Test func followsIncludesAndGuardsAgainstCycles() throws {
        let result = try #require(complete("docker compose up ", env: composeFixture))
        #expect(inserts(result) == ["web", "worker", "cache", "proxy"])
        let web = try #require(result.items.first { $0.insert == "web" })
        #expect(web.detail == "profile: debug, dev")
        #expect(result.items.first { $0.insert == "cache" }?.detail == "compose service")
        #expect(inserts(complete("docker-compose logs pro", env: composeFixture)) == ["proxy"])
    }

    @Test func profileValuesAndComposeFileVariable() {
        #expect(inserts(complete("docker compose --profile ", env: composeFixture)) == ["debug", "dev", "batch"])
        #expect(inserts(complete("docker compose --profile b", env: composeFixture)) == ["batch"])
        let variable = env {
            $0.texts = composeFixture.texts
            $0.variables["COMPOSE_FILE"] = "alt.yml:extra/compose.yaml"
        }
        #expect(inserts(complete("docker compose up ", env: variable)) == ["alt-one", "proxy"])
        #expect(inserts(complete("docker compose -f alt.yml up a", env: composeFixture)) == ["alt-one"])
    }
}

struct CapturedEnvironmentTests {
    @Test func probeScriptsDumpTheEnvironment() throws {
        for shell in ["zsh", "bash", "fish"] {
            let script = try #require(SystemCompletionEnvironment.probeScript(shellName: shell))
            #expect(script.contains("env -0"), "\(shell)")
            #expect(script.contains("ENVBEGIN"))
            #expect(script.contains("ENVEND"))
        }
    }

    @Test func splitsTheEnvironmentBlockFromTheSymbols() {
        let output = "\u{1}a\u{1}gs\u{1}git status\nbanner\n\u{1}ENVBEGIN\u{2}A=1\0B=two words\0MULTI=line1\nline2=x\0\u{1}ENVEND\u{2}\n"
        let split = SystemCompletionEnvironment.splitEnvironment(output)
        #expect(split.environment == ["A": "1", "B": "two words", "MULTI": "line1\nline2=x"])
        #expect(!split.rest.contains("ENVBEGIN"))
        #expect(split.rest.contains("gs"))
        #expect(SystemCompletionEnvironment.splitEnvironment("no block").environment.isEmpty)
    }

    @Test func capturedValuesWinOverTheProcessEnvironment() {
        let environment = SystemCompletionEnvironment()
        let output = "\u{1}a\u{1}gs\u{1}git status\n\u{1}ENVBEGIN\u{2}HOME=/captured/home\0DOCKER_HOST=unix:///tmp/d.sock\0KUBECONFIG=/a:/b\0\u{1}ENVEND\u{2}\n"
        environment.parseProbe(output)
        let variables = environment.variables
        #expect(variables["HOME"] == "/captured/home")
        #expect(variables["DOCKER_HOST"] == "unix:///tmp/d.sock")
        #expect(variables["KUBECONFIG"] == "/a:/b")
        #expect(environment.processEnvironment()["DOCKER_HOST"] == "unix:///tmp/d.sock")
        #expect(environment.lookupCommand("gs", directory: "/") == .alias)
        #expect(DockerEngine.socketPath(variables: variables, home: "/h", readText: { _ in nil }, exists: { $0 == "/tmp/d.sock" }) == "/tmp/d.sock")
        #expect(KubeSources.kubeconfigPaths(variables: variables, home: "/h") == ["/a", "/b"])
    }

    @Test func nameOnlyVariablesAreNotPassedToChildren() {
        let environment = SystemCompletionEnvironment()
        environment.parseProbe("\u{1}v\u{1}ONLY_A_NAME\n")
        #expect(environment.variables["ONLY_A_NAME"] == "")
        #expect(environment.processEnvironment()["ONLY_A_NAME"] == nil)
    }
}

struct HelmSourceTests {
    private static let fixture: FakeEnvironment = env { value in
        value.texts["/home/tester/Library/Preferences/helm/repositories.yaml"] =
            "apiVersion: v1\nrepositories:\n- name: bitnami\n  url: https://x\n- name: stable\n  url: https://y\n"
        value.files["/home/tester/Library/Caches/helm/repository"] = [
            DirectoryEntry(name: "bitnami-index.yaml", isDirectory: false), DirectoryEntry(name: "stable-index.yaml", isDirectory: false),
        ]
        value.texts["/home/tester/Library/Caches/helm/repository/bitnami-index.yaml"] =
            "apiVersion: v1\nentries:\n  nginx:\n  - name: nginx\n    urls:\n    - https://a\n  redis:\n  - name: redis\ngenerated: x\n"
        value.texts["/home/tester/Library/Caches/helm/repository/stable-index.yaml"] = "entries:\n  chartmuseum:\n  - name: chartmuseum\n"
        value.listings[CLIListing.helmReleases(namespace: nil, context: nil, kubeconfig: nil)] = ["web", "db"]
        value.listings[CLIListing.helmReleases(namespace: "prod", context: "c1", kubeconfig: nil)] = ["api"]
        value.texts["/home/tester/.kube/config"] = "contexts:\n- context:\n    cluster: c\n  name: c1\n"
    }

    @Test func repositoriesAndCharts() {
        #expect(HelmSources.repositories(env: Self.fixture) == ["bitnami", "stable"])
        #expect(HelmSources.charts(env: Self.fixture) == ["bitnami/nginx", "bitnami/redis", "stable/chartmuseum"])
        #expect(inserts(complete("helm repo remove bi", env: Self.fixture)) == ["bitnami"])
        #expect(inserts(complete("helm repo update ", env: Self.fixture)) == ["bitnami", "stable"])
        #expect(inserts(complete("helm repo ", env: Self.fixture)).contains("add"))
        #expect(inserts(complete("helm install myrel bitnami/n", env: Self.fixture)) == ["bitnami/nginx"])
        #expect(inserts(complete("helm install myrel bit", env: Self.fixture)) == ["bitnami/nginx", "bitnami/redis", "bitnami/"])
        #expect(inserts(complete("helm show values stable/c", env: Self.fixture)) == ["stable/chartmuseum"])
        #expect(inserts(complete("helm show ", env: Self.fixture)).contains("values"))
        #expect(inserts(complete("helm pull bitnami/r", env: Self.fixture)) == ["bitnami/redis"])
    }

    @Test func releaseNamesUseTheReadOnlyListing() {
        #expect(inserts(complete("helm uninstall ", env: Self.fixture)) == ["web", "db"])
        #expect(inserts(complete("helm status w", env: Self.fixture)) == ["web"])
        #expect(inserts(complete("helm upgrade d", env: Self.fixture)) == ["db"])
        #expect(inserts(complete("helm get values w", env: Self.fixture)) == ["web"])
        #expect(inserts(complete("helm uninstall -n prod --kube-context c1 a", env: Self.fixture)) == ["api"])
        #expect(complete("helm uninstall zzz", env: Self.fixture) == nil)
    }

    @Test func namespaceAndContextOptions() {
        #expect(inserts(complete("helm --kube-context c", env: Self.fixture)) == ["c1"])
        #expect(inserts(complete("helm list -n kube-s", env: Self.fixture)) == ["kube-system"])
    }
}

struct CloudCliSourceTests {
    @Test func gcloudConfigurationsAndProjects() {
        let fixture = env { value in
            value.files["/home/tester/.config/gcloud/configurations"] = [
                DirectoryEntry(name: "config_default", isDirectory: false), DirectoryEntry(name: "config_work", isDirectory: false),
            ]
            value.texts["/home/tester/.config/gcloud/configurations/config_default"] = "[core]\nproject = proj-a\naccount = x\n"
            value.texts["/home/tester/.config/gcloud/configurations/config_work"] = "[core]\nproject = proj-b\n[compute]\nproject = ignored\n"
            value.texts["/home/tester/.config/gcloud/active_config"] = "work\n"
        }
        #expect(inserts(complete("gcloud config configurations activate w", env: fixture)) == ["work"])
        #expect(inserts(complete("gcloud --configuration d", env: fixture)) == ["default"])
        #expect(inserts(complete("gcloud config set project proj-", env: fixture)) == ["proj-a", "proj-b"])
        #expect(inserts(complete("gcloud --project proj-b", env: fixture)) == ["proj-b"])
        #expect(inserts(complete("gcloud projects describe p", env: fixture)) == ["proj-a", "proj-b"])
        #expect(inserts(complete("gcloud config ", env: fixture)).contains("configurations"))
        #expect(inserts(complete("gcloud config configurations ", env: fixture)).contains("activate"))
        #expect(inserts(complete("gcloud comp", env: fixture)) == ["compute", "components"])
        let custom = env {
            $0.variables["CLOUDSDK_CONFIG"] = "/cfg"
            $0.files["/cfg/configurations"] = [DirectoryEntry(name: "config_only", isDirectory: false)]
            $0.texts["/cfg/configurations/config_only"] = "[core]\nproject = custom-p\n"
        }
        #expect(inserts(complete("gcloud --project cu", env: custom)) == ["custom-p"])
    }

    @Test func azureSubscriptions() {
        let json = "\u{FEFF}{\"subscriptions\":[{\"id\":\"1111\",\"name\":\"Prod Sub\",\"isDefault\":true},{\"id\":\"2222\",\"name\":\"Dev\"}]}"
        let fixture = env { $0.texts["/home/tester/.azure/azureProfile.json"] = json }
        #expect(inserts(complete("az account set --subscription P", env: fixture)) == ["Prod\\ Sub"])
        #expect(inserts(complete("az --subscription 22", env: fixture)) == ["2222"])
        #expect(inserts(complete("az account ", env: fixture)).contains("set"))
        #expect(inserts(complete("az ac", env: fixture)) == ["account", "acr"])
        let moved = env { $0.variables["AZURE_CONFIG_DIR"] = "/az"; $0.texts["/az/azureProfile.json"] = json }
        #expect(inserts(complete("az -s D", env: moved)) == ["Dev"])
    }

    @Test func voltaTools() {
        let fixture = env { value in
            value.files["/home/tester/.volta/tools/image/packages"] = [DirectoryEntry(name: "typescript", isDirectory: true)]
            value.files["/home/tester/.volta/tools/image/node"] = [DirectoryEntry(name: "18.0.0", isDirectory: true), DirectoryEntry(name: "20.1.0", isDirectory: true)]
            value.files["/home/tester/.volta/tools/user/bins"] = [DirectoryEntry(name: "tsc.json", isDirectory: false)]
        }
        #expect(inserts(complete("volta install ty", env: fixture)) == ["typescript"])
        #expect(inserts(complete("volta install no", env: fixture)) == ["node"])
        #expect(inserts(complete("volta install node@2", env: fixture)) == ["node@20.1.0"])
        #expect(inserts(complete("volta uninstall t", env: fixture)) == ["typescript"])
        #expect(inserts(complete("volta which t", env: fixture)) == ["tsc"])
        #expect(inserts(complete("volta ins", env: fixture)) == ["install"])
        let moved = env { $0.variables["VOLTA_HOME"] = "/v"; $0.files["/v/tools/image/packages"] = [DirectoryEntry(name: "eslint", isDirectory: true)] }
        #expect(inserts(complete("volta uninstall e", env: moved)) == ["eslint"])
    }
}

struct AnsibleTests {
    private static let ini = """
    [web]
    web[01:03].example.com ansible_host=10.0.0.1
    db1

    [db]
    db1
    db2

    [prod:children]
    web
    db

    [web:vars]
    foo=bar
    """

    private static let yaml = """
    all:
      hosts:
        lone:
      children:
        app:
          hosts:
            app1:
              ansible_host: 1.2.3.4
            app2:
          vars:
            x: y
        cache:
          hosts:
            redis1:
    """

    @Test func parsesIniInventories() {
        let parsed = AnsibleInventory.parse(Self.ini)
        #expect(Set(parsed.hosts) == ["web01.example.com", "web02.example.com", "web03.example.com", "db1", "db2"])
        #expect(Set(parsed.groups) == ["web", "db", "prod"])
    }

    @Test func parsesYamlInventories() {
        let parsed = AnsibleInventory.parse(Self.yaml)
        #expect(Set(parsed.hosts) == ["lone", "app1", "app2", "redis1"])
        #expect(Set(parsed.groups) == ["all", "app", "cache"])
    }

    @Test func expandsRanges() {
        #expect(AnsibleInventory.expand("web[1:3]") == ["web1", "web2", "web3"])
        #expect(AnsibleInventory.expand("web[08:10].x") == ["web08.x", "web09.x", "web10.x"])
        #expect(AnsibleInventory.expand("db-[a:c]") == ["db-a", "db-b", "db-c"])
        #expect(AnsibleInventory.expand("plain") == ["plain"])
    }

    @Test func completesPatternsFromTheDefaultInventory() throws {
        let fixture = env { $0.texts["/work/inventory"] = Self.ini }
        let result = try #require(complete("ansible we", env: fixture))
        #expect(inserts(result) == ["web", "web01.example.com", "web02.example.com", "web03.example.com"])
        #expect(result.items[0].kind == .group)
        #expect(result.items[1].kind == .host)
        #expect(inserts(complete("ansible web:d", env: fixture)) == ["web:db", "web:db1", "web:db2"])
        #expect(inserts(complete("ansible-playbook site.yml -l db", env: fixture)) == ["db", "db1", "db2"])
        #expect(inserts(complete("ansible-playbook site.yml --limit=pr", env: fixture)) == ["prod"])
    }

    @Test func honoursExplicitAndConfiguredInventories() {
        let fixture = env { value in
            value.texts["/work/alt.ini"] = "[x]\nxh\n"
            value.texts["/work/ansible.cfg"] = "[defaults]\ninventory = hosts.ini\n"
            value.texts["/work/hosts.ini"] = "[cfggroup]\ncfghost\n"
            value.texts["/work/inventory"] = Self.ini
        }
        #expect(inserts(complete("ansible-playbook -i alt.ini -l x", env: fixture)) == ["x", "xh"])
        #expect(inserts(complete("ansible -i alt.ini x", env: fixture)) == ["x", "xh"])
        #expect(inserts(complete("ansible cfg", env: fixture)) == ["cfggroup", "cfghost"])
        #expect(inserts(complete("ansible -i h1,h2, h", env: fixture)) == ["h1", "h2"])
        let directory = env { value in
            value.files["/work/inv.d"] = [DirectoryEntry(name: "one", isDirectory: false)]
            value.texts["/work/inv.d/one"] = "[dg]\ndh\n"
        }
        #expect(inserts(complete("ansible --inventory inv.d d", env: directory)) == ["dg", "dh"])
    }
}

struct LanguageToolSourceTests {
    private static let workspace: FakeEnvironment = env { value in
        value.texts["/work/Cargo.toml"] = "[workspace]\nmembers = [\n  \"crates/*\",\n  \"tools/cli\",\n]\n\n[features]\nfast = []\nfull = [\"fast\"]\n\n[profile.release]\nlto = true\n[profile.bench-fast]\ninherits = \"release\"\n"
        value.files["/work/crates"] = [DirectoryEntry(name: "a", isDirectory: true), DirectoryEntry(name: "b", isDirectory: true)]
        value.texts["/work/crates/a/Cargo.toml"] = "[package]\nname = \"alpha\"\n"
        value.texts["/work/crates/b/Cargo.toml"] = "[package]\nname = \"beta\"\n"
        value.texts["/work/tools/cli/Cargo.toml"] = "[package]\nname = \"clitool\"\n"
        value.files["/work/crates/a/src"] = [DirectoryEntry(name: "main.rs", isDirectory: false)]
    }

    @Test func cargoWorkspaceMembersFeaturesAndProfiles() {
        #expect(inserts(complete("cargo build -p al", env: Self.workspace)) == ["alpha"])
        #expect(inserts(complete("cargo build --package=c", env: Self.workspace)) == ["clitool"])
        #expect(inserts(complete("cargo test --package ", env: Self.workspace)) == ["alpha", "beta", "clitool"])
        #expect(inserts(complete("cargo build --features f", env: Self.workspace)) == ["fast", "full"])
        #expect(inserts(complete("cargo build --features fast,fu", env: Self.workspace)) == ["fast,full"])
        #expect(inserts(complete("cargo build --profile r", env: Self.workspace)) == ["release"])
        #expect(inserts(complete("cargo build --profile b", env: Self.workspace)) == ["bench", "bench-fast"])
        #expect(inserts(complete("cargo run --bin al", env: Self.workspace)) == ["alpha"])
    }

    private static let node: FakeEnvironment = env { value in
        value.texts["/work/package.json"] = #"{"dependencies":{"react":"1"},"devDependencies":{"vite":"1","vitest":"1"},"scripts":{"dev":"vite"}}"#
        value.files["/work/node_modules/.bin"] = [
            DirectoryEntry(name: "tsc", isDirectory: false), DirectoryEntry(name: "eslint", isDirectory: false),
            DirectoryEntry(name: ".bin-hidden", isDirectory: false),
        ]
    }

    @Test func npmDependenciesAndLocalBinaries() {
        #expect(inserts(complete("npm uninstall v", env: Self.node)) == ["vite", "vitest"])
        #expect(inserts(complete("yarn remove re", env: Self.node)) == ["react"])
        #expect(inserts(complete("pnpm update ", env: Self.node)) == ["react", "vite", "vitest"])
        #expect(inserts(complete("npx es", env: Self.node)) == ["eslint"])
        #expect(inserts(complete("npm exec ts", env: Self.node)) == ["tsc"])
        #expect(inserts(complete("npx es", env: Self.node, directory: "/work/src")) == ["eslint"])
        #expect(complete("npx zzz", env: Self.node) == nil)
    }

    @Test func pipFileOptionsAndMultiplePackages() {
        let fixture = env { value in
            value.variables["VIRTUAL_ENV"] = "/venv"
            value.files["/venv/lib"] = [DirectoryEntry(name: "python3.12", isDirectory: true)]
            value.files["/venv/lib/python3.12/site-packages"] = [
                DirectoryEntry(name: "Flask-3.0.0.dist-info", isDirectory: true), DirectoryEntry(name: "requests-2.31.0.dist-info", isDirectory: true),
            ]
        }
        #expect(inserts(complete("pip install -r no", env: fixture)) == ["notes.txt"])
        #expect(inserts(complete("pip3 install --target s", env: fixture)) == ["src/"])
        #expect(inserts(complete("pip uninstall Flask re", env: fixture)) == ["requests"])
    }

    @Test func brewTapsAndServices() {
        let fixture = env { value in
            value.files["/opt/homebrew/Library/Taps"] = [DirectoryEntry(name: "homebrew", isDirectory: true), DirectoryEntry(name: "acme", isDirectory: true)]
            value.files["/opt/homebrew/Library/Taps/homebrew"] = [DirectoryEntry(name: "homebrew-core", isDirectory: true), DirectoryEntry(name: "homebrew-cask", isDirectory: true)]
            value.files["/opt/homebrew/Library/Taps/acme"] = [DirectoryEntry(name: "homebrew-tools", isDirectory: true)]
            value.files["/opt/homebrew/Cellar"] = [DirectoryEntry(name: "postgresql@16", isDirectory: true), DirectoryEntry(name: "wget", isDirectory: true)]
        }
        #expect(inserts(complete("brew untap ", env: fixture)) == ["acme/tools", "homebrew/cask", "homebrew/core"])
        #expect(inserts(complete("brew services ", env: fixture)).contains("start"))
        #expect(inserts(complete("brew services restart post", env: fixture)) == ["postgresql@16"])
    }

    @Test func awsServicesAndOperationsFromTheInstalledIndex() {
        let root = "/opt/homebrew/opt/awscli/libexec/lib/python3.12/site-packages/botocore/data"
        let fixture = env { value in
            value.files["/opt/homebrew/opt/awscli/libexec/lib"] = [DirectoryEntry(name: "python3.12", isDirectory: true)]
            value.files[root] = [
                DirectoryEntry(name: "s3", isDirectory: true), DirectoryEntry(name: "ec2", isDirectory: true),
                DirectoryEntry(name: "frobnicate", isDirectory: true), DirectoryEntry(name: "_retry.json", isDirectory: false),
            ]
            value.files[root + "/ec2"] = [DirectoryEntry(name: "2015-10-01", isDirectory: true), DirectoryEntry(name: "2016-11-15", isDirectory: true)]
            value.texts[root + "/ec2/2016-11-15/service-2.json"] = #"{"operations":{"DescribeInstances":{},"RunInstances":{},"DescribeDBInstances":{}}}"#
        }
        #expect(inserts(complete("aws fro", env: fixture)) == ["frobnicate"])
        #expect(inserts(complete("aws s3a", env: fixture)) == ["s3api"])
        #expect(inserts(complete("aws ec2 desc", env: fixture)) == ["describe-db-instances", "describe-instances"])
        #expect(inserts(complete("aws ec2 r", env: fixture)) == ["run-instances"])
        #expect(inserts(complete("aws s3 s", env: fixture)) == ["sync"])
        #expect(AWSIndex.kebab("DescribeDBInstances") == "describe-db-instances")
        #expect(AWSIndex.kebab("ListObjectsV2") == "list-objects-v2")
        #expect(complete("aws ec2 zzz", env: fixture) == nil)
    }
}

struct SQLiteFixtureError: Error {}

private func makeSQLite(_ statements: [String]) throws -> String {
    let path = NSTemporaryDirectory() + "turm-ac-" + UUID().uuidString + ".index"
    var database: OpaquePointer?
    guard sqlite3_open(path, &database) == SQLITE_OK else { throw SQLiteFixtureError() }
    defer { sqlite3_close(database) }
    for statement in statements {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw SQLiteFixtureError() }
    }
    return path
}

private let awsSchema = [
    "CREATE TABLE command_table (parent TEXT, command TEXT, command_type TEXT, help_summary TEXT, UNIQUE (parent, command))",
    "CREATE TABLE param_table (parent TEXT, command TEXT, arg_name TEXT, type_name TEXT, nargs TEXT, positional_arg BOOLEAN, required BOOLEAN, help_summary TEXT, UNIQUE (parent, command, arg_name))",
]

private func makeAWSIndex() throws -> String {
    try makeSQLite(awsSchema + [
        "INSERT INTO command_table VALUES ('aws', 'ec2', 'service', 'Amazon Elastic Compute Cloud')",
        "INSERT INTO command_table VALUES ('aws', 's3', 'service', 'Amazon S3')",
        "INSERT INTO command_table VALUES ('aws', 's3api', 'service', 'S3 API')",
        "INSERT INTO command_table VALUES ('aws', 'frobnicate', 'service', 'Frobnicate service')",
        "INSERT INTO command_table VALUES ('aws.ec2', 'describe-instances', 'operation', 'Describes the specified instances.')",
        "INSERT INTO command_table VALUES ('aws.ec2', 'run-instances', 'operation', 'Launches instances' || char(10) || 'multi-line.')",
        "INSERT INTO command_table VALUES ('aws.s3', 'ls', 'command', 'List objects')",
        "INSERT INTO param_table VALUES ('aws', '', '--profile', 'string', '1', 0, 0, 'Use a specific profile')",
        "INSERT INTO param_table VALUES ('aws', '', '--debug', 'boolean', '0', 0, 0, 'Turn on debug logging')",
        "INSERT INTO param_table VALUES ('aws.ec2', 'describe-instances', '--filters', 'list', '*', 0, 0, 'The filters.')",
        "INSERT INTO param_table VALUES ('aws.ec2', 'describe-instances', '--dry-run', 'boolean', '0', 0, 0, 'Checks permissions.')",
        "INSERT INTO param_table VALUES ('aws.ec2', 'describe-instances', 'instance-ids', 'list', '*', 0, 0, 'IDs without dashes')",
        "INSERT INTO param_table VALUES ('aws.ec2', 'describe-instances', '--positional', 'string', '1', 1, 0, 'excluded')",
    ])
}

struct AWSCompletionIndexTests {
    @Test func readsServicesAndOperationsWithDescriptions() throws {
        let path = try makeAWSIndex()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let services = AWSCompletionIndex.commands(path: path, parent: "aws")
        #expect(services.map { $0.name } == ["ec2", "frobnicate", "s3", "s3api"])
        #expect(services.first?.detail == "Amazon Elastic Compute Cloud")
        #expect(services.first?.type == "service")
        let operations = AWSCompletionIndex.commands(path: path, parent: "aws.ec2")
        #expect(operations.map { $0.name } == ["describe-instances", "run-instances"])
        #expect(operations[1].detail == "Launches instances multi-line.")
    }

    @Test func readsOptionsSkippingPositionalsAndNormalisingNames() throws {
        let path = try makeAWSIndex()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let options = AWSCompletionIndex.options(path: path, parent: "aws.ec2", command: "describe-instances")
        #expect(options.map { $0.name } == ["--dry-run", "--filters", "--instance-ids"])
        #expect(options.map { $0.type } == ["boolean", "list", "list"])
        let global = AWSCompletionIndex.options(path: path, parent: "aws", command: "")
        #expect(global.map { $0.name } == ["--debug", "--profile"])
    }

    @Test func readsTheRealAwsCliIndexSchema() throws {
        let path = try makeSQLite([
            "CREATE TABLE command_table (command TEXT, full_name TEXT, parent TEXT REFERENCES command_table, PRIMARY KEY (command, parent))",
            "CREATE TABLE param_table (param_id INTEGER PRIMARY KEY, argname TEXT, type_name TEXT, command TEXT, parent TEXT, nargs TEXT, positional_arg TEXT, required INTEGER)",
            "INSERT INTO command_table VALUES ('aws', NULL, '')",
            "INSERT INTO command_table VALUES ('ec2', 'Amazon Elastic Compute Cloud', 'aws')",
            "INSERT INTO command_table VALUES ('s3', 'Amazon Simple Storage Service', 'aws')",
            "INSERT INTO command_table VALUES ('describe-instances', NULL, 'aws.ec2')",
            "INSERT INTO param_table (argname, type_name, command, parent, nargs, positional_arg, required) VALUES ('profile', 'string', 'aws', '', '1', NULL, 0)",
            "INSERT INTO param_table (argname, type_name, command, parent, nargs, positional_arg, required) VALUES ('debug', 'boolean', 'aws', '', '0', NULL, 0)",
            "INSERT INTO param_table (argname, type_name, command, parent, nargs, positional_arg, required) VALUES ('instance-ids', 'list', 'describe-instances', 'aws.ec2', '*', NULL, 0)",
            "INSERT INTO param_table (argname, type_name, command, parent, nargs, positional_arg, required) VALUES ('path', 'string', 'describe-instances', 'aws.ec2', '1', 'path', 1)",
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let services = AWSCompletionIndex.commands(path: path, parent: "aws")
        #expect(services.map { $0.name } == ["ec2", "s3"])
        #expect(services.first?.detail == "Amazon Elastic Compute Cloud")
        #expect(AWSCompletionIndex.commands(path: path, parent: "aws.ec2").map { $0.name } == ["describe-instances"])
        #expect(AWSCompletionIndex.options(path: path, parent: "aws.ec2", command: "describe-instances").map { $0.name } == ["--instance-ids"])
        #expect(AWSCompletionIndex.options(path: path, parent: "aws", command: "").map { $0.name } == ["--debug", "--profile"])
    }

    @Test func toleratesMissingColumnsSpacedParentsAndBadFiles() throws {
        let plain = try makeSQLite([
            "CREATE TABLE command_table (parent TEXT, command TEXT)",
            "INSERT INTO command_table VALUES ('aws ec2', 'run-instances')",
        ])
        defer { try? FileManager.default.removeItem(atPath: plain) }
        let found = AWSCompletionIndex.commands(path: plain, parent: "aws.ec2")
        #expect(found == [AWSIndexEntry(name: "run-instances", detail: nil, type: nil)])
        #expect(AWSCompletionIndex.options(path: plain, parent: "aws.ec2", command: "run-instances").isEmpty)

        let garbage = NSTemporaryDirectory() + "turm-garbage-" + UUID().uuidString
        try "not a database".write(toFile: garbage, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: garbage) }
        #expect(AWSCompletionIndex.commands(path: garbage, parent: "aws").isEmpty)
        #expect(AWSCompletionIndex.commands(path: "/nonexistent/ac.index", parent: "aws").isEmpty)
    }

    @Test func findsTheIndexInKnownInstallLocations() {
        var brew = FakeEnvironment.standard
        let brewPath = "/opt/homebrew/opt/awscli/libexec/lib/python3.12/site-packages/awscli/data/ac.index"
        brew.files["/opt/homebrew/opt/awscli/libexec/lib"] = [DirectoryEntry(name: "python3.12", isDirectory: true)]
        brew.texts[brewPath] = ""
        #expect(AWSCompletionIndex.locate(brew) == brewPath)

        var bundled = FakeEnvironment.standard
        let bundledPath = "/usr/local/aws-cli/v2/2.15.0/dist/awscli/data/ac.index"
        bundled.files["/usr/local/aws-cli/v2"] = [DirectoryEntry(name: "2.15.0", isDirectory: true)]
        bundled.texts[bundledPath] = ""
        #expect(AWSCompletionIndex.locate(bundled) == bundledPath)
        #expect(AWSCompletionIndex.locate(FakeEnvironment.standard) == nil)
    }

    @Test func completionUsesTheIndexAndKeepsTheStaticFallback() throws {
        let path = try makeAWSIndex()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fixture = env { $0.awsIndex = path }
        #expect(inserts(complete("aws fro", env: fixture)) == ["frobnicate"])
        let services = try #require(complete("aws ec", env: fixture))
        #expect(inserts(services) == ["ec2", "ecr", "ecs"])
        #expect(services.items[0].detail == "Amazon Elastic Compute Cloud")
        let operations = try #require(complete("aws ec2 desc", env: fixture))
        #expect(inserts(operations) == ["describe-instances"])
        #expect(operations.items[0].detail == "Describes the specified instances.")
        #expect(inserts(complete("aws ec2 r", env: fixture)) == ["run-instances"])
        #expect(inserts(complete("aws s3 l", env: fixture)) == ["ls"])
        #expect(inserts(complete("aws s", env: FakeEnvironment.standard)).contains("s3"))
        #expect(complete("aws ec2 zzz", env: fixture) == nil)
    }

    @Test func optionsComeFromTheIndex() throws {
        let path = try makeAWSIndex()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fixture = env { $0.awsIndex = path }
        #expect(inserts(complete("aws ec2 describe-instances --f", env: fixture)) == ["--filters"])
        #expect(inserts(complete("aws ec2 describe-instances --dry", env: fixture)) == ["--dry-run"])
        #expect(inserts(complete("aws --pro", env: fixture)) == ["--profile"])
        let flags = CommandCompleter.flags(command: "aws", args: ["ec2", "describe-instances"], env: fixture)
        let byName = Dictionary(uniqueKeysWithValues: flags.map { ($0.name, $0) })
        #expect(byName["--dry-run"]?.takesValue == false)
        #expect(byName["--debug"]?.takesValue == false)
        #expect(byName["--filters"]?.takesValue == true)
        #expect(byName["--profile"]?.detail == "Use a specific profile")
    }
}

struct ProcessEnvironmentReaderTests {
    private func buffer(argc: Int32, path: String, arguments: [String], environment: [String], apple: [String] = []) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(path.utf8) + [0, 0, 0]
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        for entry in environment { bytes += Array(entry.utf8) + [0] }
        bytes += [0]
        for entry in apple { bytes += Array(entry.utf8) + [0] }
        return bytes
    }

    @Test func parsesArgumentsAndEnvironment() throws {
        let bytes = buffer(
            argc: 2, path: "/bin/zsh", arguments: ["-zsh", "-l"],
            environment: ["HOME=/Users/x", "MULTI=a=b", "NOEQUALS", "=novalue", "EMPTY="],
            apple: ["executable_path=/bin/zsh"]
        )
        let parsed = try #require(ProcessEnvironmentReader.parse(bytes))
        #expect(parsed.arguments == ["-zsh", "-l"])
        #expect(parsed.environment == ["HOME": "/Users/x", "MULTI": "a=b", "EMPTY": ""])
    }

    @Test func handlesNoArgumentsAndValuesWithSpacesAndUnicode() throws {
        let bytes = buffer(argc: 0, path: "/bin/sh", arguments: [], environment: ["A=one two", "B=h\u{E9}llo"])
        let parsed = try #require(ProcessEnvironmentReader.parse(bytes))
        #expect(parsed.arguments.isEmpty)
        #expect(parsed.environment == ["A": "one two", "B": "h\u{E9}llo"])
    }

    @Test func rejectsTruncatedOrImplausibleBuffers() {
        #expect(ProcessEnvironmentReader.parse([]) == nil)
        #expect(ProcessEnvironmentReader.parse([1, 0, 0]) == nil)
        let short = buffer(argc: 5, path: "/bin/sh", arguments: ["sh"], environment: [])
        #expect(ProcessEnvironmentReader.parse(short) == nil)
        let negative = buffer(argc: -1, path: "/bin/sh", arguments: [], environment: [])
        #expect(ProcessEnvironmentReader.parse(negative) == nil)
    }

    @Test func readsTheCurrentProcessThroughSysctl() {
        let environment = ProcessEnvironmentReader.read(pid: getpid())
        #expect(environment?.isEmpty == false)
        #expect(ProcessEnvironmentReader.read(pid: 0x7ffffff0) == nil)
    }
}

struct EnvironmentRefreshPolicyTests {
    @Test func stalenessUsesSixtySeconds() {
        let start = Date(timeIntervalSince1970: 5_000)
        #expect(EnvironmentRefreshPolicy.isStale(lastCapture: nil, now: start))
        #expect(!EnvironmentRefreshPolicy.isStale(lastCapture: start, now: start.addingTimeInterval(59)))
        #expect(!EnvironmentRefreshPolicy.isStale(lastCapture: start, now: start.addingTimeInterval(60)))
        #expect(EnvironmentRefreshPolicy.isStale(lastCapture: start, now: start.addingTimeInterval(61)))
    }

    private func changes(_ text: String, directory: String = "/work", shell: String = "zsh", envFiles: Set<String> = []) -> Bool {
        EnvironmentRefreshPolicy.commandMayChangeEnvironment(text, directory: directory, shell: shell, hasEnvFile: { envFiles.contains($0) })
    }

    @Test func recognisesEnvironmentChangingCommands() {
        for text in [
            "export FOO=1", "source ~/.zshrc", ". ./env.sh", "eval \"$(direnv hook zsh)\"", "direnv allow", "nvm use 20",
            "fnm use 20", "pyenv shell 3.11", "conda activate base", "FOO=1 export BAR=2", "cd proj && export A=1",
            "ls | grep x; source env", "unset FOO", "sudo -E true; mamba activate x", "asdf shell nodejs 20",
        ] {
            #expect(changes(text), "\(text)")
        }
    }

    @Test func ignoresPlainCommands() {
        for text in ["ls -la", "echo export", "cat .env", "git status | grep source", "grep -r eval src", "make test", "", "echo hi > out"] {
            #expect(!changes(text), "\(text)")
        }
    }

    @Test func cdIntoDirectoriesWithEnvFiles() {
        #expect(changes("cd proj", envFiles: ["/work/.envrc"]))
        #expect(changes("pushd proj", envFiles: ["/work/.env"]))
        #expect(!changes("cd proj"))
        #expect(!changes("ls", envFiles: ["/work/.envrc"]))
    }

    @Test func fishSetWithExportFlag() {
        #expect(changes("set -x FOO 1", shell: "fish"))
        #expect(changes("set -gx PATH /x $PATH", shell: "fish"))
        #expect(changes("set -Ux EDITOR vim", shell: "fish"))
        #expect(!changes("set FOO 1", shell: "fish"))
        #expect(!changes("set --global FOO 1", shell: "fish"))
        #expect(!changes("set -x FOO 1", shell: "zsh"))
    }
}

nonisolated final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct EnvironmentRefreshTests {
    private func makeEnvironment(clock: TestClock, counter: ProbeCounter, path: String = "/a") -> SystemCompletionEnvironment {
        SystemCompletionEnvironment(clock: { clock.date }, probe: {
            let n = counter.next()
            return "\u{1}ENVBEGIN\u{2}TURM_GEN=\(n)\0PATH=\(path)\0\u{1}ENVEND\u{2}"
        })
    }

    @Test func refreshesOnlyWhenTheCaptureIsOlderThanSixtySeconds() {
        let clock = TestClock()
        let counter = ProbeCounter()
        let environment = makeEnvironment(clock: clock, counter: counter)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 1)
        #expect(environment.variables["TURM_GEN"] == "1")
        clock.advance(30)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 1)
        clock.advance(31)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 2)
        #expect(environment.variables["TURM_GEN"] == "2")
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 2)
    }

    @Test func refreshesRightAfterEnvironmentChangingCommands() {
        let clock = TestClock()
        let counter = ProbeCounter()
        let environment = makeEnvironment(clock: clock, counter: counter)
        environment.refreshEnvironment(wait: true)
        #expect(counter.count == 1)
        environment.commandFinished("ls -la", directory: NSTemporaryDirectory(), wait: true)
        #expect(counter.count == 1)
        environment.commandFinished("export FOO=1", directory: NSTemporaryDirectory(), wait: true)
        #expect(counter.count == 2)
        #expect(environment.variables["TURM_GEN"] == "2")
        environment.commandFinished("source ~/.zshrc", directory: NSTemporaryDirectory(), wait: true)
        environment.commandFinished("nvm use 20", directory: NSTemporaryDirectory(), wait: true)
        #expect(counter.count == 4)
        environment.commandFinished("cd /tmp", directory: NSTemporaryDirectory(), wait: true)
        #expect(counter.count == 4)
    }

    @Test func aFailingProbeStillStampsTheCapture() {
        let clock = TestClock()
        let counter = ProbeCounter()
        let environment = SystemCompletionEnvironment(clock: { clock.date }, probe: {
            _ = counter.next()
            return nil
        })
        environment.refreshIfStale(wait: true)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 1)
        clock.advance(61)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 2)
    }

    @Test func liveShellEnvironmentIsLayeredUnderTheProbe() {
        let clock = TestClock()
        let environment = SystemCompletionEnvironment(clock: { clock.date }, probe: {
            "\u{1}ENVBEGIN\u{2}HOME=/probe/home\0\u{1}ENVEND\u{2}"
        })
        environment.setShellProcess(pid: getpid())
        environment.refreshEnvironment(wait: true)
        let variables = environment.variables
        #expect(variables["HOME"] == "/probe/home")
        #expect(environment.processEnvironment()["HOME"] == "/probe/home")
    }

    @Test func pathChangesAreDetectedAcrossRefreshes() {
        let clock = TestClock()
        let counter = ProbeCounter()
        let environment = makeEnvironment(clock: clock, counter: counter, path: "/one:/two")
        environment.refreshEnvironment(wait: true)
        #expect(environment.variables["PATH"] == "/one:/two")
    }
}

struct LiveEnvironmentTests {
    @Test func liveValuesLayerAboveTheProbeAndLaunchEnvironment() {
        let clock = TestClock()
        let environment = SystemCompletionEnvironment(clock: { clock.date }, probe: {
            "\u{1}ENVBEGIN\u{2}HOME=/probe/home\0A=probe\0ONLY_PROBE=1\0\u{1}ENVEND\u{2}"
        })
        environment.setShellProcess(pid: getpid())
        environment.refreshEnvironment(wait: true)
        #expect(environment.variables["HOME"] == "/probe/home")
        environment.applyLiveEnvironment(["A": "live", "B": "live-only"], merge: true, wait: true)
        let variables = environment.variables
        #expect(variables["A"] == "live")
        #expect(variables["B"] == "live-only")
        #expect(variables["HOME"] == "/probe/home")
        #expect(variables["ONLY_PROBE"] == "1")
        let child = environment.processEnvironment()
        #expect(child["A"] == "live")
        #expect(child["B"] == "live-only")
        environment.applyLiveEnvironment(["A": "newer"], merge: true, wait: true)
        #expect(environment.variables["A"] == "newer")
        #expect(environment.variables["B"] == "live-only")
    }

    @Test func applyingStampsTheCaptureTimeAndSurvivesLaterProbes() {
        let clock = TestClock()
        let counter = ProbeCounter()
        let environment = SystemCompletionEnvironment(clock: { clock.date }, probe: {
            "\u{1}ENVBEGIN\u{2}A=probe\(counter.next())\0\u{1}ENVEND\u{2}"
        })
        environment.applyLiveEnvironment(["A": "live"], merge: true, wait: true)
        clock.advance(30)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 0)
        clock.advance(31)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 1)
        #expect(environment.variables["A"] == "live")
    }

    @Test func pathChangesTriggerARescanAndUnchangedPathsDoNot() throws {
        let directory = NSTemporaryDirectory() + "turm-live-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        func makeTool(_ name: String) {
            let path = directory + "/" + name
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        makeTool("turm-live-tool")
        let environment = SystemCompletionEnvironment(clock: { Date() }, probe: { nil })
        environment.applyLiveEnvironment(["PATH": directory], merge: true, wait: true)
        #expect(environment.commandSymbols().contains { $0.name == "turm-live-tool" && $0.kind == .executable })
        #expect(environment.lookupCommand("turm-live-tool", directory: "/") == .executable)
        makeTool("turm-second-tool")
        environment.applyLiveEnvironment(["PATH": directory, "OTHER": "1"], merge: true, wait: true)
        #expect(!environment.commandSymbols().contains { $0.name == "turm-second-tool" })
        environment.applyLiveEnvironment(["PATH": directory + ":/nonexistent-turm-dir"], merge: true, wait: true)
        #expect(environment.commandSymbols().contains { $0.name == "turm-second-tool" })
    }

    @Test func concurrentApplicationsAreThreadSafe() {
        let environment = SystemCompletionEnvironment(clock: { Date() }, probe: { nil })
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            environment.applyLiveEnvironment(["KEY_\(index)": "\(index)"], merge: true, wait: true)
            _ = environment.variables
        }
        let variables = environment.variables
        for index in 0..<64 {
            #expect(variables["KEY_\(index)"] == "\(index)")
        }
    }
}

struct LiveSnapshotTests {
    private func probed(_ clock: TestClock, counter: ProbeCounter? = nil) -> SystemCompletionEnvironment {
        SystemCompletionEnvironment(clock: { clock.date }, probe: {
            _ = counter?.next()
            return "\u{1}v\u{1}NAME_ONLY\n\u{1}ENVBEGIN\u{2}KUBECONFIG=/probe/kube\0KEEP=probe\0HOME=/probe/home\0\u{1}ENVEND\u{2}"
        })
    }

    @Test func snapshotsReplaceAndUnsetVariables() {
        let environment = probed(TestClock())
        environment.refreshEnvironment(wait: true)
        #expect(environment.variables["KUBECONFIG"] == "/probe/kube")
        environment.applyLiveEnvironment(["KEEP": "live", "NEW": "1"], wait: true)
        let variables = environment.variables
        #expect(variables["KUBECONFIG"] == nil)
        #expect(variables["HOME"] == nil)
        #expect(variables["KEEP"] == "live")
        #expect(variables["NEW"] == "1")
        #expect(environment.processEnvironment()["KUBECONFIG"] == nil)
        #expect(environment.processEnvironment() == ["KEEP": "live", "NEW": "1"])
    }

    @Test func nameOnlyShellVariablesSurviveASnapshot() {
        let environment = probed(TestClock())
        environment.refreshEnvironment(wait: true)
        environment.applyLiveEnvironment(["A": "1"], wait: true)
        #expect(environment.variables["NAME_ONLY"] == "")
        #expect(environment.processEnvironment()["NAME_ONLY"] == nil)
    }

    @Test func nextSnapshotReplacesThePreviousOneWhileMergeAddsToIt() {
        let environment = probed(TestClock())
        environment.applyLiveEnvironment(["A": "1", "B": "2"], wait: true)
        environment.applyLiveEnvironment(["C": "3"], merge: true, wait: true)
        #expect(environment.processEnvironment() == ["A": "1", "B": "2", "C": "3"])
        environment.applyLiveEnvironment(["B": "20"], wait: true)
        #expect(environment.processEnvironment() == ["B": "20"])
        environment.applyLiveEnvironment([:], wait: true)
        #expect(environment.processEnvironment().isEmpty)
    }

    @Test func fallbackLayersApplyUntilTheFirstSnapshot() {
        let environment = probed(TestClock())
        environment.refreshEnvironment(wait: true)
        environment.applyLiveEnvironment(["EXTRA": "delta"], merge: true, wait: true)
        #expect(environment.variables["HOME"] == "/probe/home")
        #expect(environment.variables["EXTRA"] == "delta")
        environment.applyLiveEnvironment(["ONLY": "1"], wait: true)
        #expect(environment.variables["HOME"] == nil)
        #expect(environment.variables["EXTRA"] == nil)
    }

    @Test func laterProbesDoNotOverrideASnapshot() {
        let clock = TestClock()
        let counter = ProbeCounter()
        let environment = probed(clock, counter: counter)
        environment.applyLiveEnvironment(["A": "1"], wait: true)
        clock.advance(61)
        environment.refreshIfStale(wait: true)
        #expect(counter.count == 1)
        #expect(environment.processEnvironment() == ["A": "1"])
    }

    @Test func snapshotsThatChangePathRescanAgainstThePreviousEffectivePath() throws {
        let directory = NSTemporaryDirectory() + "turm-snap-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        func makeTool(_ name: String) {
            FileManager.default.createFile(atPath: directory + "/" + name, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        makeTool("turm-snap-tool")
        let environment = SystemCompletionEnvironment(clock: { Date() }, probe: { nil })
        environment.applyLiveEnvironment(["PATH": directory], wait: true)
        #expect(environment.commandSymbols().contains { $0.name == "turm-snap-tool" })
        makeTool("turm-snap-late")
        environment.applyLiveEnvironment(["PATH": directory, "X": "1"], wait: true)
        #expect(!environment.commandSymbols().contains { $0.name == "turm-snap-late" })
        environment.applyLiveEnvironment(["PATH": directory + ":/nonexistent-turm-dir"], wait: true)
        #expect(environment.commandSymbols().contains { $0.name == "turm-snap-late" })
        #expect(environment.processEnvironment()["PATH"] == directory + ":/nonexistent-turm-dir")
        environment.applyLiveEnvironment(["HOME": "/h"], wait: true)
        #expect(environment.processEnvironment()["PATH"] == nil)
    }
}
