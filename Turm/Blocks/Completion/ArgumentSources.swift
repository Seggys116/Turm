import Foundation

nonisolated enum KnownCommands {
    static let subcommands: [String: [(String, String)]] = [
        "npm": [
            ("install", "Install a package"), ("uninstall", "Remove a package"), ("run", "Run a package script"),
            ("run-script", "Run a package script"), ("test", "Run the test script"), ("start", "Run the start script"),
            ("init", "Create a package.json"), ("update", "Update packages"), ("publish", "Publish a package"),
            ("ci", "Clean install from lockfile"), ("audit", "Run a security audit"), ("outdated", "Check for outdated packages"),
            ("list", "List installed packages"), ("link", "Symlink a package folder"), ("exec", "Run a package binary"),
            ("cache", "Manipulate the package cache"), ("config", "Manage npm configuration"), ("view", "View registry info"),
            ("login", "Log in to the registry"), ("pack", "Create a tarball"), ("version", "Bump the package version"),
        ],
        "yarn": [
            ("add", "Add a dependency"), ("install", "Install dependencies"), ("remove", "Remove a dependency"),
            ("run", "Run a package script"), ("test", "Run the test script"), ("start", "Run the start script"),
            ("init", "Create a package.json"), ("upgrade", "Upgrade dependencies"), ("publish", "Publish a package"),
            ("build", "Run the build script"), ("dlx", "Run a package in a temporary environment"), ("workspaces", "Manage workspaces"),
            ("why", "Explain why a package is installed"), ("link", "Symlink a package folder"), ("cache", "Manage the cache"),
        ],
        "pnpm": [
            ("add", "Add a dependency"), ("install", "Install dependencies"), ("remove", "Remove a dependency"),
            ("run", "Run a package script"), ("test", "Run the test script"), ("start", "Run the start script"),
            ("init", "Create a package.json"), ("update", "Update dependencies"), ("publish", "Publish a package"),
            ("dlx", "Run a package in a temporary environment"), ("exec", "Run a shell command in the project"),
            ("outdated", "Check for outdated packages"), ("store", "Manage the package store"), ("why", "Explain why a package is installed"),
        ],
        "bun": [
            ("run", "Run a script or file"), ("install", "Install dependencies"), ("add", "Add a dependency"),
            ("remove", "Remove a dependency"), ("test", "Run tests"), ("build", "Bundle files"), ("init", "Create a project"),
            ("create", "Scaffold a project"), ("x", "Run a package binary"), ("upgrade", "Upgrade bun"), ("link", "Link a package"),
            ("update", "Update dependencies"), ("pm", "Package manager utilities"), ("dev", "Start the dev server"),
        ],
        "cargo": [
            ("build", "Compile the package"), ("check", "Check the package for errors"), ("clean", "Remove build artifacts"),
            ("doc", "Build package documentation"), ("new", "Create a new package"), ("init", "Create a package in an existing directory"),
            ("add", "Add a dependency"), ("remove", "Remove a dependency"), ("run", "Run a binary or example"),
            ("test", "Run the tests"), ("bench", "Run the benchmarks"), ("update", "Update dependencies in Cargo.lock"),
            ("search", "Search crates.io"), ("publish", "Publish the package"), ("install", "Install a binary"),
            ("uninstall", "Remove an installed binary"), ("fmt", "Format the source code"), ("clippy", "Run the linter"),
            ("fix", "Apply compiler suggestions"), ("tree", "Display the dependency tree"), ("metadata", "Output package metadata"),
            ("vendor", "Vendor all dependencies"), ("fetch", "Fetch dependencies"), ("login", "Save a registry token"),
            ("package", "Assemble the package"), ("yank", "Remove a pushed crate from the index"), ("rustc", "Compile with extra rustc flags"),
            ("rustdoc", "Build documentation with extra flags"), ("locate-project", "Print the manifest location"),
        ],
        "brew": [
            ("install", "Install a formula or cask"), ("uninstall", "Uninstall a formula or cask"), ("upgrade", "Upgrade installed packages"),
            ("update", "Fetch the newest version of Homebrew"), ("list", "List installed packages"), ("info", "Show package information"),
            ("search", "Search for packages"), ("outdated", "List outdated packages"), ("cleanup", "Remove old versions"),
            ("doctor", "Check the system for problems"), ("services", "Manage background services"), ("tap", "Add a tap"),
            ("untap", "Remove a tap"), ("link", "Symlink a keg"), ("unlink", "Remove keg symlinks"), ("pin", "Prevent upgrades"),
            ("unpin", "Allow upgrades"), ("deps", "Show dependencies"), ("uses", "Show dependents"), ("leaves", "List packages not required by others"),
            ("fetch", "Download a package"), ("home", "Open the homepage"), ("reinstall", "Reinstall a package"), ("bundle", "Install from a Brewfile"),
            ("autoremove", "Remove unneeded dependencies"), ("cat", "Print the source of a package"), ("config", "Show Homebrew configuration"),
        ],
        "docker": [
            ("run", "Create and run a new container"), ("ps", "List containers"), ("build", "Build an image"), ("pull", "Download an image"),
            ("push", "Upload an image"), ("images", "List images"), ("exec", "Run a command in a running container"),
            ("logs", "Fetch the logs of a container"), ("stop", "Stop containers"), ("start", "Start containers"),
            ("restart", "Restart containers"), ("rm", "Remove containers"), ("rmi", "Remove images"), ("compose", "Docker Compose"),
            ("network", "Manage networks"), ("volume", "Manage volumes"), ("system", "Manage Docker"), ("inspect", "Return low-level information"),
            ("cp", "Copy files between a container and the host"), ("login", "Log in to a registry"), ("tag", "Tag an image"),
            ("container", "Manage containers"), ("image", "Manage images"), ("buildx", "Extended build capabilities"),
        ],
        "kubectl": [
            ("get", "Display resources"), ("describe", "Show details of a resource"), ("apply", "Apply a configuration"),
            ("delete", "Delete resources"), ("logs", "Print the logs for a container"), ("exec", "Execute a command in a container"),
            ("create", "Create a resource"), ("edit", "Edit a resource"), ("config", "Modify kubeconfig files"),
            ("port-forward", "Forward local ports to a pod"), ("rollout", "Manage a rollout"), ("scale", "Set a new size"),
            ("expose", "Expose a resource as a service"), ("run", "Run an image in a pod"), ("cp", "Copy files to and from containers"),
            ("top", "Display resource usage"), ("label", "Update labels"), ("annotate", "Update annotations"), ("patch", "Update fields"),
            ("cluster-info", "Display cluster information"), ("version", "Print client and server versions"), ("api-resources", "List API resources"),
            ("explain", "Documentation of resources"), ("diff", "Diff live and applied versions"), ("wait", "Wait for a condition"),
            ("cordon", "Mark a node unschedulable"), ("drain", "Drain a node"), ("taint", "Update node taints"), ("auth", "Inspect authorization"),
        ],
    ]

    static let optionKinds: [String: [String: ValueKind]] = [
        "ssh": ["-i": .file, "-l": .user, "-F": .file, "-J": .host, "-S": .file, "-E": .file],
        "scp": ["-i": .file, "-F": .file, "-J": .host, "-S": .file],
        "sftp": ["-i": .file, "-F": .file, "-J": .host, "-S": .file],
        "make": ["-C": .directory, "--directory": .directory, "-f": .file, "--file": .file],
        "cargo": ["--manifest-path": .file, "--target-dir": .directory],
        "npm": ["--prefix": .directory, "--userconfig": .file],
        "curl": ["-o": .file, "--output": .file, "-K": .file, "--config": .file, "-T": .file],
        "grep": ["-f": .file, "--file": .file],
        "tar": ["-C": .directory, "-f": .file, "--file": .file, "--directory": .directory],
        "git": ["-C": .directory],
        "kubectl": ["--kubeconfig": .file, "-f": .file, "--filename": .file, "-k": .directory, "--kustomize": .directory],
        "terraform": ["-chdir": .directory],
        "pip": ["-r": .file, "--requirement": .file, "-c": .file, "--constraint": .file, "-t": .directory, "--target": .directory],
        "pip3": ["-r": .file, "--requirement": .file, "-c": .file, "--constraint": .file, "-t": .directory, "--target": .directory],
        "ansible": ["-i": .file, "--inventory": .file],
        "ansible-playbook": ["-i": .file, "--inventory": .file],
        "docker": ["--config": .directory, "--env-file": .file],
    ]

    static let fileCommands: Set<String> = [
        "cat", "ls", "cp", "mv", "rm", "mkdir", "touch", "open", "vim", "nvim", "nano", "less", "more", "head", "tail",
        "code", "chmod", "chown", "ln", "find", "diff", "wc", "sort", "file", "du", "df", "stat", "source", "bat", "tree",
    ]

    static let signals = ["HUP", "INT", "QUIT", "KILL", "TERM", "USR1", "USR2", "STOP", "CONT", "TSTP"]

    static let installedBrewCommands: Set<String> = [
        "uninstall", "remove", "rm", "upgrade", "reinstall", "unlink", "link", "pin", "unpin", "services", "list", "ls",
    ]
    static let anyBrewCommands: Set<String> = ["install", "info", "fetch", "home", "homepage", "deps", "uses", "cat", "audit"]
}

nonisolated enum ArgumentSources {
    static func findUp(_ name: String, from directory: String, env: CompletionEnvironment) -> (text: String, directory: String)? {
        var current = directory
        for _ in 0..<8 {
            if let text = env.readText(atPath: current + "/" + name) { return (text, current) }
            guard current.count > 1 else { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
        return nil
    }

    static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        func match(_ i: Int, _ j: Int) -> Bool {
            if i == p.count { return j == t.count }
            if p[i] == "*" {
                var k = j
                while k <= t.count {
                    if match(i + 1, k) { return true }
                    k += 1
                }
                return false
            }
            guard j < t.count else { return false }
            return (p[i] == "?" || p[i] == t[j]) && match(i + 1, j + 1)
        }
        return match(0, 0)
    }

    static func unquote(_ text: String) -> String {
        var result = text
        if result.count >= 2, let first = result.first, first == "\"" || first == "'", result.last == first {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }

    static func sshHosts(_ env: CompletionEnvironment) -> [String] {
        var hosts: [String] = []
        collectSSHConfig(path: env.homeDirectory + "/.ssh/config", env: env, depth: 0, into: &hosts)
        collectSSHConfig(path: "/etc/ssh/ssh_config", env: env, depth: 0, into: &hosts)
        for path in [env.homeDirectory + "/.ssh/known_hosts", "/etc/ssh/ssh_known_hosts"] {
            hosts += knownHosts(env.readText(atPath: path) ?? "")
        }
        return Array(Set(hosts)).sorted()
    }

    static func collectSSHConfig(path: String, env: CompletionEnvironment, depth: Int, into hosts: inout [String]) {
        guard depth < 4, let text = env.readText(atPath: path) else { return }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let split = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" })
            else { continue }
            let key = line[..<split].lowercased()
            let rest = line[line.index(after: split)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            let words = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { unquote(String($0)) }
            if key == "host" {
                for name in words where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
                    hosts.append(name)
                }
            } else if key == "include" {
                for pattern in words {
                    for included in expandInclude(pattern, env: env) {
                        collectSSHConfig(path: included, env: env, depth: depth + 1, into: &hosts)
                    }
                }
            }
        }
    }

    static func expandInclude(_ pattern: String, env: CompletionEnvironment) -> [String] {
        var resolved = pattern
        if resolved.hasPrefix("~/") {
            resolved = env.homeDirectory + resolved.dropFirst()
        } else if !resolved.hasPrefix("/") {
            resolved = env.homeDirectory + "/.ssh/" + resolved
        }
        guard resolved.contains("*") || resolved.contains("?") else { return [resolved] }
        let directory = (resolved as NSString).deletingLastPathComponent
        let filePattern = (resolved as NSString).lastPathComponent
        let entries = env.directoryEntries(atPath: directory) ?? []
        return entries
            .filter { !$0.isDirectory && wildcardMatch(filePattern, $0.name) }
            .map { directory + "/" + $0.name }
            .sorted()
    }

    static func knownHosts(_ text: String) -> [String] {
        var hosts: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard var field = fields.first.map(String.init), !field.hasPrefix("#") else { continue }
            if field.hasPrefix("@") {
                guard fields.count > 1 else { continue }
                field = String(fields[1])
            }
            if field.hasPrefix("|") { continue }
            for entry in field.split(separator: ",") {
                var host = String(entry)
                if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                    host = String(host[host.index(after: host.startIndex)..<close])
                }
                if host.contains("*") || host.contains("?") || host.hasPrefix("!") || host.isEmpty { continue }
                hosts.append(host)
            }
        }
        return hosts
    }

    static func hostNames(_ env: CompletionEnvironment) -> [String] {
        var hosts = sshHosts(env)
        for raw in (env.readText(atPath: "/etc/hosts") ?? "").components(separatedBy: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            hosts += fields.dropFirst().map(String.init)
        }
        return Array(Set(hosts)).sorted()
    }

    static func names(fromColonFile text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard !line.hasPrefix("#"), let name = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first,
                  !name.isEmpty, !name.hasPrefix("_")
            else { return nil }
            return String(name)
        }
    }

    static func users(_ env: CompletionEnvironment) -> [String] {
        var result = names(fromColonFile: env.readText(atPath: "/etc/passwd") ?? "")
        for entry in env.directoryEntries(atPath: "/Users") ?? [] where entry.isDirectory && !entry.name.hasPrefix(".") && entry.name != "Shared" {
            result.append(entry.name)
        }
        return Array(Set(result)).sorted()
    }

    static func groups(_ env: CompletionEnvironment) -> [String] {
        Array(Set(names(fromColonFile: env.readText(atPath: "/etc/group") ?? ""))).sorted()
    }

    static func packageScripts(directory: String, env: CompletionEnvironment) -> [(name: String, command: String)] {
        guard let found = findUp("package.json", from: directory, env: env),
              let object = try? JSONSerialization.jsonObject(with: Data(found.text.utf8)) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any]
        else { return [] }
        return scripts.keys.sorted().map { ($0, scripts[$0] as? String ?? "") }
    }

    static func packageDependencies(directory: String, env: CompletionEnvironment) -> [String] {
        guard let found = findUp("package.json", from: directory, env: env),
              let object = try? JSONSerialization.jsonObject(with: Data(found.text.utf8)) as? [String: Any]
        else { return [] }
        var names: [String] = []
        for key in ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"] {
            names += (object[key] as? [String: Any])?.keys.map { $0 } ?? []
        }
        return Array(Set(names)).sorted()
    }

    static func nodeBinaries(directory: String, env: CompletionEnvironment) -> [String] {
        var current = directory
        for _ in 0..<8 {
            if let entries = env.directoryEntries(atPath: current + "/node_modules/.bin") {
                return entries.filter { !$0.isDirectory && !$0.name.hasPrefix(".") }.map { $0.name }.sorted()
            }
            guard current.count > 1 else { break }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
        return []
    }

    static func brewTaps(env: CompletionEnvironment) -> [String] {
        var taps: [String] = []
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let root = prefix + "/Library/Taps"
            for owner in env.directoryEntries(atPath: root) ?? [] where owner.isDirectory {
                for repo in env.directoryEntries(atPath: root + "/" + owner.name) ?? [] where repo.isDirectory {
                    let short = repo.name.hasPrefix("homebrew-") ? String(repo.name.dropFirst("homebrew-".count)) : repo.name
                    taps.append(owner.name + "/" + short)
                }
            }
        }
        return Array(Set(taps)).sorted()
    }

    static func makeTargets(_ text: String) -> [String] {
        var targets: [String] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: "\n") {
            guard let first = line.first, !first.isWhitespace, first != "#", first != ".", first != "$",
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let before = line[..<colon]
            if before.contains("=") || before.contains("$") || before.contains("%") || before.contains("(") { continue }
            let after = line.index(after: colon)
            if after < line.endIndex, line[after] == "=" { continue }
            for name in before.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let target = String(name)
                guard let head = target.first, head.isLetter || head.isNumber || head == "_",
                      target.allSatisfy({ $0.isLetter || $0.isNumber || "_./+-".contains($0) }),
                      seen.insert(target).inserted
                else { continue }
                targets.append(target)
            }
        }
        return targets
    }

    static func justRecipes(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"^@?([A-Za-z_][A-Za-z0-9_-]*)[^:\n]*:(?!=)"#, options: .anchorsMatchLines) else { return [] }
        var recipes: [String] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: text) else { return }
            let name = String(text[range])
            if !name.hasPrefix("_"), seen.insert(name).inserted { recipes.append(name) }
        }
        return recipes
    }

    nonisolated struct CargoManifest: Equatable {
        var package: String?
        var bins: [String] = []
        var examples: [String] = []
        var tests: [String] = []
        var benches: [String] = []
    }

    static func parseCargo(_ text: String) -> CargoManifest {
        var manifest = CargoManifest()
        var section = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line
                continue
            }
            guard line.hasPrefix("name"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "name" else { continue }
            let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            switch section {
            case "[package]": manifest.package = value
            case "[[bin]]": manifest.bins.append(value)
            case "[[example]]": manifest.examples.append(value)
            case "[[test]]": manifest.tests.append(value)
            case "[[bench]]": manifest.benches.append(value)
            default: break
            }
        }
        return manifest
    }

    static func cargoTargets(option: String, directory: String, env: CompletionEnvironment) -> [String] {
        guard let found = findUp("Cargo.toml", from: directory, env: env) else { return [] }
        var directories = [found.directory]
        directories += CommandCompleter.cargoWorkspaceMembers(directory: directory, env: env).map { $0.directory }
        var names: [String] = []
        for folder in Set(directories) {
            guard let text = env.readText(atPath: folder + "/Cargo.toml") else { continue }
            let manifest = parseCargo(text)
            func stems(_ sub: String) -> [String] {
                (env.directoryEntries(atPath: folder + "/" + sub) ?? []).compactMap { entry in
                    if entry.isDirectory { return entry.name }
                    return entry.name.hasSuffix(".rs") ? String(entry.name.dropLast(3)) : nil
                }
            }
            switch option {
            case "--bin":
                names += manifest.bins + stems("src/bin")
                if let package = manifest.package, env.fileExists(atPath: folder + "/src/main.rs") { names.append(package) }
            case "--example":
                names += manifest.examples + stems("examples")
            case "--test":
                names += manifest.tests + stems("tests")
            case "--bench":
                names += manifest.benches + stems("benches")
            default:
                break
            }
        }
        return Array(Set(names)).sorted()
    }

    static func brewPackages(command: String, casksOnly: Bool, formulaeOnly: Bool, env: CompletionEnvironment) -> [(name: String, detail: String)] {
        var prefixes: [String] = []
        if let configured = env.variables["HOMEBREW_PREFIX"] { prefixes.append(configured) }
        for fallback in ["/opt/homebrew", "/usr/local"] where !prefixes.contains(fallback) { prefixes.append(fallback) }
        var result: [String: String] = [:]
        func names(_ path: String) -> [String] {
            (env.directoryEntries(atPath: path) ?? []).filter { !$0.name.hasPrefix(".") }.map(\.name)
        }
        let installedOnly = KnownCommands.installedBrewCommands.contains(command)
        for prefix in prefixes {
            if !casksOnly { for name in names(prefix + "/Cellar") { result[name] = "installed formula" } }
            if !formulaeOnly { for name in names(prefix + "/Caskroom") { result[name] = "installed cask" } }
        }
        if !installedOnly {
            let cache = env.variables["HOMEBREW_CACHE"] ?? env.homeDirectory + "/Library/Caches/Homebrew"
            func lines(_ file: String) -> [String] {
                (env.readText(atPath: cache + "/api/" + file) ?? "").split(separator: "\n").map(String.init)
            }
            if !casksOnly { for name in lines("formula_names.txt") where result[name] == nil { result[name] = "formula" } }
            if !formulaeOnly { for name in lines("cask_names.txt") where result[name] == nil { result[name] = "cask" } }
            for prefix in prefixes {
                for owner in names(prefix + "/Library/Taps") {
                    for repo in names(prefix + "/Library/Taps/" + owner) {
                        let root = prefix + "/Library/Taps/" + owner + "/" + repo
                        for (folder, label, wanted) in [("Formula", "formula", !casksOnly), ("Casks", "cask", !formulaeOnly)] where wanted {
                            for entry in env.directoryEntries(atPath: root + "/" + folder) ?? [] {
                                if entry.isDirectory {
                                    for inner in names(root + "/" + folder + "/" + entry.name) where inner.hasSuffix(".rb") {
                                        let name = String(inner.dropLast(3))
                                        if result[name] == nil { result[name] = label }
                                    }
                                } else if entry.name.hasSuffix(".rb") {
                                    let name = String(entry.name.dropLast(3))
                                    if result[name] == nil { result[name] = label }
                                }
                            }
                        }
                    }
                }
            }
        }
        return result.keys.sorted().map { ($0, result[$0] ?? "") }
    }
}
