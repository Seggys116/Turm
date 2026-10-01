import Foundation
import TurmCore

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
        var symbol: String?
        var detail: String?
        /// Names the groups this option belongs to, matched against the tags of the option picked in the `filter` variant.
        var tags: [String] = []
    }

    let id: String
    var title: String
    var ecosystem: String
    var options: [Option]
    var defaultIndex = 0
    var filter: String?

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

    static let fallbackSymbols: [String: String] = [
        "cargo": "shippingbox", "swiftpm": "swift", "xcode": "hammer", "node": "curlybraces", "tauri": "macwindow",
        "deno": "curlybraces.square", "python": "chevron.left.forwardslash.chevron.right", "go": "arrow.right.circle",
        "platformio": "cpu", "cmake": "gearshape.2", "meson": "gearshape.2", "make": "gearshape", "gradle": "cube", "maven": "cube",
        "dotnet": "number.square", "zig": "bolt", "mix": "flame", "dart": "scope", "ruby": "diamond",
        "php": "server.rack", "nix": "snowflake", "just": "list.bullet.rectangle", "task": "list.bullet.rectangle",
        "docker": "shippingbox.fill", "terraform": "cloud", projectID: "folder",
    ]

    private static let brandKeys: [String: String] = [
        "swiftpm": "swift", "xcode": "xcode", "node": "nodejs", "deno": "deno", "python": "python",
        "go": "go", "platformio": "platformio", "cmake": "cmake", "gradle": "gradle", "maven": "apachemaven",
        "dotnet": "dotnet", "mix": "elixir", "dart": "dart",
        "just": "just", "task": "task", "docker": "docker", "terraform": "terraform",
    ]

    static let symbols: [String: String] = fallbackSymbols.merging(brandKeys.mapValues { "brand:" + $0 }) { _, brand in brand }

    static func symbol(for id: String) -> String {
        symbols[id] ?? "terminal"
    }

    static func fallback(forSymbol symbol: String) -> String {
        guard symbol.hasPrefix("brand:") else { return symbol }
        let id = symbols.first { $0.value == symbol }?.key
        return id.flatMap { fallbackSymbols[$0] } ?? "terminal"
    }
}

nonisolated struct ProjectSnapshot: Equatable, Sendable {
    var ecosystems: [ProjectEcosystem] = []
    var bar = BarOverrides()
    var actions: [ProjectAction] = []
    var variants: [ProjectVariant] = []
    var notice: String?
    var manifestPath: String?
    var shortcuts: [Shortcut] = []

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

    func visibleOptions(of variant: ProjectVariant, selection: [String: Int]) -> [(index: Int, option: ProjectVariant.Option)] {
        let all = variant.options.enumerated().map { (index: $0.offset, option: $0.element) }
        guard let parent = variants.first(where: { $0.id == variant.filter }) else { return all }
        let tags = Set(selectedOption(of: parent, selection: selection).option.tags)
        guard !tags.isEmpty else { return all }
        let kept = all.filter { $0.option.tags.isEmpty || !tags.isDisjoint(with: $0.option.tags) }
        return kept.isEmpty ? all : kept
    }

    func selectedOption(of variant: ProjectVariant, selection: [String: Int]) -> (index: Int, option: ProjectVariant.Option) {
        let visible = visibleOptions(of: variant, selection: selection)
        if let hit = visible.first(where: { $0.index == selection[variant.id] }) { return hit }
        if let hit = visible.first(where: { $0.index == variant.defaultIndex }) { return hit }
        return visible.first ?? (index: 0, option: variant.option(at: nil))
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

    func commandLine(for action: ProjectAction, selection: [String: Int], from directory: String) -> String {
        var text = action.command
        for variant in variants {
            let value = selectedOption(of: variant, selection: selection).option.value
            text = text.replacingOccurrences(of: "{\(variant.id)}", with: value)
        }
        text = Self.collapseSpaces(text)
        let environment = action.environment.filter { $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
        if !environment.isEmpty {
            let pairs = environment.sorted { $0.key < $1.key }
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

    static let valueKey = "turm.projectVariantValues"

    /// A remembered value wins over the index so lists that change (schemes, devices) keep the same choice.
    static func load(roots: [String], variants: [ProjectVariant], defaults: UserDefaults = .standard) -> [String: Int] {
        let stored = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        let values = defaults.dictionary(forKey: valueKey) as? [String: String] ?? [:]
        var selection: [String: Int] = [:]
        for variant in variants {
            for root in roots {
                let name = entry(root, variant.id)
                if let value = values[name] {
                    guard let index = variant.options.firstIndex(where: { $0.value == value }) else { continue }
                    selection[variant.id] = index
                    break
                }
                if let index = stored[name], variant.options.indices.contains(index) {
                    selection[variant.id] = index
                    break
                }
            }
        }
        return selection
    }

    static func save(index: Int, variant: String, roots: [String], value: String? = nil, defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        var values = defaults.dictionary(forKey: valueKey) as? [String: String] ?? [:]
        for root in roots {
            stored[entry(root, variant)] = index
            values[entry(root, variant)] = value
        }
        defaults.set(stored, forKey: key)
        defaults.set(values, forKey: valueKey)
    }

    private static func entry(_ root: String, _ variant: String) -> String {
        "\(root)\u{1F}\(variant)"
    }
}

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
