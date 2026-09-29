import Foundation

nonisolated enum ActionCategory: String, Codable, CaseIterable, Sendable {
    case run
    case build
    case test
    case check
    case clean
    case deps
    case other

    var title: String {
        switch self {
        case .run: "Run"
        case .build: "Build"
        case .test: "Test"
        case .check: "Check"
        case .clean: "Clean"
        case .deps: "Dependencies"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .run: "play.fill"
        case .build: "hammer.fill"
        case .test: "checkmark.seal.fill"
        case .check: "checklist"
        case .clean: "trash"
        case .deps: "shippingbox"
        case .other: "terminal"
        }
    }
}

nonisolated struct ProjectAction: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var command: String
    var category: ActionCategory
    var ecosystem: String
    var symbol: String?
    var featured = false
    var root: String
    var environment: [String: String] = [:]

    var displaySymbol: String { symbol ?? category.symbol }
}

nonisolated struct ProjectVariant: Identifiable, Hashable, Sendable {
    struct Option: Hashable, Sendable {
        var label: String
        var value: String
    }

    let id: String
    var title: String
    var ecosystem: String
    var options: [Option]
    var defaultIndex = 0

    func option(at index: Int?) -> Option {
        let resolved = index.flatMap { options.indices.contains($0) ? $0 : nil } ?? defaultIndex
        return options[options.indices.contains(resolved) ? resolved : 0]
    }
}

nonisolated struct ProjectEcosystem: Identifiable, Hashable, Sendable {
    static let projectID = "project"

    let id: String
    var title: String
    var symbol: String

    static let symbols: [String: String] = [
        "cargo": "shippingbox", "swiftpm": "swift", "xcode": "hammer", "node": "curlybraces", "tauri": "macwindow",
        "deno": "curlybraces.square", "python": "chevron.left.forwardslash.chevron.right", "go": "arrow.right.circle",
        "cmake": "gearshape.2", "meson": "gearshape.2", "make": "gearshape", "gradle": "cube", "maven": "cube",
        "dotnet": "number.square", "zig": "bolt", "mix": "flame", "dart": "scope", "ruby": "diamond",
        "php": "server.rack", "nix": "snowflake", "just": "list.bullet.rectangle", "task": "list.bullet.rectangle",
        "docker": "shippingbox.fill", "terraform": "cloud", projectID: "folder",
    ]

    static func symbol(for id: String) -> String {
        symbols[id] ?? "terminal"
    }
}

nonisolated struct ProjectSnapshot: Equatable, Sendable {
    var ecosystems: [ProjectEcosystem] = []
    var bar = BarOverrides()
    var actions: [ProjectAction] = []
    var variants: [ProjectVariant] = []
    var notice: String?
    var manifestPath: String?

    static let empty = ProjectSnapshot()

    var isEmpty: Bool { actions.isEmpty && notice == nil }

    var featured: [ProjectAction] {
        actions.filter(\.featured)
    }

    func actions(in ecosystem: String) -> [ProjectAction] {
        actions.filter { $0.ecosystem == ecosystem }
    }

    func variants(in ecosystem: String) -> [ProjectVariant] {
        variants.filter { $0.ecosystem == ecosystem }
    }

    var roots: [String] {
        var seen: [String] = []
        for action in actions where !seen.contains(action.root) { seen.append(action.root) }
        return seen
    }

    func grouped() -> [(category: ActionCategory, actions: [ProjectAction])] {
        ActionCategory.allCases.compactMap { category in
            let members = actions.filter { $0.category == category }
            return members.isEmpty ? nil : (category, members)
        }
    }

    /// Builds the text typed into the shell: variant placeholders filled, environment prefixed, and a `cd` when the project lives above the shell's directory.
    func commandLine(for action: ProjectAction, selection: [String: Int], from directory: String) -> String {
        var text = action.command
        for variant in variants {
            let value = variant.option(at: selection[variant.id]).value
            text = text.replacingOccurrences(of: "{\(variant.id)}", with: value)
        }
        text = Self.collapseSpaces(text)
        if !action.environment.isEmpty {
            let pairs = action.environment.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(ShellQuoting.quote($0.value))" }
            text = "env \(pairs.joined(separator: " ")) \(text)"
        }
        if URL(fileURLWithPath: action.root).standardizedFileURL.path != URL(fileURLWithPath: directory).standardizedFileURL.path {
            text = "cd \(ShellQuoting.quote(action.root)) && \(text)"
        }
        return text
    }

    private static func collapseSpaces(_ text: String) -> String {
        var result = ""
        var quote: Character?
        var lastWasSpace = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                result.append(character)
                continue
            }
            if character == "'" || character == "\"" { quote = character }
            if character == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

nonisolated enum VariantStore {
    static let key = "turm.projectVariants"

    static func load(roots: [String], variants: [ProjectVariant], defaults: UserDefaults = .standard) -> [String: Int] {
        let stored = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        var selection: [String: Int] = [:]
        for variant in variants {
            for root in roots {
                if let index = stored[entry(root, variant.id)], variant.options.indices.contains(index) {
                    selection[variant.id] = index
                    break
                }
            }
        }
        return selection
    }

    static func save(index: Int, variant: String, roots: [String], defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        for root in roots { stored[entry(root, variant)] = index }
        defaults.set(stored, forKey: key)
    }

    private static func entry(_ root: String, _ variant: String) -> String {
        "\(root)\u{1F}\(variant)"
    }
}

/// Remembers which detected tool the bar shows, per project directory.
nonisolated enum ToolChoiceStore {
    static let key = "turm.projectTools"

    static func load(roots: [String], defaults: UserDefaults = .standard) -> String? {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return roots.lazy.compactMap { stored[$0] }.first
    }

    static func save(_ tool: String, roots: [String], defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        for root in roots { stored[root] = tool }
        defaults.set(stored, forKey: key)
    }
}

nonisolated enum ShellQuoting {
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func word(_ text: String) -> String {
        let plain = text.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || ("0"..."9").contains($0) || "-_./:@+=".unicodeScalars.contains($0) }
        return !text.isEmpty && plain ? text : quote(text)
    }
}
