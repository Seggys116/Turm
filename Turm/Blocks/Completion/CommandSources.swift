import Foundation
import TurmCore

nonisolated extension CommandCompleter {
    static func sourceItems(
        command: String, args: [String], current: ShellToken?, directory: String, env: CompletionEnvironment
    ) -> [CompletionItem]? {
        let value = current?.value ?? ""
        let positional = args.filter { !$0.hasPrefix("-") }
        switch command {
        case "ssh", "sftp", "mosh", "ssh-copy-id":
            guard positional.isEmpty else { return nil }
            return hostItems(prefix: value, colon: false, env: env)
        case "scp", "rsync":
            if value.contains(":") { return [] }
            return hostItems(prefix: value, colon: true, env: env)
                + pathItems(word: current, directory: directory, env: env, directoriesOnly: false)
        case "npm", "yarn", "pnpm", "bun":
            return packageItems(command: command, positional: positional, value: value, directory: directory, env: env)
        case "npx", "bunx":
            guard positional.isEmpty else { return nil }
            return namedItems(ArgumentSources.nodeBinaries(directory: directory, env: env), kind: .command, detail: "local binary", prefix: value)
        case "make", "gmake":
            return makeItems(args: args, value: value, directory: directory, env: env)
        case "just":
            guard let text = ["justfile", "Justfile", ".justfile"].lazy.compactMap({ ArgumentSources.findUp($0, from: directory, env: env) }).first else {
                return []
            }
            return ArgumentSources.justRecipes(text.text).filter { $0.hasPrefix(value) }.map {
                CompletionItem(insert: $0, kind: .target, detail: "just recipe")
            }
        case "cargo":
            guard positional.isEmpty else { return nil }
            var items = subcommandItems(command: "cargo", prefix: value, env: env)
            let known = Set(items.map(\.insert))
            for symbol in env.commandSymbols() where symbol.kind == .executable && symbol.name.hasPrefix("cargo-") {
                let name = String(symbol.name.dropFirst(6))
                if name.hasPrefix(value), !known.contains(name) {
                    items.append(CompletionItem(insert: name, kind: .subcommand, detail: "cargo plugin"))
                }
            }
            return items
        case "brew":
            return brewItems(args: args, positional: positional, value: value, env: env)
        case "kill":
            return valueItems(.pid, current: current, directory: directory, env: env)
        case "killall", "pkill":
            var seen = Set<String>()
            return env.processes().map(\.name).sorted().filter { $0.hasPrefix(value) && seen.insert($0).inserted }.map {
                CompletionItem(insert: PathCompleter.escape($0), display: $0, kind: .process, detail: "process")
            }
        case "docker":
            return dockerItems(args: args, value: value, directory: directory, env: env)
        case "docker-compose":
            return composeItems(args: args, value: value, directory: directory, env: env)
        case "kubectl":
            return kubectlItems(args: args, value: value, directory: directory, env: env)
        default:
            return toolItems(command: command, args: args, positional: positional, value: value, directory: directory, env: env)
        }
    }

    static func hostItems(prefix: String, colon: Bool, env: CompletionEnvironment) -> [CompletionItem] {
        var user = ""
        var hostPrefix = prefix
        if let at = prefix.lastIndex(of: "@") {
            user = String(prefix[...at])
            hostPrefix = String(prefix[prefix.index(after: at)...])
        }
        return ArgumentSources.hostNames(env).filter { $0.hasPrefix(hostPrefix) }.map {
            CompletionItem(
                insert: user + $0 + (colon ? ":" : ""),
                display: $0,
                kind: .host,
                detail: "host",
                terminator: colon ? "" : " "
            )
        }
    }

    static func packageItems(
        command: String, positional: [String], value: String, directory: String, env: CompletionEnvironment
    ) -> [CompletionItem]? {
        func scripts() -> [CompletionItem] {
            ArgumentSources.packageScripts(directory: directory, env: env).filter { $0.name.hasPrefix(value) }.map {
                CompletionItem(insert: PathCompleter.escape($0.name), display: $0.name, kind: .script, detail: ArgumentSources.shorten($0.command))
            }
        }
        let runVerbs: Set<String> = ["run", "run-script", "rum", "urn"]
        if positional.count == 1, runVerbs.contains(positional[0]) { return scripts() }
        let dependencyVerbs: Set<String> = ["uninstall", "remove", "rm", "un", "update", "up", "upgrade", "outdated", "explain", "why", "unlink"]
        if let verb = positional.first, dependencyVerbs.contains(verb) {
            return namedItems(ArgumentSources.packageDependencies(directory: directory, env: env), kind: .package, detail: "dependency", prefix: value)
        }
        if let verb = positional.first, verb == "exec", command != "yarn" {
            return namedItems(ArgumentSources.nodeBinaries(directory: directory, env: env), kind: .command, detail: "local binary", prefix: value)
        }
        guard positional.isEmpty else { return nil }
        let subs = subcommandItems(command: command, prefix: value, env: env)
        if command == "npm" { return subs }
        let known = Set(subs.map(\.insert))
        return subs + scripts().filter { !known.contains($0.insert) }
    }

    static func makeItems(args: [String], value: String, directory: String, env: CompletionEnvironment) -> [CompletionItem] {
        var base = directory
        var file: String?
        for (index, arg) in args.enumerated() where index + 1 < args.count {
            if arg == "-C" || arg == "--directory" { base = env.resolve(path: args[index + 1], directory: directory) }
            if arg == "-f" || arg == "--file" { file = args[index + 1] }
        }
        var text: String?
        if let file {
            text = env.readText(atPath: env.resolve(path: file, directory: base))
        } else {
            for name in ["GNUmakefile", "makefile", "Makefile"] {
                if let found = env.readText(atPath: base + "/" + name) {
                    text = found
                    break
                }
            }
        }
        return ArgumentSources.makeTargets(text ?? "").filter { $0.hasPrefix(value) }.map {
            CompletionItem(insert: PathCompleter.escape($0), display: $0, kind: .target, detail: "make target")
        }
    }

    static func brewItems(args: [String], positional: [String], value: String, env: CompletionEnvironment) -> [CompletionItem]? {
        if positional.isEmpty { return subcommandItems(command: "brew", prefix: value, env: env) }
        let sub = positional[0]
        if sub == "untap" { return namedItems(ArgumentSources.brewTaps(env: env), kind: .repo, detail: "tap", prefix: value) }
        if sub == "services" {
            if positional.count == 1 { return nestedItems(key: "brew services", prefix: value) }
            let installed = ArgumentSources.brewPackages(command: "services", casksOnly: false, formulaeOnly: true, env: env)
            return namedItems(installed.map { $0.name }, kind: .package, detail: "installed formula", prefix: value)
        }
        guard KnownCommands.installedBrewCommands.contains(sub) || KnownCommands.anyBrewCommands.contains(sub) else { return nil }
        let casksOnly = args.contains("--cask") || args.contains("--casks")
        let formulaeOnly = args.contains("--formula") || args.contains("--formulae")
        return ArgumentSources.brewPackages(command: sub, casksOnly: casksOnly, formulaeOnly: formulaeOnly, env: env)
            .filter { $0.name.hasPrefix(value) }
            .prefix(maxItems)
            .map { CompletionItem(insert: PathCompleter.escape($0.name), display: $0.name, kind: .package, detail: $0.detail) }
    }
}

nonisolated extension ArgumentSources {
    static func shorten(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return text.count > 60 ? String(text.prefix(57)) + "..." : text
    }
}
