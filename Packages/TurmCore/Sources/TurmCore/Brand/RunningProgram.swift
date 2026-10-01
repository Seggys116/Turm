import Foundation

public nonisolated struct RunningProgram: Codable, Sendable, Equatable, Hashable {
    public let name: String
    public let iconKey: String?
    public let symbol: String

    public init(name: String, iconKey: String?, symbol: String) {
        self.name = name
        self.iconKey = iconKey
        self.symbol = symbol
    }
}

public nonisolated extension RunningProgram {
    static func resolve(command: String) -> RunningProgram? {
        for words in segments(of: command) {
            if let program = program(in: words) { return program }
        }
        return nil
    }

    /// Looks a program up by the argv of a live process, so interpreters running a known script are seen through.
    static func resolve(arguments: [String]) -> RunningProgram? {
        program(in: arguments)
    }

    static func resolve(executable: String) -> RunningProgram? {
        catalog[normalized(basename(executable))]
    }

    static var iconKeys: Set<String> { Set(catalog.values.compactMap(\.iconKey)) }

    static func displayed(isRunning: Bool, running: RunningProgram?, lastCommand: String?) -> RunningProgram? {
        if isRunning { return running }
        return lastCommand.flatMap { resolve(command: $0) }
    }
}

private nonisolated extension RunningProgram {
    static let wrappers: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-C", "-S", "-P"],
        "nice": ["-n"],
        "caffeinate": ["-t", "-w"],
        "time": [],
        "nohup": [],
        "exec": [],
        "command": [],
        "builtin": [],
        "stdbuf": [],
    ]

    static let optionArguments: Set<String> = [
        "--with", "--python", "-p", "--package", "--directory", "--project", "--from", "--with-requirements", "-r",
    ]

    /// Package runners map to the tool they run; the value names the program shown when the inner one is unknown.
    static let bareRunners: [String: String] = ["npx": "npm", "bunx": "bun", "pnpx": "pnpm", "uvx": "uv"]

    static let subcommandRunners: [String: Set<String>] = [
        "pnpm": ["dlx", "exec"],
        "yarn": ["dlx"],
        "npm": ["exec", "x"],
        "bun": ["x"],
        "uv": ["run", "tool"],
        "poetry": ["run"],
        "pipx": ["run"],
        "bundle": ["exec"],
        "pdm": ["run"],
    ]

    static let packageAliases: [String: String] = [
        "claude-code": "claude",
        "gemini-cli": "gemini",
        "opencode-ai": "opencode",
        "create-next-app": "next",
        "create-vite": "vite",
    ]

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "tsx", "ts-node"]

    static func program(in words: [String]) -> RunningProgram? {
        var index = 0
        while index < words.count {
            let word = words[index]
            if isAssignment(word) {
                index += 1
                continue
            }
            let base = normalized(basename(word))
            if let skipped = wrappers[base] {
                index += 1
                while index < words.count {
                    let next = words[index]
                    if next.hasPrefix("-") {
                        index += skipped.contains(next) ? 2 : 1
                    } else if base == "env", isAssignment(next) {
                        index += 1
                    } else {
                        break
                    }
                }
                continue
            }
            return program(startingAt: base, in: words, at: index)
        }
        return nil
    }

    static func program(startingAt base: String, in words: [String], at index: Int) -> RunningProgram? {
        let rest = Array(words[(index + 1)...])
        if let fallback = bareRunners[base] {
            return runPackage(in: rest) ?? catalog[fallback]
        }
        if let subs = subcommandRunners[base], var first = rest.first {
            var inner = Array(rest.dropFirst())
            if base == "uv", first == "tool" {
                guard inner.first == "run" else { return catalog[base] }
                inner.removeFirst()
                first = "run"
            }
            if subs.contains(first) {
                return runPackage(in: inner) ?? catalog[base]
            }
        }
        if base == "gh", rest.first == "copilot" {
            return catalog["copilot"]
        }
        if interpreters.contains(base), let found = script(in: rest, interpreter: base) {
            return found
        }
        return catalog[base]
    }

    static func runPackage(in words: [String]) -> RunningProgram? {
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("-") {
                index += optionArguments.contains(word) ? 2 : 1
                continue
            }
            if isAssignment(word) {
                index += 1
                continue
            }
            var package = word
            if let at = package.dropFirst().lastIndex(of: "@") { package = String(package[..<at]) }
            let tool = normalized(basename(package))
            if let alias = packageAliases[tool] { return catalog[alias] }
            if wrappers[tool] != nil || subcommandRunners[tool] != nil || bareRunners[tool] != nil || interpreters.contains(tool) {
                return program(in: Array(words[index...]))
            }
            return catalog[tool]
        }
        return nil
    }

    /// Interpreters running `-m module`, a framework entry script, or a script named after a known tool.
    static func script(in words: [String], interpreter: String) -> RunningProgram? {
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "-m" || word == "--module", index + 1 < words.count {
                let module = normalized(words[index + 1].split(separator: ".").first.map(String.init) ?? "")
                return module == interpreter ? nil : catalog[module]
            }
            if word == "-e" || word == "-c" || word == "--eval" || word == "-p" { return nil }
            if word.hasPrefix("-") {
                index += ["-r", "--require", "--loader", "--import"].contains(word) ? 2 : 1
                continue
            }
            let file = basename(word)
            if file == "manage.py" { return catalog["django"] }
            let stem = file.split(separator: ".").first.map(String.init) ?? file
            guard let found = catalog[stem.lowercased()], found.iconKey != interpreterIcon(interpreter) else { return nil }
            return found
        }
        return nil
    }

    static func interpreterIcon(_ interpreter: String) -> String? {
        catalog[normalized(interpreter)]?.iconKey
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func basename(_ word: String) -> String {
        word.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? word
    }

    static func normalized(_ name: String) -> String {
        let lowered = name.lowercased()
        for family in ["python", "pip"] where lowered.hasPrefix(family) {
            let suffix = lowered.dropFirst(family.count)
            if suffix.allSatisfy({ $0.isNumber || $0 == "." }) { return family }
        }
        return lowered
    }

    static func segments(of line: String) -> [[String]] {
        var result: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        let chars = Array(line)
        var index = 0

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { result.append(words) }
            words = []
        }

        while index < chars.count {
            let char = chars[index]
            if let open = quote {
                if char == open {
                    quote = nil
                } else if char == "\\", open == "\"", index + 1 < chars.count {
                    index += 1
                    word.append(chars[index])
                } else {
                    word.append(char)
                }
            } else if char == "\\", index + 1 < chars.count {
                index += 1
                word.append(chars[index])
                inWord = true
            } else if char == "'" || char == "\"" {
                quote = char
                inWord = true
            } else if char == " " || char == "\t" {
                endWord()
            } else if char == ";" || char == "\n" || char == "|" || char == "(" || char == ")" {
                endSegment()
            } else if char == "&" {
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                let previous = index > 0 ? chars[index - 1] : nil
                if next == "&" {
                    endSegment()
                    index += 1
                } else if previous == ">" || previous == "<" || next == ">" {
                    word.append(char)
                    inWord = true
                } else {
                    endSegment()
                }
            } else {
                word.append(char)
                inWord = true
            }
            index += 1
        }
        endSegment()
        return result
    }
}

private nonisolated extension RunningProgram {
    static let catalog: [String: RunningProgram] = {
        var table: [String: RunningProgram] = [:]
        func add(_ name: String, _ icon: String?, _ symbol: String, _ executables: [String]) {
            let program = RunningProgram(name: name, iconKey: icon, symbol: symbol)
            for executable in executables { table[executable] = program }
        }

        add("Claude", "claude", "sparkle", ["claude"])
        add("Codex", "codex", "sparkle", ["codex"])
        add("OpenAI", "openai", "sparkle", ["openai"])
        add("Cline", "cline", "sparkle", ["cline"])
        add("Kimi", "kimi", "sparkle", ["kimi"])
        add("Windsurf", "windsurf", "sparkle", ["windsurf"])
        add("Anaconda", "anaconda", "shippingbox", ["conda", "mamba"])
        add("Grok", "grok", "sparkle", ["grok"])
        add("Gemini", "gemini", "sparkle", ["gemini"])
        add("GitHub Copilot", "githubcopilot", "sparkle", ["copilot"])
        add("Cursor", "cursor", "sparkle", ["cursor-agent"])
        add("Ollama", "ollama", "sparkle", ["ollama"])
        add("Aider", nil, "sparkle", ["aider"])
        add("OpenCode", "opencode", "sparkle", ["opencode"])
        add("Amp", "amp", "sparkle", ["amp"])
        add("Goose", "goose", "sparkle", ["goose"])
        add("Qwen", "qwen", "sparkle", ["qwen"])
        add("Mistral Vibe", "mistral", "sparkle", ["vibe"])
        add("DeepSeek", "deepseek", "sparkle", ["deepseek"])
        add("Perplexity", "perplexity", "sparkle", ["perplexity"])
        add("Warp", "warp", "sparkle", ["warp"])

        add("Git", nil, "arrow.triangle.branch", ["git", "lazygit", "tig"])
        add("GitHub CLI", "github", "arrow.triangle.pull", ["gh"])
        add("GitLab CLI", "gitlab", "arrow.triangle.pull", ["glab"])

        add("npm", "npm", "shippingbox", ["npm"])
        add("pnpm", "pnpm", "shippingbox", ["pnpm"])
        add("Yarn", nil, "shippingbox", ["yarn"])
        add("Bun", "bun", "shippingbox", ["bun"])
        add("Node.js", "nodejs", "chevron.left.forwardslash.chevron.right", ["node"])
        add("Deno", "deno", "chevron.left.forwardslash.chevron.right", ["deno"])
        add("Python", "python", "chevron.left.forwardslash.chevron.right", ["python", "python3", "pip", "pip3", "ipython"])
        add("uv", "uv", "shippingbox", ["uv"])
        add("Poetry", "poetry", "shippingbox", ["poetry"])
        add("Rust", nil, "hammer", ["cargo", "rustc", "rustup"])
        add("Go", "go", "chevron.left.forwardslash.chevron.right", ["go"])
        add("Swift", "swift", "hammer", ["swift", "swiftc"])
        add("Xcode", "xcode", "hammer", ["xcodebuild", "xcrun"])

        add("Docker", "docker", "shippingbox", ["docker", "docker-compose", "colima"])
        add("Kubernetes", "kubernetes", "shippingbox", ["kubectl", "k9s", "minikube", "kind"])
        add("Helm", "helm", "shippingbox", ["helm"])
        add("Terraform", "terraform", "server.rack", ["terraform", "tofu"])

        add("Vim", "vim", "character.cursor.ibeam", ["vim", "vi"])
        add("Neovim", nil, "character.cursor.ibeam", ["nvim"])
        add("Emacs", nil, "character.cursor.ibeam", ["emacs"])

        add("Homebrew", "homebrew", "shippingbox", ["brew"])
        add("CMake", "cmake", "hammer", ["cmake"])
        add("Gradle", "gradle", "hammer", ["gradle", "gradlew"])
        add("Maven", "apachemaven", "hammer", ["mvn"])
        add("Java", "openjdk", "chevron.left.forwardslash.chevron.right", ["java"])
        add("Ruby", nil, "chevron.left.forwardslash.chevron.right", ["ruby", "irb", "gem", "bundle", "rake"])
        add("Rails", "rubyonrails", "chevron.left.forwardslash.chevron.right", ["rails"])
        add("PHP", nil, "chevron.left.forwardslash.chevron.right", ["php"])
        add("Composer", "composer", "shippingbox", ["composer"])
        add(".NET", "dotnet", "hammer", ["dotnet"])
        add("Flutter", "flutter", "hammer", ["flutter"])
        add("Dart", "dart", "chevron.left.forwardslash.chevron.right", ["dart"])
        add("PlatformIO", "platformio", "cpu", ["pio", "platformio"])

        add("Firebase", "firebase", "cloud", ["firebase"])
        add("Vercel", "vercel", "cloud", ["vercel"])
        add("Netlify", "netlify", "cloud", ["netlify"])
        add("Google Cloud", "googlecloud", "cloud", ["gcloud"])
        add("Supabase", "supabase", "cloud", ["supabase"])
        add("Cloudflare", "cloudflare", "cloud", ["wrangler"])
        add("Fly.io", "flydotio", "cloud", ["fly", "flyctl"])
        add("Heroku", nil, "cloud", ["heroku"])

        add("PostgreSQL", "postgresql", "cylinder", ["psql", "postgres"])
        add("MySQL", "mysql", "cylinder", ["mysql"])
        add("Redis", "redis", "cylinder", ["redis-cli", "redis-server"])
        add("SQLite", "sqlite", "cylinder", ["sqlite3"])
        add("MongoDB", "mongodb", "cylinder", ["mongosh", "mongod"])

        add("tmux", "tmux", "rectangle.split.2x1", ["tmux"])
        add("curl", "curl", "arrow.down.circle", ["curl"])
        add("FFmpeg", "ffmpeg", "film", ["ffmpeg"])
        add("TypeScript", "typescript", "chevron.left.forwardslash.chevron.right", ["tsc"])
        add("Vite", "vite", "bolt", ["vite"])
        add("Vitest", "vitest", "checkmark.seal", ["vitest"])
        add("Jest", "jest", "checkmark.seal", ["jest"])
        add("pytest", "pytest", "checkmark.seal", ["pytest"])
        add("Django", "django", "chevron.left.forwardslash.chevron.right", ["django-admin", "django"])
        add("Jupyter", "jupyter", "chart.xyaxis.line", ["jupyter"])
        add("Next.js", "nextdotjs", "bolt", ["next"])
        add("Lua", "lua", "chevron.left.forwardslash.chevron.right", ["lua"])
        add("Zig", nil, "hammer", ["zig"])
        add("Elixir", "elixir", "chevron.left.forwardslash.chevron.right", ["elixir", "iex", "mix"])
        add("Haskell", "haskell", "hammer", ["ghc", "ghci", "stack", "cabal"])
        add("Kotlin", "kotlin", "hammer", ["kotlin", "kotlinc"])
        add("Scala", "scala", "hammer", ["scala", "sbt"])
        add("LLVM", "llvm", "hammer", ["clang", "clang++", "lldb"])
        add("GNU", nil, "hammer", ["gcc", "g++", "make", "gdb"])
        add("Nix", nil, "shippingbox", ["nix", "nix-shell", "nix-build", "nixos-rebuild"])
        add("Just", "just", "hammer", ["just"])
        add("Task", "task", "checklist", ["task"])
        add("Godot", nil, "gamecontroller", ["godot"])
        add("Ansible", "ansible", "gearshape.2", ["ansible", "ansible-playbook"])

        add("SSH", nil, "network", ["ssh", "mosh", "sftp"])
        add("top", nil, "gauge.with.dots.needle.33percent", ["top", "htop", "btop"])
        add("less", nil, "book", ["less", "man", "more"])
        add("tail", nil, "text.alignleft", ["tail", "journalctl", "log"])
        add("ping", nil, "antenna.radiowaves.left.and.right", ["ping", "traceroute"])
        add("nano", nil, "pencil", ["nano"])
        add("sleep", nil, "moon.zzz", ["sleep"])
        add("watch", nil, "eye", ["watch"])
        return table
    }()
}
