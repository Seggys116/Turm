import Foundation
import TurmCore

nonisolated enum AnsibleInventory {
    static func expand(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "["), let close = pattern[open...].firstIndex(of: "]"),
              let colon = pattern[open..<close].firstIndex(of: ":")
        else { return [pattern] }
        let head = String(pattern[..<open])
        let tail = String(pattern[pattern.index(after: close)...])
        let lower = String(pattern[pattern.index(after: open)..<colon])
        let upper = String(pattern[pattern.index(after: colon)..<close])
        if let start = Int(lower), let end = Int(upper), start <= end, end - start < 1000 {
            let width = lower.hasPrefix("0") ? lower.count : 0
            return (start...end).map { head + String(format: width > 0 ? "%0\(width)d" : "%d", $0) + tail }
        }
        if lower.count == 1, upper.count == 1, let a = lower.unicodeScalars.first?.value, let b = upper.unicodeScalars.first?.value, a <= b {
            return (a...b).compactMap { Unicode.Scalar($0).map { head + String($0) + tail } }
        }
        return [pattern]
    }

    static func parse(_ text: String) -> (hosts: [String], groups: [String]) {
        let lines = text.components(separatedBy: "\n")
        let isINI = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("]") }
        return isINI ? parseINI(lines) : parseYAML(lines)
    }

    static func parseINI(_ lines: [String]) -> (hosts: [String], groups: [String]) {
        var hosts: [String] = []
        var groups: [String] = []
        var section: (name: String, kind: String) = ("ungrouped", "hosts")
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast())
                let parts = inner.split(separator: ":", maxSplits: 1).map(String.init)
                section = (parts[0], parts.count > 1 ? parts[1] : "hosts")
                groups.append(parts[0])
                continue
            }
            switch section.kind {
            case "vars":
                continue
            case "children":
                groups.append(String(line.prefix { !$0.isWhitespace }))
            default:
                let token = String(line.prefix { !$0.isWhitespace })
                if !token.contains("=") { hosts += expand(token) }
            }
        }
        return (hosts, groups)
    }

    static func parseYAML(_ lines: [String]) -> (hosts: [String], groups: [String]) {
        var hosts: [String] = []
        var groups: [String] = []
        var stack: [(indent: Int, key: String)] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let indent = raw.prefix { $0 == " " }.count
            let key = ArgumentSources.unquote(String(trimmed[..<colon]))
            while let top = stack.last, top.indent >= indent { stack.removeLast() }
            let insideVars = stack.contains { $0.key == "vars" }
            if !insideVars {
                let parent = stack.last?.key
                if parent == "hosts" {
                    hosts += expand(key)
                } else if parent == "children" || (indent == 0 && !["all"].contains(key) && !key.isEmpty) {
                    groups.append(key)
                } else if key == "all" {
                    groups.append("all")
                }
            }
            stack.append((indent, key))
        }
        return (hosts, groups)
    }
}

nonisolated enum HelmSources {
    static func configDirectories(variables: [String: String], home: String) -> [String] {
        var directories: [String] = []
        if let custom = variables["HELM_CONFIG_HOME"] { directories.append(custom) }
        if let xdg = variables["XDG_CONFIG_HOME"] { directories.append(xdg + "/helm") }
        directories += [home + "/Library/Preferences/helm", home + "/.config/helm"]
        return directories
    }

    static func cacheDirectories(variables: [String: String], home: String) -> [String] {
        var directories: [String] = []
        if let custom = variables["HELM_CACHE_HOME"] { directories.append(custom) }
        if let xdg = variables["XDG_CACHE_HOME"] { directories.append(xdg + "/helm") }
        directories += [home + "/Library/Caches/helm", home + "/.cache/helm"]
        return directories
    }

    static func repositories(env: CompletionEnvironment) -> [String] {
        var paths: [String] = []
        if let explicit = env.variables["HELM_REPOSITORY_CONFIG"] { paths.append(explicit) }
        paths += configDirectories(variables: env.variables, home: env.homeDirectory).map { $0 + "/repositories.yaml" }
        for path in paths {
            guard let text = env.readText(atPath: path) else { continue }
            var names: [String] = []
            for raw in text.components(separatedBy: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
                if line.hasPrefix("name:") { names.append(ArgumentSources.unquote(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))) }
            }
            return names
        }
        return []
    }

    static func chartNames(indexText: String) -> [String] {
        var names: [String] = []
        var inEntries = false
        var chartIndent: Int?
        for raw in indexText.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = raw.prefix { $0 == " " }.count
            if indent == 0 {
                inEntries = trimmed.hasPrefix("entries:")
                chartIndent = nil
                continue
            }
            guard inEntries else { continue }
            if chartIndent == nil { chartIndent = indent }
            if indent == chartIndent, trimmed.hasSuffix(":"), !trimmed.hasPrefix("-") {
                names.append(ArgumentSources.unquote(String(trimmed.dropLast())))
            }
        }
        return names
    }

    static func charts(env: CompletionEnvironment) -> [String] {
        var result: [String] = []
        for directory in cacheDirectories(variables: env.variables, home: env.homeDirectory) {
            for entry in env.directoryEntries(atPath: directory + "/repository") ?? [] where entry.name.hasSuffix("-index.yaml") {
                let repo = String(entry.name.dropLast("-index.yaml".count))
                guard let text = env.readText(atPath: directory + "/repository/" + entry.name) else { continue }
                result += chartNames(indexText: text).map { repo + "/" + $0 }
            }
        }
        return Array(Set(result)).sorted()
    }
}

nonisolated enum GCloudSources {
    static func configDirectory(_ env: CompletionEnvironment) -> String {
        env.variables["CLOUDSDK_CONFIG"] ?? env.homeDirectory + "/.config/gcloud"
    }

    static func configurations(_ env: CompletionEnvironment) -> [String] {
        let directory = configDirectory(env) + "/configurations"
        var names = (env.directoryEntries(atPath: directory) ?? []).filter { !$0.isDirectory && $0.name.hasPrefix("config_") }.map {
            String($0.name.dropFirst("config_".count))
        }
        if let active = env.readText(atPath: configDirectory(env) + "/active_config")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !active.isEmpty {
            names.append(active)
        }
        return Array(Set(names)).sorted()
    }

    static func projects(_ env: CompletionEnvironment) -> [String] {
        let directory = configDirectory(env) + "/configurations"
        var projects: [String] = []
        for entry in env.directoryEntries(atPath: directory) ?? [] where entry.name.hasPrefix("config_") {
            var inCore = false
            for raw in (env.readText(atPath: directory + "/" + entry.name) ?? "").components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inCore = line == "[core]"; continue }
                guard inCore, line.hasPrefix("project"), let equals = line.firstIndex(of: "=") else { continue }
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { projects.append(value) }
            }
        }
        if let project = env.variables["CLOUDSDK_CORE_PROJECT"] { projects.append(project) }
        return Array(Set(projects)).sorted()
    }
}

nonisolated enum AzureSources {
    static func subscriptions(_ env: CompletionEnvironment) -> [(name: String, id: String)] {
        let directory = env.variables["AZURE_CONFIG_DIR"] ?? env.homeDirectory + "/.azure"
        guard var text = env.readText(atPath: directory + "/azureProfile.json") else { return [] }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let list = object["subscriptions"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return (entry["name"] as? String ?? id, id)
        }
    }
}

nonisolated enum VoltaSources {
    static func home(_ env: CompletionEnvironment) -> String {
        env.variables["VOLTA_HOME"] ?? env.homeDirectory + "/.volta"
    }

    static func packages(_ env: CompletionEnvironment) -> [String] {
        (env.directoryEntries(atPath: home(env) + "/tools/image/packages") ?? []).filter(\.isDirectory).map { $0.name }
    }

    static func binaries(_ env: CompletionEnvironment) -> [String] {
        (env.directoryEntries(atPath: home(env) + "/tools/user/bins") ?? []).filter { $0.name.hasSuffix(".json") }.map {
            String($0.name.dropLast(5))
        }
    }

    static func versions(of tool: String, env: CompletionEnvironment) -> [String] {
        (env.directoryEntries(atPath: home(env) + "/tools/image/" + tool) ?? []).filter(\.isDirectory).map { $0.name }
    }
}

nonisolated enum AWSIndex {
    static func dataRoots(_ env: CompletionEnvironment) -> [String] {
        let home = env.homeDirectory
        var roots: [String] = []
        var libs = [
            "/opt/homebrew/opt/awscli/libexec/lib", "/usr/local/opt/awscli/libexec/lib", home + "/.local/pipx/venvs/awscli/lib",
            home + "/Library/Python",
        ]
        if let venv = env.variables["VIRTUAL_ENV"] { libs.append(venv + "/lib") }
        for lib in libs {
            for entry in env.directoryEntries(atPath: lib) ?? [] where entry.isDirectory && entry.name.hasPrefix("python") || entry.name.first?.isNumber == true {
                roots.append(lib + "/" + entry.name + "/site-packages/botocore/data")
                roots.append(lib + "/" + entry.name + "/lib/python/site-packages/botocore/data")
            }
        }
        for version in env.directoryEntries(atPath: "/usr/local/aws-cli/v2") ?? [] where version.isDirectory {
            roots.append("/usr/local/aws-cli/v2/" + version.name + "/dist/awscli/botocore/data")
        }
        return roots
    }

    static func services(_ env: CompletionEnvironment) -> [String] {
        var names: [String] = []
        for root in dataRoots(env) {
            names += (env.directoryEntries(atPath: root) ?? []).filter { $0.isDirectory && !$0.name.hasPrefix("_") }.map { $0.name }
        }
        if names.contains("s3") { names.append("s3api") }
        return Array(Set(names)).sorted()
    }

    static func kebab(_ operation: String) -> String {
        guard let first = try? NSRegularExpression(pattern: "(.)([A-Z][a-z]+)"),
              let second = try? NSRegularExpression(pattern: "([a-z0-9])([A-Z])")
        else { return operation.lowercased() }
        var text = first.stringByReplacingMatches(in: operation, range: NSRange(operation.startIndex..., in: operation), withTemplate: "$1-$2")
        text = second.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1-$2")
        return text.lowercased()
    }

    static func operations(service: String, env: CompletionEnvironment) -> [String] {
        let directory = service == "s3api" ? "s3" : service
        for root in dataRoots(env) {
            let versions = (env.directoryEntries(atPath: root + "/" + directory) ?? []).filter(\.isDirectory).map { $0.name }.sorted()
            guard let latest = versions.last,
                  let text = env.readText(atPath: root + "/" + directory + "/" + latest + "/service-2.json"),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let operations = object["operations"] as? [String: Any]
            else { continue }
            return operations.keys.map(kebab).sorted()
        }
        return []
    }
}

nonisolated extension CommandCompleter {
    static func awsFlags(args: [String], path: String) -> [FlagInfo] {
        let positional = args.filter { !$0.hasPrefix("-") }
        var entries = AWSCompletionIndex.options(path: path, parent: "aws", command: "")
        if let service = positional.first {
            let parent = "aws." + service
            if positional.count > 1 { entries += AWSCompletionIndex.options(path: path, parent: parent, command: positional[1]) }
            else { entries += AWSCompletionIndex.options(path: path, parent: "aws", command: service) }
        }
        var seen = Set<String>()
        return entries.filter { seen.insert($0.name).inserted }.map {
            FlagInfo(name: $0.name, detail: $0.detail, takesValue: $0.type != "boolean")
        }
    }

    static func kubeContextArgs(_ args: [String]) -> KubeOptions {
        var options = kubeOptions(args)
        var index = 0
        while index < args.count {
            if args[index] == "--kube-context", index + 1 < args.count { options.context = args[index + 1] }
            index += 1
        }
        return options
    }

    static func helmChartItems(value: String, directory: String, env: CompletionEnvironment) -> [CompletionItem] {
        var items: [CompletionItem] = []
        for chart in HelmSources.charts(env: env) where chart.hasPrefix(value) {
            items.append(CompletionItem(insert: PathCompleter.escape(chart), display: chart, kind: .chart, detail: "chart"))
        }
        if !value.contains("/") {
            for repo in HelmSources.repositories(env: env) where (repo + "/").hasPrefix(value) {
                items.append(CompletionItem(insert: repo + "/", display: repo + "/", kind: .repo, detail: "chart repository", terminator: ""))
            }
        }
        return items
    }

    static func helmItems(args: [String], positional: [String], value: String, directory: String, env: CompletionEnvironment) -> [CompletionItem]? {
        guard let first = positional.first else { return nil }
        func releases() -> [CompletionItem] {
            let options = kubeContextArgs(args)
            let invocation = CLIListing.helmReleases(namespace: options.namespace, context: options.context, kubeconfig: options.kubeconfig)
            return namedItems(env.cliListing(invocation), kind: .release, detail: "helm release", prefix: value)
        }
        switch first {
        case "repo":
            if positional.count == 1 { return nestedItems(key: "helm repo", prefix: value) }
            guard positional.count == 2, ["remove", "rm", "update"].contains(positional[1]) else { return [] }
            return namedItems(HelmSources.repositories(env: env), kind: .repo, detail: "chart repository", prefix: value)
        case "get":
            if positional.count == 1 { return nestedItems(key: "helm get", prefix: value) }
            return positional.count == 2 ? releases() : []
        case "show":
            if positional.count == 1 { return nestedItems(key: "helm show", prefix: value) }
            return positional.count == 2 ? helmChartItems(value: value, directory: directory, env: env) : []
        case "dependency", "dep":
            return positional.count == 1 ? nestedItems(key: "helm dependency", prefix: value) : nil
        case "plugin":
            return positional.count == 1 ? nestedItems(key: "helm plugin", prefix: value) : nil
        case "uninstall", "delete", "un":
            return releases()
        case "status", "history", "rollback", "test":
            return positional.count == 1 ? releases() : []
        case "upgrade":
            if positional.count == 1 { return releases() }
            return positional.count == 2 ? helmChartItems(value: value, directory: directory, env: env) : []
        case "install":
            return positional.count == 2 ? helmChartItems(value: value, directory: directory, env: env) : nil
        case "template", "pull":
            let index = first == "pull" ? 1 : 2
            return positional.count == index ? helmChartItems(value: value, directory: directory, env: env) : nil
        default:
            return nil
        }
    }

    static func gcloudItems(positional: [String], value: String, env: CompletionEnvironment) -> [CompletionItem]? {
        if positional == ["config"] { return nestedItems(key: "gcloud config", prefix: value) }
        if positional == ["config", "configurations"] { return nestedItems(key: "gcloud config configurations", prefix: value) }
        if positional.count == 3, positional[0] == "config", positional[1] == "configurations",
           ["activate", "delete", "describe"].contains(positional[2]) {
            return namedItems(GCloudSources.configurations(env), kind: .profile, detail: "gcloud configuration", prefix: value)
        }
        if positional == ["config", "set", "project"] || positional.count == 2 && positional[0] == "projects" && positional[1] == "describe" {
            return namedItems(GCloudSources.projects(env), kind: .project, detail: "gcloud project", prefix: value)
        }
        return nil
    }

    static func azItems(positional: [String], value: String, env: CompletionEnvironment) -> [CompletionItem]? {
        if positional.count == 1, KnownTools.nested["az " + positional[0]] != nil {
            return nestedItems(key: "az " + positional[0], prefix: value)
        }
        return nil
    }

    static func subscriptionItems(value: String, env: CompletionEnvironment) -> [CompletionItem] {
        var items: [CompletionItem] = []
        for subscription in AzureSources.subscriptions(env) {
            if subscription.name.hasPrefix(value) {
                items.append(CompletionItem(insert: PathCompleter.escape(subscription.name), display: subscription.name, kind: .project, detail: subscription.id))
            }
            if subscription.id.hasPrefix(value), subscription.id != subscription.name {
                items.append(CompletionItem(insert: subscription.id, kind: .project, detail: subscription.name))
            }
        }
        return items
    }

    static func ansibleInventoryFiles(args: [String], directory: String, env: CompletionEnvironment) -> [String] {
        var files: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if (word == "-i" || word == "--inventory"), index + 1 < args.count {
                files.append(args[index + 1])
                index += 2
                continue
            }
            if word.hasPrefix("--inventory=") { files.append(String(word.dropFirst("--inventory=".count))) }
            else if word.hasPrefix("-i"), word.count > 2, !word.hasPrefix("--") { files.append(String(word.dropFirst(2))) }
            index += 1
        }
        if !files.isEmpty { return files }
        if let cfg = env.readText(atPath: directory + "/ansible.cfg") {
            for raw in cfg.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("inventory"), let equals = line.firstIndex(of: "=") else { continue }
                return line[line.index(after: equals)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        if let variable = env.variables["ANSIBLE_INVENTORY"] { return variable.split(separator: ",").map(String.init) }
        for name in ["inventory", "inventory.ini", "inventory.yml", "inventory.yaml", "hosts", "hosts.ini", "hosts.yml", "hosts.yaml"]
        where env.readText(atPath: directory + "/" + name) != nil || env.directoryEntries(atPath: directory + "/" + name) != nil {
            return [name]
        }
        return ["/etc/ansible/hosts"]
    }

    static func ansibleTargets(args: [String], directory: String, env: CompletionEnvironment) -> (hosts: [String], groups: [String]) {
        var hosts: [String] = []
        var groups: [String] = []
        for file in ansibleInventoryFiles(args: args, directory: directory, env: env) {
            let path = env.resolve(path: file, directory: directory)
            var texts: [String] = []
            if let text = env.readText(atPath: path) {
                texts.append(text)
            } else if let entries = env.directoryEntries(atPath: path) {
                texts += entries.filter { !$0.isDirectory }.compactMap { env.readText(atPath: path + "/" + $0.name) }
            } else if file.contains(",") {
                hosts += file.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            }
            for text in texts {
                let parsed = AnsibleInventory.parse(text)
                hosts += parsed.hosts
                groups += parsed.groups
            }
        }
        return (Array(Set(hosts)).sorted(), Array(Set(groups + ["all"])).sorted())
    }

    static func ansiblePatternItems(value: String, args: [String], directory: String, env: CompletionEnvironment) -> [CompletionItem] {
        var base = ""
        var prefix = value
        if let cut = value.lastIndex(where: { ":,!&".contains($0) }) {
            base = String(value[...cut])
            prefix = String(value[value.index(after: cut)...])
        }
        let targets = ansibleTargets(args: args, directory: directory, env: env)
        var items: [CompletionItem] = []
        for group in targets.groups where group.hasPrefix(prefix) {
            items.append(CompletionItem(insert: base + group, display: group, kind: .group, detail: "inventory group"))
        }
        for host in targets.hosts where host.hasPrefix(prefix) {
            items.append(CompletionItem(insert: base + host, display: host, kind: .host, detail: "inventory host"))
        }
        return items
    }

    static func voltaItems(positional: [String], value: String, env: CompletionEnvironment) -> [CompletionItem]? {
        guard let first = positional.first else { return nil }
        if ["install", "pin", "run", "list", "ls"].contains(first) {
            if let at = value.firstIndex(of: "@") {
                let tool = String(value[..<at])
                let prefix = String(value[value.index(after: at)...])
                return VoltaSources.versions(of: tool, env: env).filter { $0.hasPrefix(prefix) }.sorted().map {
                    CompletionItem(insert: tool + "@" + $0, display: $0, kind: .version, detail: tool + " version")
                }
            }
            return namedItems(["node", "npm", "yarn", "pnpm"] + VoltaSources.packages(env), kind: .package, detail: "volta tool", prefix: value)
        }
        if first == "uninstall" {
            return namedItems(VoltaSources.packages(env), kind: .package, detail: "installed package", prefix: value)
        }
        if first == "which" {
            return namedItems(VoltaSources.binaries(env), kind: .command, detail: "volta binary", prefix: value)
        }
        return nil
    }

    static func cloudItems(
        command: String, args: [String], positional: [String], value: String, directory: String, env: CompletionEnvironment
    ) -> [CompletionItem]? {
        switch command {
        case "helm":
            let options: Set<String> = ["-n", "--namespace", "--kube-context", "--kubeconfig", "--repo", "-f", "--values", "--set", "--version", "-o", "--output"]
            return helmItems(args: args, positional: words(args, valueOptions: options), value: value, directory: directory, env: env)
        case "gcloud":
            return gcloudItems(positional: positional, value: value, env: env)
        case "az":
            return azItems(positional: positional, value: value, env: env)
        case "volta":
            return voltaItems(positional: positional, value: value, env: env)
        case "ansible", "ansible-console":
            let options: Set<String> = ["-i", "--inventory", "-m", "--module-name", "-a", "--args", "-l", "--limit", "-u", "--user", "-e", "--extra-vars", "-f", "--forks", "-t", "--tree", "-c", "--connection", "-T", "--timeout"]
            return words(args, valueOptions: options).isEmpty ? ansiblePatternItems(value: value, args: args, directory: directory, env: env) : nil
        case "aws":
            let index = env.awsIndexPath()
            if positional.isEmpty {
                let discovered = AWSIndex.services(env)
                let indexed = index.map { AWSCompletionIndex.commands(path: $0, parent: "aws") } ?? []
                guard !discovered.isEmpty || !indexed.isEmpty else { return nil }
                var details: [String: String] = [:]
                for entry in KnownTools.allSubcommands("aws") { details[entry.0] = entry.1 }
                for name in discovered where details[name] == nil { details[name] = "aws service" }
                for entry in indexed { details[entry.name] = entry.detail ?? details[entry.name] ?? "aws service" }
                return details.keys.sorted().filter { $0.hasPrefix(value) }.map {
                    CompletionItem(insert: $0, kind: .subcommand, detail: details[$0])
                }
            }
            guard positional.count == 1 else { return nil }
            if let index {
                let indexed = AWSCompletionIndex.commands(path: index, parent: "aws." + positional[0])
                if !indexed.isEmpty {
                    return indexed.filter { $0.name.hasPrefix(value) }.map {
                        CompletionItem(insert: $0.name, kind: .subcommand, detail: $0.detail)
                    }
                }
            }
            if positional[0] == "s3" || positional[0] == "configure" {
                return nestedItems(key: "aws " + positional[0], prefix: value)
            }
            let operations = AWSIndex.operations(service: positional[0], env: env)
            return operations.isEmpty ? nil : namedItems(operations, kind: .subcommand, detail: "aws " + positional[0] + " operation", prefix: value)
        default:
            return nil
        }
    }

    static func cloudOptionItems(
        command: String, option: String, current: ShellToken?, args: [String], directory: String, env: CompletionEnvironment
    ) -> [CompletionItem]? {
        let value = current?.value ?? ""
        switch (command, option) {
        case ("helm", "-n"), ("helm", "--namespace"):
            return namedItems(kubeNamespaces(env, args: args), kind: .namespace, detail: "namespace", prefix: value)
        case ("helm", "--kube-context"):
            return namedItems(kubeConfig(env).contexts.map { $0.name }, kind: .context, detail: "context", prefix: value)
        case ("gcloud", "--configuration"):
            return namedItems(GCloudSources.configurations(env), kind: .profile, detail: "gcloud configuration", prefix: value)
        case ("gcloud", "--project"):
            return namedItems(GCloudSources.projects(env), kind: .project, detail: "gcloud project", prefix: value)
        case ("az", "--subscription"), ("az", "-s"):
            return subscriptionItems(value: value, env: env)
        case ("ansible", "-l"), ("ansible", "--limit"), ("ansible-playbook", "-l"), ("ansible-playbook", "--limit"),
             ("ansible-console", "-l"), ("ansible-console", "--limit"):
            return ansiblePatternItems(value: value, args: args, directory: directory, env: env)
        case ("ansible-inventory", "--host"):
            return ansibleTargets(args: args, directory: directory, env: env).hosts.filter { $0.hasPrefix(value) }.map {
                CompletionItem(insert: $0, kind: .host, detail: "inventory host")
            }
        case ("cargo", "-p"), ("cargo", "--package"):
            return namedItems(cargoWorkspaceMembers(directory: directory, env: env).map { $0.name }, kind: .package, detail: "workspace member", prefix: value)
        case ("cargo", "--features"), ("cargo", "-F"):
            var base = ""
            var prefix = value
            if let comma = value.lastIndex(of: ",") {
                base = String(value[...comma])
                prefix = String(value[value.index(after: comma)...])
            }
            return cargoFeatures(directory: directory, env: env).filter { $0.hasPrefix(prefix) }.map {
                CompletionItem(insert: base + $0, display: $0, kind: .choice, detail: "cargo feature", terminator: "")
            }
        case ("cargo", "--profile"):
            return namedItems(cargoProfiles(directory: directory, env: env), kind: .choice, detail: "cargo profile", prefix: value)
        default:
            return nil
        }
    }

    static func cargoManifestRoot(directory: String, env: CompletionEnvironment) -> (text: String, directory: String)? {
        var current = directory
        var first: (String, String)?
        for _ in 0..<8 {
            if let text = env.readText(atPath: current + "/Cargo.toml") {
                if first == nil { first = (text, current) }
                if text.contains("[workspace]") { return (text, current) }
            }
            guard current.count > 1 else { break }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
        return first
    }

    static func cargoWorkspaceMembers(directory: String, env: CompletionEnvironment) -> [(name: String, directory: String)] {
        guard let root = cargoManifestRoot(directory: directory, env: env) else { return [] }
        var members: [(name: String, directory: String)] = []
        if let package = ArgumentSources.parseCargo(root.text).package { members.append((package, root.directory)) }
        guard let start = root.text.range(of: "members") else { return members }
        let tail = root.text[start.upperBound...]
        guard let open = tail.firstIndex(of: "["), let close = tail[open...].firstIndex(of: "]") else { return members }
        let entries = tail[tail.index(after: open)..<close].split(separator: ",").map {
            ArgumentSources.unquote($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for entry in entries where !entry.isEmpty {
            var directories: [String] = []
            if entry.hasSuffix("/*") {
                let parent = root.directory + "/" + entry.dropLast(2)
                directories = (env.directoryEntries(atPath: parent) ?? []).filter(\.isDirectory).map { parent + "/" + $0.name }
            } else {
                directories = [root.directory + "/" + entry]
            }
            for member in directories {
                guard let text = env.readText(atPath: member + "/Cargo.toml"), let name = ArgumentSources.parseCargo(text).package else { continue }
                members.append((name, member))
            }
        }
        return members
    }

    static func cargoFeatures(directory: String, env: CompletionEnvironment) -> [String] {
        guard let manifest = ArgumentSources.findUp("Cargo.toml", from: directory, env: env) else { return [] }
        var inFeatures = false
        var names: [String] = []
        for raw in manifest.text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inFeatures = line == "[features]"; continue }
            guard inFeatures, let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            names.append(ArgumentSources.unquote(line[..<equals].trimmingCharacters(in: .whitespaces)))
        }
        return names
    }

    static func cargoProfiles(directory: String, env: CompletionEnvironment) -> [String] {
        var names = ["dev", "release", "test", "bench"]
        if let manifest = ArgumentSources.findUp("Cargo.toml", from: directory, env: env) {
            for raw in manifest.text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[profile."), line.hasSuffix("]") {
                    let inner = String(line.dropFirst("[profile.".count).dropLast())
                    names.append(String(inner.prefix { $0 != "." }))
                }
            }
        }
        return Array(Set(names)).sorted()
    }
}
