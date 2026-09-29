import Foundation

nonisolated enum DockerScope: Sendable {
    case running
    case stopped
    case all
}

nonisolated struct KubeContext: Equatable, Sendable {
    let name: String
    let cluster: String?
    let user: String?
    let namespace: String?
}

nonisolated struct KubeConfig: Equatable, Sendable {
    var currentContext: String?
    var contexts: [KubeContext] = []
    var clusters: [String] = []
    var users: [String] = []
}

nonisolated struct KubeResource: Equatable, Sendable {
    let name: String
    let shortNames: [String]
    let kind: String
    let group: String
}

nonisolated enum KubeSources {
    static let coreResources: [KubeResource] = {
        let table: [(String, [String], String, String)] = [
        ("pods", ["po"], "Pod", ""), ("services", ["svc"], "Service", ""), ("deployments", ["deploy"], "Deployment", "apps"),
        ("replicasets", ["rs"], "ReplicaSet", "apps"), ("statefulsets", ["sts"], "StatefulSet", "apps"),
        ("daemonsets", ["ds"], "DaemonSet", "apps"), ("jobs", [], "Job", "batch"), ("cronjobs", ["cj"], "CronJob", "batch"),
        ("configmaps", ["cm"], "ConfigMap", ""), ("secrets", [], "Secret", ""), ("namespaces", ["ns"], "Namespace", ""),
        ("nodes", ["no"], "Node", ""), ("persistentvolumes", ["pv"], "PersistentVolume", ""),
        ("persistentvolumeclaims", ["pvc"], "PersistentVolumeClaim", ""), ("ingresses", ["ing"], "Ingress", "networking.k8s.io"),
        ("events", ["ev"], "Event", ""), ("serviceaccounts", ["sa"], "ServiceAccount", ""), ("endpoints", ["ep"], "Endpoints", ""),
        ("roles", [], "Role", "rbac.authorization.k8s.io"), ("rolebindings", [], "RoleBinding", "rbac.authorization.k8s.io"),
        ("clusterroles", [], "ClusterRole", "rbac.authorization.k8s.io"),
        ("clusterrolebindings", [], "ClusterRoleBinding", "rbac.authorization.k8s.io"),
        ("networkpolicies", ["netpol"], "NetworkPolicy", "networking.k8s.io"),
        ("horizontalpodautoscalers", ["hpa"], "HorizontalPodAutoscaler", "autoscaling"),
        ("storageclasses", ["sc"], "StorageClass", "storage.k8s.io"),
        ("customresourcedefinitions", ["crd", "crds"], "CustomResourceDefinition", "apiextensions.k8s.io"),
        ("poddisruptionbudgets", ["pdb"], "PodDisruptionBudget", "policy"), ("resourcequotas", ["quota"], "ResourceQuota", ""),
        ("limitranges", ["limits"], "LimitRange", ""),
        ]
        return table.map { KubeResource(name: $0.0, shortNames: $0.1, kind: $0.2, group: $0.3) }
    }()

    static let globalValueOptions: Set<String> = [
        "-n", "--namespace", "--context", "--cluster", "--user", "--kubeconfig", "-s", "--server", "-o", "--output", "-l",
        "--selector", "-f", "--filename", "-c", "--container", "--field-selector", "-L", "--label-columns", "--sort-by",
        "--tail", "--since", "--as", "--token", "-k", "--kustomize", "--request-timeout",
    ]

    static func kubeconfigPaths(variables: [String: String], home: String) -> [String] {
        if let list = variables["KUBECONFIG"], !list.isEmpty {
            return list.split(separator: ":").map(String.init)
        }
        return [home + "/.kube/config"]
    }

    static func loadConfig(variables: [String: String], home: String, readText: (String) -> String?) -> KubeConfig {
        var merged = KubeConfig()
        for path in kubeconfigPaths(variables: variables, home: home) {
            guard let text = readText(path) else { continue }
            let parsed = parseConfig(text)
            if merged.currentContext == nil { merged.currentContext = parsed.currentContext }
            let knownContexts = Set(merged.contexts.map(\.name))
            merged.contexts += parsed.contexts.filter { !knownContexts.contains($0.name) }
            merged.clusters += parsed.clusters.filter { !merged.clusters.contains($0) }
            merged.users += parsed.users.filter { !merged.users.contains($0) }
        }
        return merged
    }

    static func field(_ text: String) -> (key: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = ArgumentSources.unquote(String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        return (key, value)
    }

    static func parseConfig(_ text: String) -> KubeConfig {
        struct Item {
            var name: String?
            var cluster: String?
            var user: String?
            var namespace: String?
        }
        var config = KubeConfig()
        var section = ""
        var dashIndent: Int?
        var fieldIndent = 0
        var item: Item?

        func flush() {
            guard let finished = item, let name = finished.name else {
                item = nil
                return
            }
            switch section {
            case "clusters": config.clusters.append(name)
            case "users": config.users.append(name)
            case "contexts":
                config.contexts.append(KubeContext(name: name, cluster: finished.cluster, user: finished.user, namespace: finished.namespace))
            default: break
            }
            item = nil
        }

        func apply(_ line: String, indent: Int) {
            guard let (key, value) = field(line) else { return }
            if indent == fieldIndent {
                if key == "name" { item?.name = value }
            } else if indent > fieldIndent, section == "contexts" {
                switch key {
                case "cluster": item?.cluster = value
                case "user": item?.user = value
                case "namespace": item?.namespace = value
                default: break
                }
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = raw.prefix { $0 == " " }.count
            if indent == 0, !trimmed.hasPrefix("-") {
                flush()
                dashIndent = nil
                guard let (key, value) = field(trimmed) else { continue }
                section = key
                if key == "current-context" { config.currentContext = value }
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if dashIndent == nil { dashIndent = indent }
                if indent == dashIndent {
                    flush()
                    item = Item()
                    fieldIndent = indent + 2
                    apply(String(trimmed.dropFirst(2)), indent: fieldIndent)
                    continue
                }
            }
            apply(trimmed, indent: indent)
        }
        flush()
        return config
    }

    static func parseDiscovery(_ text: String) -> [KubeResource] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let resources = object["resources"] as? [[String: Any]]
        else { return [] }
        let groupVersion = object["groupVersion"] as? String ?? ""
        let group = groupVersion.contains("/") ? String(groupVersion.split(separator: "/")[0]) : ""
        return resources.compactMap { entry in
            guard let name = entry["name"] as? String, !name.contains("/") else { return nil }
            return KubeResource(
                name: name,
                shortNames: entry["shortNames"] as? [String] ?? [],
                kind: entry["kind"] as? String ?? "",
                group: group
            )
        }
    }

    static func cachedResources(variables: [String: String], home: String, env: CompletionEnvironment) -> [KubeResource] {
        let root = (variables["KUBECACHEDIR"] ?? home + "/.kube/cache") + "/discovery"
        var found: [KubeResource] = []
        func walk(_ directory: String, depth: Int) {
            if let text = env.readText(atPath: directory + "/serverresources.json") { found += parseDiscovery(text) }
            guard depth < 3 else { return }
            for entry in env.directoryEntries(atPath: directory) ?? [] where entry.isDirectory {
                walk(directory + "/" + entry.name, depth: depth + 1)
            }
        }
        for host in env.directoryEntries(atPath: root) ?? [] where host.isDirectory {
            walk(root + "/" + host.name, depth: 0)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.name).inserted }
    }
}

nonisolated extension CommandCompleter {
    static let dockerValueOptions: Set<String> = [
        "-t", "--time", "-n", "--tail", "--since", "--until", "-s", "--signal", "-e", "--env", "-u", "--user", "-w", "--workdir",
        "--detach-keys", "--env-file", "-p", "--publish", "-v", "--volume", "--name", "-h", "--hostname", "--network", "--net",
        "--entrypoint", "-m", "--memory", "--cpus", "-l", "--label", "--restart", "--platform", "--add-host", "--dns",
        "--mount", "--pull", "--cap-add", "--cap-drop", "--device", "--log-driver", "--ulimit", "--user-agent", "-a", "--attach",
    ]
    static let dockerGlobalOptions: Set<String> = ["-H", "--host", "-c", "--context", "-l", "--log-level", "--config", "--tlscacert", "--tlscert", "--tlskey"]
    static let dockerContainerScopes: [String: DockerScope] = [
        "exec": .running, "stop": .running, "kill": .running, "pause": .running, "top": .running, "stats": .running,
        "attach": .running, "port": .running, "start": .stopped, "logs": .all, "restart": .all, "rm": .all, "rename": .all,
        "wait": .all, "diff": .all, "unpause": .all, "update": .all, "commit": .all, "export": .all, "inspect": .all,
    ]
    static let dockerMultiple: Set<String> = ["stop", "kill", "pause", "stats", "start", "restart", "rm", "unpause", "wait", "inspect", "update", "rmi", "save"]
    static let dockerImageCommands: Set<String> = ["run", "create", "rmi", "pull", "push", "history", "save", "tag", "scan", "inspect"]
    static let composeValueOptions: Set<String> = [
        "-f", "--file", "-p", "--project-name", "--profile", "--env-file", "--project-directory", "--ansi", "--parallel",
    ]
    static let composeServiceCommands: [String: Bool] = [
        "up": true, "logs": true, "ps": true, "restart": true, "start": true, "stop": true, "exec": false, "run": false,
        "build": true, "pull": true, "push": true, "rm": true, "kill": true, "pause": true, "unpause": true, "top": true,
        "port": false, "images": true, "create": true, "watch": true,
    ]
    static let composeFiles = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    static func words(_ args: [String], valueOptions: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if word == "--" {
                result += args[(index + 1)...]
                break
            }
            if word.hasPrefix("-"), word.count > 1 {
                index += valueOptions.contains(word) ? 2 : 1
            } else {
                result.append(word)
                index += 1
            }
        }
        return result
    }

    static func awaitingValue(_ args: [String], valueOptions: Set<String>) -> Bool {
        guard let last = args.last, last.hasPrefix("-"), !last.contains("=") else { return false }
        return valueOptions.contains(last)
    }

    static func dockerContextNames(_ env: CompletionEnvironment) -> [String] {
        DockerEngine.contextNames(
            home: env.homeDirectory, entries: { env.directoryEntries(atPath: $0) }, readText: { env.readText(atPath: $0) }
        )
    }

    static func dockerContainerItems(_ containers: [DockerContainer], scope: DockerScope, prefix: String) -> [CompletionItem] {
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for container in containers {
            let running = container.state == "running"
            switch scope {
            case .running where !running, .stopped where running: continue
            default: break
            }
            for name in (container.names.isEmpty ? [container.id] : container.names) where name.hasPrefix(prefix) && seen.insert(name).inserted {
                items.append(CompletionItem(
                    insert: PathCompleter.escape(name), display: name, kind: .container,
                    detail: container.image.isEmpty ? container.state : container.image + " - " + container.state
                ))
            }
        }
        return items.sorted { $0.display < $1.display }
    }

    static func dockerImageItems(_ images: [DockerImage], prefix: String) -> [CompletionItem] {
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for image in images {
            for name in (image.names.isEmpty ? [image.id] : image.names) where name.hasPrefix(prefix) && seen.insert(name).inserted {
                items.append(CompletionItem(
                    insert: PathCompleter.escape(name), display: name, kind: .image,
                    detail: image.names.isEmpty ? "untagged image" : "image " + image.id
                ))
            }
        }
        return items.sorted { $0.display < $1.display }
    }

    static func namedItems(_ names: [String], kind: CompletionItem.Kind, detail: String?, prefix: String) -> [CompletionItem] {
        var seen = Set<String>()
        return names.filter { $0.hasPrefix(prefix) && seen.insert($0).inserted }.map {
            CompletionItem(insert: PathCompleter.escape($0), display: $0, kind: kind, detail: detail)
        }
    }

    static func nestedItems(key: String, prefix: String) -> [CompletionItem] {
        (KnownTools.nested[key] ?? []).filter { $0.0.hasPrefix(prefix) }.map {
            CompletionItem(insert: $0.0, kind: .subcommand, detail: $0.1)
        }
    }

    static func kubeConfig(_ env: CompletionEnvironment) -> KubeConfig {
        KubeSources.loadConfig(variables: env.variables, home: env.homeDirectory, readText: { env.readText(atPath: $0) })
    }

    static func kubeResources(_ env: CompletionEnvironment) -> [KubeResource] {
        let cached = KubeSources.cachedResources(variables: env.variables, home: env.homeDirectory, env: env)
        return cached.isEmpty ? KubeSources.coreResources : cached
    }

    static func resourceItems(value: String, env: CompletionEnvironment, filter: (KubeResource) -> Bool) -> [CompletionItem] {
        var base = ""
        var prefix = value
        if let comma = value.lastIndex(of: ",") {
            base = String(value[...comma])
            prefix = String(value[value.index(after: comma)...])
        }
        var items: [CompletionItem] = []
        var seen = Set<String>()
        for resource in kubeResources(env) where filter(resource) {
            let label = resource.group.isEmpty ? resource.kind : resource.kind + " (" + resource.group + ")"
            if resource.name.hasPrefix(prefix), seen.insert(resource.name).inserted {
                items.append(CompletionItem(insert: base + resource.name, display: resource.name, kind: .resource, detail: label))
            }
            for short in resource.shortNames where short.hasPrefix(prefix) && seen.insert(short).inserted {
                items.append(CompletionItem(insert: base + short, display: short, kind: .resource, detail: "short name for " + resource.name))
            }
        }
        return items.sorted { $0.display < $1.display }
    }
}
