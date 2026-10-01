import Foundation
import TurmCore

nonisolated struct ComposeService: Equatable, Sendable {
    let name: String
    let profiles: [String]
    let extends: String?
}

nonisolated struct DockerSource {
    let args: [String]
    let env: CompletionEnvironment
    let context: String?
    private let socketObjects: DockerObjects?

    init(args: [String], env: CompletionEnvironment) {
        self.args = args
        self.env = env
        let typed = CommandCompleter.dockerTypedContext(args)
        context = typed == "default" ? nil : typed
        if context == nil {
            let objects = env.dockerObjects()
            socketObjects = objects.available ? objects : nil
        } else {
            socketObjects = nil
        }
    }

    private func names(_ listing: DockerListing) -> [String] {
        env.cliListing(CLIListing.docker(listing, context: context))
    }

    func images() -> [DockerImage] {
        if let socketObjects { return socketObjects.images }
        return names(.images).filter { !$0.contains("<none>") }.map { DockerImage(id: "", names: [$0]) }
    }

    func containers(_ scope: DockerScope) -> [DockerContainer] {
        if let socketObjects { return socketObjects.containers }
        switch scope {
        case .running:
            return names(.runningContainers).map { DockerContainer(id: "", names: [$0], image: "", state: "running") }
        case .all:
            return names(.allContainers).map { DockerContainer(id: "", names: [$0], image: "", state: "") }
        case .stopped:
            let running = Set(names(.runningContainers))
            return names(.allContainers).filter { !running.contains($0) }.map {
                DockerContainer(id: "", names: [$0], image: "", state: "exited")
            }
        }
    }

    func volumes() -> [String] {
        socketObjects?.volumes ?? names(.volumes)
    }

    func networks() -> [String] {
        socketObjects?.networks ?? names(.networks)
    }
}

nonisolated extension CommandCompleter {
    static func dockerTypedContext(_ args: [String]) -> String? {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            let word = args[index]
            if (word == "--context" || word == "-c"), index + 1 < args.count { return args[index + 1] }
            if word.hasPrefix("--context=") { return String(word.dropFirst("--context=".count)) }
            index += dockerGlobalOptions.contains(word) ? 2 : 1
        }
        return nil
    }

    static func dockerItems(args: [String], value: String, directory: String, env: CompletionEnvironment) -> [CompletionItem]? {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") { index += dockerGlobalOptions.contains(args[index]) ? 2 : 1 }
        guard index < args.count else { return subcommandItems(command: "docker", prefix: value, env: env) }
        var sub = args[index]
        var rest = Array(args[(index + 1)...])
        var namespace: String?
        if sub == "container" || sub == "image" {
            let inner = rest.first { !$0.hasPrefix("-") }
            guard let inner, let position = rest.firstIndex(of: inner) else {
                return nestedItems(key: "docker " + sub, prefix: value)
            }
            namespace = sub
            sub = inner
            rest = Array(rest[(position + 1)...])
        }
        if sub == "compose" { return composeItems(args: rest, value: value, directory: directory, env: env) }
        if sub == "context" {
            let positional = words(rest, valueOptions: [])
            if positional.isEmpty { return nestedItems(key: "docker context", prefix: value) }
            guard positional.count == 1, ["use", "rm", "inspect", "update", "export"].contains(positional[0]) else { return [] }
            return namedItems(dockerContextNames(env), kind: .context, detail: "docker context", prefix: value)
        }
        if sub == "volume" {
            let positional = words(rest, valueOptions: [])
            if positional.isEmpty { return nestedItems(key: "docker volume", prefix: value) }
            guard ["rm", "remove", "inspect"].contains(positional[0]) else { return [] }
            return namedItems(DockerSource(args: args, env: env).volumes(), kind: .volume, detail: "volume", prefix: value)
        }
        if sub == "network" {
            let positional = words(rest, valueOptions: [])
            if positional.isEmpty { return nestedItems(key: "docker network", prefix: value) }
            let source = DockerSource(args: args, env: env)
            switch positional[0] {
            case "connect", "disconnect":
                if positional.count == 1 { return namedItems(source.networks(), kind: .network, detail: "network", prefix: value) }
                return positional.count == 2 ? dockerContainerItems(source.containers(.all), scope: .all, prefix: value) : []
            case "rm", "remove", "inspect":
                return namedItems(source.networks(), kind: .network, detail: "network", prefix: value)
            default:
                return []
            }
        }
        if awaitingValue(rest, valueOptions: dockerValueOptions) { return [] }

        var scope: DockerScope?
        var wantsImages = false
        switch namespace {
        case "image":
            wantsImages = sub == "rm" || dockerImageCommands.contains(sub)
            if sub == "rm" { sub = "rmi" }
        case "container":
            scope = dockerContainerScopes[sub]
        default:
            scope = dockerContainerScopes[sub]
            wantsImages = dockerImageCommands.contains(sub)
        }
        if scope == nil, !wantsImages { return nil }

        let positional = words(rest, valueOptions: dockerValueOptions)
        guard positional.isEmpty || dockerMultiple.contains(sub) else { return nil }
        let source = DockerSource(args: args, env: env)
        var items: [CompletionItem] = []
        if let scope { items += dockerContainerItems(source.containers(scope), scope: scope, prefix: value) }
        if wantsImages { items += dockerImageItems(source.images(), prefix: value) }
        return items
    }

    static func dockerOptionItems(
        option: String, current: ShellToken?, args: [String], directory: String, env: CompletionEnvironment
    ) -> [CompletionItem]? {
        let value = current?.value ?? ""
        switch option {
        case "-v", "--volume":
            if value.contains(":") { return [] }
            let volumes = DockerSource(args: args, env: env).volumes().filter { $0.hasPrefix(value) }.map {
                CompletionItem(insert: PathCompleter.escape($0) + ":", display: $0, kind: .volume, detail: "volume", terminator: "")
            }
            return volumes + pathItems(word: current, directory: directory, env: env, directoriesOnly: true)
        case "--network", "--net":
            return namedItems(DockerSource(args: args, env: env).networks(), kind: .network, detail: "network", prefix: value)
        case "--volumes-from":
            return dockerContainerItems(DockerSource(args: args, env: env).containers(.all), scope: .all, prefix: value)
        default:
            return nil
        }
    }

    static func parseCompose(_ text: String) -> (services: [ComposeService], includes: [String]) {
        var services: [ComposeService] = []
        var includes: [String] = []
        var section = ""
        var serviceIndent: Int?
        var name: String?
        var profiles: [String] = []
        var extends: String?
        var block: (key: String, indent: Int)?
        var lastKey = ""

        func flush() {
            if let name { services.append(ComposeService(name: name, profiles: profiles, extends: extends)) }
            name = nil
            profiles = []
            extends = nil
            block = nil
        }

        func inlineList(_ text: String) -> [String] {
            var body = text.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("["), body.hasSuffix("]") { body = String(body.dropFirst().dropLast()) }
            return body.split(separator: ",").map { ArgumentSources.unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        }

        func stripComment(_ text: String) -> String {
            if let range = text.range(of: " #") { return String(text[..<range.lowerBound]) }
            return text
        }

        for raw in text.components(separatedBy: "\n") {
            let line = stripComment(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let leading = line.prefix { $0 == " " }.count
            if leading == 0 {
                flush()
                serviceIndent = nil
                section = String(trimmed.prefix { $0 != ":" })
                lastKey = section
                if section == "include", let colon = trimmed.firstIndex(of: ":") {
                    includes += inlineList(String(trimmed[trimmed.index(after: colon)...]))
                }
                continue
            }
            if section == "include" {
                var body = trimmed
                if body.hasPrefix("- ") { body = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                if let colon = body.firstIndex(of: ":"), !body.hasPrefix("\""), !body.hasPrefix("'") {
                    let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
                    lastKey = key
                    if key == "path" { includes += inlineList(String(body[body.index(after: colon)...])) }
                } else if lastKey == "include" || lastKey == "path" {
                    includes.append(ArgumentSources.unquote(body))
                }
                continue
            }
            guard section == "services" else { continue }
            if serviceIndent == nil { serviceIndent = leading }
            if leading == serviceIndent, let colon = trimmed.firstIndex(of: ":") {
                flush()
                let candidate = ArgumentSources.unquote(String(trimmed[..<colon]))
                if !candidate.hasPrefix("x-"), candidate.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }), !candidate.isEmpty {
                    name = candidate
                }
                continue
            }
            guard name != nil else { continue }
            if let current = block, leading <= current.indent { block = nil }
            if trimmed.hasPrefix("profiles:") {
                let rest = String(trimmed.dropFirst("profiles:".count))
                if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    block = ("profiles", leading)
                } else {
                    profiles += inlineList(rest)
                }
            } else if trimmed.hasPrefix("extends:") {
                let rest = ArgumentSources.unquote(String(trimmed.dropFirst("extends:".count)).trimmingCharacters(in: .whitespaces))
                if rest.isEmpty { block = ("extends", leading) } else { extends = rest }
            } else if let current = block, current.key == "profiles", trimmed.hasPrefix("- ") {
                profiles.append(ArgumentSources.unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if let current = block, current.key == "extends", trimmed.hasPrefix("service:") {
                extends = ArgumentSources.unquote(String(trimmed.dropFirst("service:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return (services, includes)
    }

    static func composeServices(_ text: String) -> [String] {
        parseCompose(text).services.map(\.name)
    }

    static func loadCompose(
        files: [String], base: String, env: CompletionEnvironment, depth: Int, visited: inout Set<String>
    ) -> [ComposeService] {
        var result: [ComposeService] = []
        for file in files {
            let path = env.resolve(path: file, directory: base)
            guard depth < 4, visited.insert(path).inserted, let text = env.readText(atPath: path) else { continue }
            let parsed = parseCompose(text)
            result += parsed.services
            let folder = (path as NSString).deletingLastPathComponent
            result += loadCompose(files: parsed.includes, base: folder, env: env, depth: depth + 1, visited: &visited)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.name).inserted }
    }

    static func composeProject(files: [String], directory: String, env: CompletionEnvironment) -> [ComposeService] {
        var candidates = files
        if candidates.isEmpty, let list = env.variables["COMPOSE_FILE"], !list.isEmpty {
            let separator: Character = env.variables["COMPOSE_PATH_SEPARATOR"]?.first ?? ":"
            candidates = list.split(separator: separator).map(String.init)
        }
        if candidates.isEmpty {
            for name in composeFiles where env.readText(atPath: directory + "/" + name) != nil {
                candidates = [name]
                break
            }
        }
        var visited = Set<String>()
        return loadCompose(files: candidates, base: directory, env: env, depth: 0, visited: &visited)
    }

    static func composeFileArguments(_ args: [String]) -> [String] {
        var files: [String] = []
        var index = 0
        while index < args.count {
            if (args[index] == "-f" || args[index] == "--file"), index + 1 < args.count {
                files.append(args[index + 1])
                index += 2
            } else if args[index].hasPrefix("--file=") {
                files.append(String(args[index].dropFirst("--file=".count)))
                index += 1
            } else {
                index += 1
            }
        }
        return files
    }

    static func composeItems(args: [String], value: String, directory: String, env: CompletionEnvironment) -> [CompletionItem]? {
        if let last = args.last, composeValueOptions.contains(last) {
            guard last == "--profile" else { return nil }
            let project = composeProject(files: composeFileArguments(args), directory: directory, env: env)
            return namedItems(project.flatMap(\.profiles), kind: .choice, detail: "compose profile", prefix: value)
        }
        var index = 0
        while index < args.count, args[index].hasPrefix("-") { index += composeValueOptions.contains(args[index]) ? 2 : 1 }
        guard index < args.count else {
            return KnownTools.composeSubcommands.filter { $0.0.hasPrefix(value) }.map {
                CompletionItem(insert: $0.0, kind: .subcommand, detail: $0.1)
            }
        }
        let sub = args[index]
        let rest = Array(args[(index + 1)...])
        guard let multiple = composeServiceCommands[sub] else { return nil }
        if awaitingValue(rest, valueOptions: dockerValueOptions) { return [] }
        let positional = words(rest, valueOptions: dockerValueOptions)
        guard positional.isEmpty || multiple else { return nil }
        let project = composeProject(files: composeFileArguments(Array(args[..<index])), directory: directory, env: env)
        return project.filter { $0.name.hasPrefix(value) }.map {
            CompletionItem(
                insert: PathCompleter.escape($0.name), display: $0.name, kind: .service,
                detail: $0.profiles.isEmpty ? "compose service" : "profile: " + $0.profiles.joined(separator: ", ")
            )
        }
    }
}
