import Foundation

nonisolated enum CommandCompleter {
    static let commandNameCommands: Set<String> = ["man", "which", "type", "whereis", "where", "whence", "help", "hash"]
    static let directoryCommands: Set<String> = ["cd", "pushd", "popd", "chdir", "rmdir"]
    static let variableCommands: Set<String> = ["export", "unset", "printenv", "typeset", "declare", "readonly", "local"]
    static let maxItems = 300

    static func complete(
        line: String,
        cursor: String.Index,
        directory: String,
        history: [String],
        environment env: CompletionEnvironment
    ) -> CompletionResult? {
        let prefix = String(line[..<cursor])
        var tokens = ShellTokenizer.tokenize(prefix)
        if tokens.contains(where: { $0.kind == .comment }) { return nil }

        var current: ShellToken?
        if let last = tokens.last, last.kind == .word, last.range.upperBound == prefix.endIndex {
            current = last
            tokens.removeLast()
        }
        if let word = current, !isCompletable(word) { return nil }

        let raw = current?.text ?? ""
        let wordStart = current?.range.lowerBound ?? prefix.endIndex
        func map(_ index: String.Index) -> String.Index {
            String.Index(utf16Offset: prefix.utf16.distance(from: prefix.startIndex, to: index), in: line)
        }
        let wordRange = map(wordStart)..<cursor

        if let variable = variableContext(raw: raw, quote: quoteCharacter(current)) {
            let names = env.variables.keys.filter { $0.hasPrefix(variable.name) }.sorted()
            let items = names.prefix(maxItems).map { name in
                CompletionItem(
                    insert: name + (variable.braced ? "}" : ""),
                    display: name,
                    kind: .variable,
                    detail: env.variables[name].flatMap(shortValue),
                    terminator: ""
                )
            }
            guard !items.isEmpty else { return nil }
            let offset = raw.distance(from: raw.startIndex, to: variable.nameStart)
            let start = prefix.index(wordStart, offsetBy: offset)
            return CompletionResult(range: map(start)..<cursor, items: Array(items))
        }

        let segment = currentSegment(tokens)
        var words: [ShellToken] = []
        var awaitingTarget = false
        for token in segment {
            if token.kind == .op, token.isRedirect {
                awaitingTarget = !hasInlineTarget(token.text)
            } else if awaitingTarget {
                awaitingTarget = false
            } else if token.kind == .word {
                words.append(token)
            }
        }

        var range = wordRange
        let items: [CompletionItem]
        if awaitingTarget {
            items = pathItems(word: current, directory: directory, env: env, directoriesOnly: false)
        } else {
            let scan = CommandScanner.commandIndex(in: words)
            if let commandAt = scan.index {
                let name = (words[commandAt].value as NSString).lastPathComponent
                let command = env.aliasTarget(of: name) ?? name
                let args = words[(commandAt + 1)...].map(\.value)
                var valueToken = current
                var valueRaw = raw
                var optionName: String?
                if raw.hasPrefix("--"), quoteCharacter(current) == nil, let equals = raw.firstIndex(of: "=") {
                    optionName = String(raw[..<equals])
                    valueRaw = String(raw[raw.index(after: equals)...])
                    valueToken = ShellTokenizer.tokenize(valueRaw).first { $0.kind == .word }
                    let offset = raw.distance(from: raw.startIndex, to: raw.index(after: equals))
                    range = map(prefix.index(wordStart, offsetBy: offset))..<cursor
                }
                items = argumentItems(
                    command: command, args: args, current: valueToken, raw: valueRaw, optionName: optionName,
                    directory: directory, env: env
                )
            } else if scan.scanner.pendingOption != nil {
                items = valueItems(scan.scanner.pendingKind ?? .text, current: current, directory: directory, env: env)
            } else if let wrapper = scan.scanner.wrapper, raw.hasPrefix("-") {
                items = flagItems(prefix: raw, flags: env.commandSpec(forCommand: wrapper).flags)
            } else if scan.scanner.positionalsLeft > 0 {
                items = []
            } else {
                let value = current?.value ?? ""
                if value.isEmpty { return nil }
                if value.contains("/") || value.hasPrefix("~") || value.hasPrefix(".") {
                    items = pathItems(word: current, directory: directory, env: env, directoriesOnly: false)
                } else {
                    items = commandItems(prefix: value, env: env, history: history)
                }
            }
        }
        guard !items.isEmpty else { return nil }
        return CompletionResult(range: range, items: Array(items.prefix(maxItems)))
    }

    static func isCompletable(_ word: ShellToken) -> Bool {
        let quoted = word.parts.contains { $0.kind == .singleQuoted || $0.kind == .doubleQuoted }
        if quoted { return quoteCharacter(word) != nil }
        if let last = word.parts.last, last.kind == .substitution, word.unterminated { return false }
        return true
    }

    static func quoteCharacter(_ word: ShellToken?) -> Character? {
        guard let word, let first = word.parts.first, first.unterminated else { return nil }
        switch first.kind {
        case .singleQuoted: return "'"
        case .doubleQuoted: return "\""
        default: return nil
        }
    }

    static func hasInlineTarget(_ op: String) -> Bool {
        guard op.contains("&"), let last = op.last else { return false }
        return last == "-" || (last.isASCII && last.isNumber)
    }

    static func currentSegment(_ tokens: [ShellToken]) -> ArraySlice<ShellToken> {
        var start = 0
        for (index, token) in tokens.enumerated() where token.isSeparator || (token.kind == .word && token.text == "{") {
            start = index + 1
        }
        return tokens[start...]
    }

    nonisolated struct VariableContext {
        let name: String
        let nameStart: String.Index
        let braced: Bool
    }

    static func variableContext(raw: String, quote: Character?) -> VariableContext? {
        guard quote != "'", let dollar = raw.lastIndex(of: "$") else { return nil }
        var backslashes = 0
        var probe = dollar
        while probe > raw.startIndex, raw[raw.index(before: probe)] == "\\" {
            backslashes += 1
            probe = raw.index(before: probe)
        }
        guard backslashes % 2 == 0 else { return nil }
        var start = raw.index(after: dollar)
        var braced = false
        if start < raw.endIndex, raw[start] == "{" {
            braced = true
            start = raw.index(after: start)
        }
        let name = raw[start...]
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return VariableContext(name: String(name), nameStart: start, braced: braced)
    }

    static func shortValue(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let single = value.replacingOccurrences(of: "\n", with: " ")
        return single.count > 48 ? String(single.prefix(45)) + "..." : single
    }

    static func argumentItems(
        command: String,
        args: [String],
        current: ShellToken?,
        raw: String,
        optionName: String?,
        directory: String,
        env: CompletionEnvironment
    ) -> [CompletionItem] {
        let value = current?.value ?? ""
        let pastDoubleDash = args.contains("--")
        let previous = args.last
        let paths = { pathItems(word: current, directory: directory, env: env, directoriesOnly: false) }

        let cargoOptions = ["--bin", "--example", "--test", "--bench"]
        if command == "cargo", let option = optionName ?? (pastDoubleDash ? nil : previous), cargoOptions.contains(option) {
            return ArgumentSources.cargoTargets(option: option, directory: directory, env: env)
                .filter { $0.hasPrefix(value) }
                .map { CompletionItem(insert: $0, kind: .target, detail: String(option.dropFirst(2)) + " target") }
        }

        if let option = optionName {
            if let items = sourceOptionItems(command: command, option: option, current: current, args: args, directory: directory, env: env) { return items }
            guard let kind = optionKind(command: command, args: args, option: option, env: env) else { return [] }
            return valueItems(kind, current: current, directory: directory, env: env)
        }

        if raw.hasPrefix("-"), !pastDoubleDash {
            if command == "kill" {
                return KnownCommands.signals.filter { ("-" + $0).hasPrefix(raw) }.map {
                    CompletionItem(insert: "-" + $0, kind: .flag, detail: "signal")
                }
            }
            return flagItems(prefix: raw, flags: flags(command: command, args: args, env: env))
        }

        if !pastDoubleDash, let previous, previous.hasPrefix("-"), previous.count > 1,
           let items = sourceOptionItems(command: command, option: previous, current: current, args: args, directory: directory, env: env) {
            return items
        }

        if !pastDoubleDash, let previous, previous.hasPrefix("-"), previous.count > 1,
           let kind = optionKind(command: command, args: args, option: previous, env: env, separate: true) {
            return valueItems(kind, current: current, directory: directory, env: env)
        }

        if commandNameCommands.contains(command) {
            guard !value.isEmpty else { return [] }
            return commandItems(prefix: value, env: env, history: [])
        }
        if directoryCommands.contains(command) {
            return pathItems(word: current, directory: directory, env: env, directoriesOnly: true)
        }
        if variableCommands.contains(command), !raw.contains("=") {
            return valueItems(.variable, current: current, directory: directory, env: env)
        }
        if command == "git" {
            return gitItems(args: args, current: current, directory: directory, env: env)
        }
        if let items = sourceItems(command: command, args: args, current: current, directory: directory, env: env) {
            return items
        }
        let positional = args.filter { !$0.hasPrefix("-") }
        if positional.isEmpty, !KnownCommands.fileCommands.contains(command),
           !value.contains("/"), !value.hasPrefix("."), !value.hasPrefix("~") {
            let matched = subcommandItems(command: command, prefix: value, env: env)
            if !matched.isEmpty { return matched }
        }
        return paths()
    }

    static func subcommandItems(command: String, prefix: String, env: CompletionEnvironment) -> [CompletionItem] {
        var seen = Set<String>()
        var items: [CompletionItem] = []
        let known = KnownTools.allSubcommands(command).map { SubcommandInfo(name: $0.0, detail: $0.1) }
        for sub in known + env.commandSpec(forCommand: command).subcommands where sub.name.hasPrefix(prefix) && seen.insert(sub.name).inserted {
            items.append(CompletionItem(insert: sub.name, kind: .subcommand, detail: sub.detail))
        }
        return items
    }

    static func flags(command: String, args: [String], env: CompletionEnvironment) -> [FlagInfo] {
        if command == "aws", let path = env.awsIndexPath() {
            let indexed = awsFlags(args: args, path: path)
            if !indexed.isEmpty { return indexed }
        }
        let base = env.commandSpec(forCommand: command)
        var sub: String?
        if command == "git" {
            sub = GitCompletion.parse(arguments: args).subcommand
        } else if let first = args.first(where: { !$0.hasPrefix("-") }),
                  base.subcommands.contains(where: { $0.name == first })
                    || KnownTools.allSubcommands(command).contains(where: { $0.0 == first }) {
            sub = first
        }
        if let sub {
            let specific = env.commandSpec(forCommand: command + "-" + sub).flags
            if !specific.isEmpty { return specific }
        }
        return base.flags
    }

    static func optionKind(
        command: String, args: [String], option: String, env: CompletionEnvironment, separate: Bool = false
    ) -> ValueKind? {
        if let known = KnownCommands.optionKinds[command]?[option] { return known }
        guard let flag = flags(command: command, args: args, env: env).first(where: { $0.name == option && $0.takesValue }) else {
            return nil
        }
        if separate, flag.usesEquals { return nil }
        return flag.valueKind
    }

    static func flagItems(prefix: String, flags: [FlagInfo]) -> [CompletionItem] {
        flags
            .filter { $0.name.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                let lhsLong = lhs.name.hasPrefix("--")
                let rhsLong = rhs.name.hasPrefix("--")
                if lhsLong != rhsLong { return !lhsLong }
                return lhs.name < rhs.name
            }
            .map {
                CompletionItem(
                    insert: $0.usesEquals ? $0.name + "=" : $0.name,
                    display: $0.name,
                    kind: .flag,
                    detail: $0.detail,
                    terminator: $0.usesEquals ? "" : " "
                )
            }
    }

    static func valueItems(_ kind: ValueKind, current: ShellToken?, directory: String, env: CompletionEnvironment) -> [CompletionItem] {
        let value = current?.value ?? ""
        func named(_ names: [String], _ kind: CompletionItem.Kind, _ detail: String?) -> [CompletionItem] {
            names.filter { $0.hasPrefix(value) }.map {
                CompletionItem(insert: PathCompleter.escape($0), display: $0, kind: kind, detail: detail)
            }
        }
        switch kind {
        case .text:
            return []
        case .file:
            return pathItems(word: current, directory: directory, env: env, directoriesOnly: false)
        case .directory:
            return pathItems(word: current, directory: directory, env: env, directoriesOnly: true)
        case .user:
            return named(ArgumentSources.users(env), .user, nil)
        case .group:
            return named(ArgumentSources.groups(env), .group, nil)
        case .host:
            return named(ArgumentSources.hostNames(env), .host, nil)
        case .variable:
            let names = env.variables.keys.sorted().filter { $0.hasPrefix(value) }
            return names.map {
                CompletionItem(insert: $0, kind: .variable, detail: env.variables[$0].flatMap(shortValue), terminator: "")
            }
        case .pid:
            return env.processes().filter { String($0.pid).hasPrefix(value) }.sorted { $0.pid < $1.pid }.map {
                CompletionItem(insert: String($0.pid), kind: .process, detail: $0.name)
            }
        case .command:
            return commandItems(prefix: value, env: env, history: [])
        case .choices(let choices):
            return choices.filter { $0.hasPrefix(value) }.map { CompletionItem(insert: $0, kind: .choice) }
        }
    }

    static func gitItems(args: [String], current: ShellToken?, directory: String, env: CompletionEnvironment) -> [CompletionItem] {
        let value = current?.value ?? ""
        let parsed = GitCompletion.parse(arguments: args)
        guard let sub = parsed.subcommand else {
            return GitCompletion.subcommands
                .filter { $0.name.hasPrefix(value) }
                .map { CompletionItem(insert: $0.name, kind: .subcommand, detail: $0.detail) }
        }
        let paths = { pathItems(word: current, directory: directory, env: env, directoriesOnly: false) }
        if parsed.pastDoubleDash { return paths() }
        let positional = parsed.subcommandArguments.filter { !$0.hasPrefix("-") }.count

        func action(_ list: [(name: String, detail: String)]) -> [CompletionItem] {
            list.filter { $0.name.hasPrefix(value) }.map { CompletionItem(insert: $0.name, kind: .subcommand, detail: $0.detail) }
        }

        if sub == "stash", positional == 0 { return action(GitCompletion.stashActions) }
        let refs = env.gitRefs(in: directory)
        switch GitCompletion.arguments(for: sub) {
        case .refs:
            var items = refs.map { refItems($0, prefix: value, includeRemote: true, includeTags: true) } ?? []
            if ["checkout", "restore", "reset", "diff", "show", "blame", "log"].contains(sub) { items += paths() }
            return items
        case .localBranches:
            return refs.map { refItems($0, prefix: value, includeRemote: false, includeTags: false) } ?? []
        case .remoteThenRefs:
            guard let refs else { return paths() }
            if positional == 0 { return remoteItems(refs, prefix: value) }
            return refItems(refs, prefix: value, includeRemote: false, includeTags: true)
        case .remotes:
            if positional == 0 { return action(GitCompletion.remoteActions) }
            return refs.map { remoteItems($0, prefix: value) } ?? []
        case .paths:
            return paths()
        case .none:
            return []
        }
    }

    static func refItems(_ refs: GitRefs, prefix: String, includeRemote: Bool, includeTags: Bool) -> [CompletionItem] {
        var items: [CompletionItem] = []
        for name in refs.branches.sorted() where name.hasPrefix(prefix) {
            items.append(CompletionItem(insert: PathCompleter.escape(name), display: name, kind: .branch, detail: "branch"))
        }
        if includeRemote {
            for name in refs.remoteBranches.sorted() where name.hasPrefix(prefix) {
                items.append(CompletionItem(insert: PathCompleter.escape(name), display: name, kind: .branch, detail: "remote branch"))
            }
        }
        if includeTags {
            for name in refs.tags.sorted() where name.hasPrefix(prefix) {
                items.append(CompletionItem(insert: PathCompleter.escape(name), display: name, kind: .tag, detail: "tag"))
            }
        }
        return items
    }

    static func remoteItems(_ refs: GitRefs, prefix: String) -> [CompletionItem] {
        refs.remotes.sorted().filter { $0.hasPrefix(prefix) }.map {
            CompletionItem(insert: PathCompleter.escape($0), display: $0, kind: .remote, detail: "remote")
        }
    }

    static func commandItems(prefix: String, env: CompletionEnvironment, history: [String]) -> [CompletionItem] {
        func rank(_ kind: ShellSymbol.Kind) -> Int {
            switch kind {
            case .alias: return 0
            case .function: return 1
            case .builtin: return 2
            case .keyword: return 3
            case .executable: return 4
            }
        }
        var best: [String: ShellSymbol] = [:]
        let allowHidden = prefix.hasPrefix("_")
        let symbols = env.commandSymbols()
        func matching(_ test: (String) -> Bool) {
            for symbol in symbols where test(symbol.name) && (allowHidden || !symbol.name.hasPrefix("_")) {
                if let existing = best[symbol.name], rank(existing.kind) <= rank(symbol.kind) { continue }
                best[symbol.name] = symbol
            }
        }
        matching { $0.hasPrefix(prefix) }
        if best.isEmpty {
            let lowered = prefix.lowercased()
            matching { $0.lowercased().hasPrefix(lowered) }
        }
        var items = best.values
            .sorted { lhs, rhs in
                if lhs.name.count != rhs.name.count { return lhs.name.count < rhs.name.count }
                return lhs.name < rhs.name
            }
            .map { symbol -> CompletionItem in
                let insert = PathCompleter.escape(symbol.name)
                switch symbol.kind {
                case .alias:
                    return CompletionItem(insert: insert, display: symbol.name, kind: .alias, detail: symbol.detail.map { "alias for " + $0 })
                case .function:
                    return CompletionItem(insert: insert, display: symbol.name, kind: .function, detail: "shell function")
                case .builtin:
                    return CompletionItem(insert: insert, display: symbol.name, kind: .builtin, detail: "shell builtin")
                case .keyword:
                    return CompletionItem(insert: insert, display: symbol.name, kind: .keyword, detail: "shell keyword")
                case .executable:
                    return CompletionItem(insert: insert, display: symbol.name, kind: .command, detail: symbol.detail)
                }
            }
        var seen = Set<String>()
        var fromHistory: [CompletionItem] = []
        for entry in history.reversed() where fromHistory.count < 5 {
            guard entry.count > prefix.count, entry.hasPrefix(prefix), entry.contains(" "), !entry.contains("\n"),
                  seen.insert(entry).inserted
            else { continue }
            fromHistory.append(CompletionItem(insert: entry, kind: .history, detail: nil, terminator: ""))
        }
        items += fromHistory
        return items
    }

    static func pathItems(word: ShellToken?, directory: String, env: CompletionEnvironment, directoriesOnly: Bool) -> [CompletionItem] {
        let raw = word?.text ?? ""
        let value = word?.value ?? ""
        let quote = quoteCharacter(word)
        if value == "~" {
            return [CompletionItem(insert: "~/", kind: .directory, terminator: "")]
        }
        let slash = value.lastIndex(of: "/")
        let folderValue = slash.map { String(value[...$0]) } ?? ""
        let namePrefix = slash.map { String(value[value.index(after: $0)...]) } ?? value
        let base = folderValue.isEmpty ? directory : env.resolve(path: folderValue, directory: directory)
        guard let entries = env.directoryEntries(atPath: base) else { return [] }

        let rawFolder: String
        if let rawSlash = raw.lastIndex(of: "/") {
            rawFolder = String(raw[...rawSlash])
        } else {
            rawFolder = quote.map(String.init) ?? ""
        }

        let showHidden = namePrefix.hasPrefix(".")
        func filter(_ test: (String) -> Bool) -> [DirectoryEntry] {
            entries.filter { test($0.name) && (showHidden || !$0.name.hasPrefix(".")) && (!directoriesOnly || $0.isDirectory) }
        }
        var matches = filter { $0.hasPrefix(namePrefix) }
        if matches.isEmpty {
            let lowered = namePrefix.lowercased()
            matches = filter { $0.lowercased().hasPrefix(lowered) }
        }
        if showHidden, "..".hasPrefix(namePrefix), !matches.contains(where: { $0.name == ".." }) {
            matches.append(DirectoryEntry(name: "..", isDirectory: true))
        }
        matches.sort { $0.name.lowercased() < $1.name.lowercased() }

        return matches.map { entry in
            let body = quote != nil ? entry.name : PathCompleter.escape(entry.name)
            if entry.isDirectory {
                return CompletionItem(insert: rawFolder + body + "/", display: entry.name + "/", kind: .directory, terminator: "")
            }
            let closing = quote.map { String($0) + " " } ?? " "
            return CompletionItem(insert: rawFolder + body, display: entry.name, kind: .file, terminator: closing)
        }
    }

    static func commonPrefix(of items: [CompletionItem]) -> String {
        guard var common = items.first?.insert else { return "" }
        for item in items.dropFirst() {
            common = String(zip(common, item.insert).prefix { $0.0 == $0.1 }.map(\.0))
            if common.isEmpty { break }
        }
        var trailing = 0
        for character in common.reversed() {
            guard character == "\\" else { break }
            trailing += 1
        }
        if trailing % 2 == 1 { common.removeLast() }
        return common
    }
}
