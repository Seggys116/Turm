import Foundation

nonisolated struct KubeOptions: Equatable, Sendable {
    var context: String?
    var namespace: String?
    var kubeconfig: String?
}

nonisolated extension CommandCompleter {
    static let kubeResourceCommands: Set<String> = [
        "get", "describe", "delete", "edit", "label", "annotate", "patch", "explain", "scale", "autoscale", "wait", "expose",
    ]
    static let kubeWorkloadPrefixes = ["pod/", "deployment/", "statefulset/", "daemonset/", "job/", "replicaset/"]

    static func kubeOptions(_ args: [String]) -> KubeOptions {
        var options = KubeOptions()
        var index = 0
        while index < args.count {
            let word = args[index]
            let next = index + 1 < args.count ? args[index + 1] : nil
            if word == "--context", let next { options.context = next; index += 2; continue }
            if word.hasPrefix("--context=") { options.context = String(word.dropFirst("--context=".count)) }
            if word == "-n" || word == "--namespace", let next { options.namespace = next; index += 2; continue }
            if word.hasPrefix("--namespace=") { options.namespace = String(word.dropFirst("--namespace=".count)) }
            if word.hasPrefix("-n"), word.count > 2, !word.hasPrefix("--") { options.namespace = String(word.dropFirst(2)) }
            if word == "--kubeconfig", let next { options.kubeconfig = next; index += 2; continue }
            if word.hasPrefix("--kubeconfig=") { options.kubeconfig = String(word.dropFirst("--kubeconfig=".count)) }
            index += 1
        }
        return options
    }

    static func kubeKindName(_ typed: String, env: CompletionEnvironment) -> String? {
        let base = typed.lowercased().split(separator: ".").first.map(String.init) ?? typed.lowercased()
        for resource in kubeResources(env) {
            let plural = resource.name
            if plural == base || resource.shortNames.contains(base) || resource.kind.lowercased() == base
                || plural == base + "s" || plural == base + "es" {
                return plural
            }
        }
        return CLIListing.validKind(base) ? base : nil
    }

    static func kubeInstances(kind: String, args: [String], env: CompletionEnvironment) -> [(kind: String, name: String)] {
        let options = kubeOptions(args)
        let invocation = CLIListing.kubectl(kind: kind, context: options.context, namespace: options.namespace, kubeconfig: options.kubeconfig)
        return CLIListing.kubectlNames(env.cliListing(invocation).joined(separator: "\n"))
    }

    static func instanceItems(kind: String, args: [String], value: String, typedKind: String?, env: CompletionEnvironment) -> [CompletionItem] {
        let namePrefix = typedKind == nil ? value : String(value.drop { $0 != "/" }.dropFirst())
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for entry in kubeInstances(kind: kind, args: args, env: env) where entry.name.hasPrefix(namePrefix) && seen.insert(entry.name).inserted {
            let insert = typedKind.map { $0 + "/" + entry.name } ?? entry.name
            items.append(CompletionItem(insert: PathCompleter.escape(insert), display: entry.name, kind: .resource, detail: entry.kind))
        }
        return items.sorted { $0.display < $1.display }
    }

    static func slashInstances(value: String, args: [String], env: CompletionEnvironment) -> [CompletionItem] {
        guard let slash = value.firstIndex(of: "/") else { return [] }
        let typed = String(value[..<slash])
        guard let kind = kubeKindName(typed, env: env) else { return [] }
        return instanceItems(kind: kind, args: args, value: value, typedKind: typed, env: env)
    }

    static func kubeNamespaces(_ env: CompletionEnvironment, args: [String] = []) -> [String] {
        let fromContexts = kubeConfig(env).contexts.compactMap(\.namespace)
        var names = fromContexts + ["default", "kube-system", "kube-public", "kube-node-lease"]
        if fromContexts.isEmpty {
            var options = kubeOptions(args)
            options.namespace = nil
            let invocation = CLIListing.kubectl(kind: "namespaces", context: options.context, namespace: nil, kubeconfig: options.kubeconfig)
            names += CLIListing.kubectlNames(env.cliListing(invocation).joined(separator: "\n")).map { $0.name }
        }
        return Array(Set(names)).sorted()
    }

    static func podItems(value: String, args: [String], env: CompletionEnvironment, withWorkloads: Bool) -> [CompletionItem] {
        if value.contains("/") { return slashInstances(value: value, args: args, env: env) }
        var items = instanceItems(kind: "pods", args: args, value: value, typedKind: nil, env: env)
        if withWorkloads {
            items += kubeWorkloadPrefixes.filter { $0.hasPrefix(value) }.map {
                CompletionItem(insert: $0, kind: .resource, detail: "workload", terminator: "")
            }
        }
        return items
    }

    static func kubectlItems(args: [String], value: String, directory: String, env: CompletionEnvironment) -> [CompletionItem]? {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") { index += KubeSources.globalValueOptions.contains(args[index]) ? 2 : 1 }
        guard index < args.count else { return subcommandItems(command: "kubectl", prefix: value, env: env) }
        let sub = args[index]
        let rest = Array(args[(index + 1)...])
        if awaitingValue(rest, valueOptions: KubeSources.globalValueOptions) { return nil }
        let positional = words(rest, valueOptions: KubeSources.globalValueOptions)

        switch sub {
        case _ where kubeResourceCommands.contains(sub):
            guard let first = positional.first else {
                if value.contains("/") { return slashInstances(value: value, args: args, env: env) }
                return resourceItems(value: value, env: env, filter: { _ in true })
            }
            guard !first.contains(","), !first.contains("/"), !value.contains("=") else { return [] }
            guard let kind = kubeKindName(first, env: env) else { return [] }
            return instanceItems(kind: kind, args: args, value: value, typedKind: nil, env: env)
        case "logs":
            guard positional.isEmpty else { return [] }
            return podItems(value: value, args: args, env: env, withWorkloads: true)
        case "exec", "attach":
            guard positional.isEmpty else { return [] }
            return podItems(value: value, args: args, env: env, withWorkloads: false)
        case "port-forward":
            guard positional.isEmpty else { return [] }
            return podItems(value: value, args: args, env: env, withWorkloads: true)
        case "cp":
            if value.contains(":") { return [] }
            let pods = instanceItems(kind: "pods", args: args, value: value, typedKind: nil, env: env).map {
                CompletionItem(insert: $0.insert + ":", display: $0.display, kind: .resource, detail: "pod", terminator: "")
            }
            return pods + pathItems(word: ShellTokenizer.tokenize(value).first { $0.kind == .word }, directory: directory, env: env, directoriesOnly: false)
        case "top":
            if positional.isEmpty { return namedItems(["pod", "node"], kind: .resource, detail: nil, prefix: value) }
            guard positional.count == 1, let kind = kubeKindName(positional[0], env: env), ["pods", "nodes"].contains(kind) else { return [] }
            return instanceItems(kind: kind, args: args, value: value, typedKind: nil, env: env)
        case "rollout":
            if positional.isEmpty { return nestedItems(key: "kubectl rollout", prefix: value) }
            if positional.count == 1 {
                if value.contains("/") { return slashInstances(value: value, args: args, env: env) }
                return resourceItems(value: value, env: env, filter: { ["deployments", "daemonsets", "statefulsets"].contains($0.name) })
            }
            guard positional.count == 2, !positional[1].contains("/"), let kind = kubeKindName(positional[1], env: env) else { return [] }
            return instanceItems(kind: kind, args: args, value: value, typedKind: nil, env: env)
        case "create":
            return positional.isEmpty ? nestedItems(key: "kubectl create", prefix: value) : nil
        case "config":
            if positional.isEmpty { return nestedItems(key: "kubectl config", prefix: value) }
            guard positional.count == 1 else { return [] }
            let config = kubeConfig(env)
            switch positional[0] {
            case "use-context", "delete-context", "rename-context", "get-contexts", "set-context":
                return namedItems(config.contexts.map(\.name), kind: .context, detail: "context", prefix: value)
            case "delete-cluster", "get-clusters", "set-cluster":
                return namedItems(config.clusters, kind: .context, detail: "cluster", prefix: value)
            case "delete-user", "get-users", "set-credentials":
                return namedItems(config.users, kind: .user, detail: "kubeconfig user", prefix: value)
            default:
                return []
            }
        case "cordon", "uncordon", "drain":
            guard positional.isEmpty else { return [] }
            return instanceItems(kind: "nodes", args: args, value: value, typedKind: nil, env: env)
        case "taint", "debug":
            return []
        default:
            return nil
        }
    }
}
