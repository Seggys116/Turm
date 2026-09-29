import Foundation

nonisolated enum BarAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading
    case center
    case trailing

    var id: Self { self }

    var title: String {
        switch self {
        case .leading: "Left"
        case .center: "Centre"
        case .trailing: "Right"
        }
    }
}

nonisolated enum TitleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case always
    case never

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

nonisolated enum BarSection: String, CaseIterable, Identifiable, Sendable {
    case actions
    case options

    var id: Self { self }

    var title: String {
        switch self {
        case .actions: "Pinned actions"
        case .options: "Option toggles"
        }
    }
}

nonisolated struct EcosystemPreference: Codable, Equatable, Sendable {
    var enabled = true
    var items: [String]?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        items = try container.decodeIfPresent([String].self, forKey: .items)
    }

    private enum Key: String, CodingKey { case enabled, items }
}

nonisolated struct StatusBarPreferences: Codable, Equatable, RawRepresentable, Sendable {
    static let key = "turm.statusBar"

    var enabled = true
    var alignment = BarAlignment.leading
    var titles = TitleMode.auto
    var order: [BarSection] = BarSection.allCases
    var runInSubShell = true
    var ecosystems: [String: EcosystemPreference] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        alignment = try container.decodeIfPresent(BarAlignment.self, forKey: .alignment) ?? .leading
        titles = try container.decodeIfPresent(TitleMode.self, forKey: .titles) ?? .auto
        order = Self.normalized((try container.decodeIfPresent([String].self, forKey: .order) ?? []).compactMap(BarSection.init(rawValue:)))
        runInSubShell = try container.decodeIfPresent(Bool.self, forKey: .runInSubShell) ?? true
        ecosystems = try container.decodeIfPresent([String: EcosystemPreference].self, forKey: .ecosystems) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(alignment, forKey: .alignment)
        try container.encode(titles, forKey: .titles)
        try container.encode(order.map(\.rawValue), forKey: .order)
        try container.encode(runInSubShell, forKey: .runInSubShell)
        try container.encode(ecosystems, forKey: .ecosystems)
    }

    private enum Key: String, CodingKey {
        case enabled, alignment, titles, order, runInSubShell, ecosystems
    }

    static func normalized(_ order: [BarSection]) -> [BarSection] {
        var result: [BarSection] = []
        for section in order where !result.contains(section) { result.append(section) }
        for section in BarSection.allCases where !result.contains(section) { result.append(section) }
        return result
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static var current: StatusBarPreferences {
        UserDefaults.standard.string(forKey: key).flatMap(StatusBarPreferences.init(rawValue:)) ?? StatusBarPreferences()
    }

    static func update(_ change: (inout StatusBarPreferences) -> Void, defaults: UserDefaults = .standard) {
        var value = defaults.string(forKey: key).flatMap(StatusBarPreferences.init(rawValue:)) ?? StatusBarPreferences()
        change(&value)
        defaults.set(value.rawValue, forKey: key)
    }

    func preference(for ecosystem: String) -> EcosystemPreference {
        ecosystems[ecosystem] ?? EcosystemPreference()
    }

    func items(for ecosystem: String, defaults: [String]) -> [String] {
        preference(for: ecosystem).items ?? defaults
    }

    mutating func setItems(_ items: [String], for ecosystem: String) {
        var entry = preference(for: ecosystem)
        entry.items = items
        ecosystems[ecosystem] = entry
    }
}

nonisolated struct BarOverrides: Equatable, Sendable {
    struct Ecosystem: Equatable, Sendable {
        var title: String?
        var symbol: String?
        var hidden = false
    }

    var pinned: [String]?
    var icons: [String: String] = [:]
    var ecosystems: [String: Ecosystem] = [:]
    var titles: TitleMode?
    var alignment: BarAlignment?
    var order: [BarSection]?
    var subShell: Bool?
}

nonisolated struct ResolvedBar: Equatable, Sendable {
    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        var title: String
        var symbol: String
        var actions: [ProjectAction]
        var variants: [ProjectVariant]
        var pinned: [ProjectAction]
        var shownVariants: [ProjectVariant]
    }

    var groups: [Group] = []
    var icons: [String: String] = [:]
    var titles = TitleMode.auto
    var alignment = BarAlignment.leading
    var order = BarSection.allCases
    var subShell = true
    var usesManifest = false
    var manifestPinned: [ProjectAction]?

    struct Display: Equatable, Sendable {
        var selector: [Group] = []
        var active: Group?
        var pinned: [ProjectAction] = []
        var variants: [ProjectVariant] = []
    }

    func display(choice: String?) -> Display {
        var display = Display()
        if !usesManifest, tools.count > 1 {
            display.selector = tools
            let active = activeTool(choice: choice)
            display.active = active
            let shown = [projectGroup, active].compactMap { $0 }
            display.pinned = shown.flatMap(\.pinned)
            display.variants = shown.flatMap(\.shownVariants)
            return display
        }
        display.pinned = manifestPinned ?? groups.flatMap(\.pinned)
        display.variants = groups.flatMap(\.shownVariants)
        return display
    }

    var tools: [Group] { groups.filter { $0.id != ProjectEcosystem.projectID } }
    var projectGroup: Group? { groups.first { $0.id == ProjectEcosystem.projectID } }

    func symbol(for action: ProjectAction) -> String {
        icons[action.id] ?? action.displaySymbol
    }

    func activeTool(choice: String?) -> Group? {
        tools.first { $0.id == choice } ?? tools.first
    }

    var isVisible: Bool { !groups.isEmpty }

    static func resolve(_ snapshot: ProjectSnapshot, preferences: StatusBarPreferences) -> ResolvedBar {
        let overrides = snapshot.bar
        var bar = ResolvedBar()
        bar.icons = overrides.icons
        bar.titles = overrides.titles ?? preferences.titles
        bar.alignment = overrides.alignment ?? preferences.alignment
        bar.order = StatusBarPreferences.normalized(overrides.order ?? preferences.order)
        bar.subShell = overrides.subShell ?? preferences.runInSubShell
        bar.usesManifest = snapshot.manifestPath != nil

        for ecosystem in snapshot.ecosystems {
            let preference = preferences.preference(for: ecosystem.id)
            let override = overrides.ecosystems[ecosystem.id]
            guard preference.enabled, override?.hidden != true else { continue }

            let actions = snapshot.actions(in: ecosystem.id)
            let variants = snapshot.variants(in: ecosystem.id)
            let defaults = actions.filter(\.featured).map(\.id) + variants.map(\.id)
            let wanted = preference.items ?? defaults

            var pinned = wanted.compactMap { id in actions.first { $0.id == id } }
            if let ids = overrides.pinned {
                pinned = ids.compactMap { id in actions.first { $0.id == id } }
            }
            let shown = wanted.compactMap { id in variants.first { $0.id == id } }
            bar.groups.append(Group(
                id: ecosystem.id, title: override?.title ?? ecosystem.title,
                symbol: override?.symbol ?? ecosystem.symbol, actions: actions, variants: variants,
                pinned: pinned, shownVariants: shown
            ))
        }
        if let ids = overrides.pinned {
            let available = bar.groups.flatMap(\.actions)
            bar.manifestPinned = ids.compactMap { id in available.first { $0.id == id } }
        }
        return bar
    }
}

nonisolated enum EcosystemCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        var title: String
        var symbol: String
        var actions: [ProjectAction]
        var variants: [ProjectVariant]
        var defaultItems: [String] { actions.filter(\.featured).map(\.id) + variants.map(\.id) }
    }

    private static let samples: [(id: String, title: String, files: [String: String])] = [
        ("cargo", "Cargo", ["Cargo.toml": "[package]\nname = \"sample\"", "src/main.rs": "", "benches/b.rs": ""]),
        ("swiftpm", "Swift Package", ["Package.swift": ".executableTarget"]),
        ("xcode", "Xcode", ["Sample.xcodeproj": ""]),
        ("node", "Node", ["package.json": #"{"scripts":{"dev":"x","build":"x","test":"x","clean":"x","lint":"x","format":"x","preview":"x"}}"#, "tsconfig.json": "{}"]),
        ("tauri", "Tauri", ["src-tauri/tauri.conf.json": "{}", "src-tauri/Cargo.toml": ""]),
        ("deno", "Deno", ["deno.json": #"{"tasks":{"dev":"x"}}"#]),
        ("python", "Python", ["pyproject.toml": "[tool.uv]\n[tool.pytest]\n[tool.ruff]\n[tool.mypy]\n[build-system]", "uv.lock": "", "main.py": ""]),
        ("go", "Go", ["go.mod": "module sample", "main.go": ""]),
        ("cmake", "CMake", ["CMakeLists.txt": "project(sample)", "CMakePresets.json": "{}"]),
        ("meson", "Meson", ["meson.build": ""]),
        ("make", "Make", ["Makefile": "all:\nrun:\ntest:\nclean:\ninstall:\n"]),
        ("gradle", "Gradle", ["build.gradle": "application"]),
        ("maven", "Maven", ["pom.xml": "spring-boot-maven-plugin"]),
        ("dotnet", ".NET", ["Sample.csproj": "", "Sample.sln": ""]),
        ("zig", "Zig", ["build.zig": ""]),
        ("mix", "Elixir", ["mix.exs": ":phoenix"]),
        ("dart", "Dart", ["pubspec.yaml": "flutter:"]),
        ("ruby", "Ruby", ["Gemfile": "rubocop", "config/application.rb": "", ".rspec": "", "Rakefile": ""]),
        ("php", "PHP", ["composer.json": "{}", "artisan": ""]),
        ("nix", "Nix", ["flake.nix": ""]),
        ("just", "Just", ["justfile": "build:\ntest:\nrun:\n"]),
        ("task", "Task", ["Taskfile.yml": "tasks:\n  build:\n  test:\n  run:\n"]),
        ("docker", "Docker", ["compose.yaml": "", "Dockerfile": ""]),
        ("terraform", "Terraform", ["main.tf": ""]),
    ]

    static let entries: [Entry] = samples.compactMap { sample in
        let probe = ProjectProbe(files: sample.files)
        guard let detection = ProjectDetection.detectors.lazy.compactMap({ $0(probe) }).first(where: { $0.id == sample.id })
        else { return nil }
        return Entry(
            id: sample.id, title: sample.title, symbol: ProjectEcosystem.symbol(for: sample.id),
            actions: detection.actions, variants: detection.variants
        )
    }

    static func entry(_ id: String) -> Entry? {
        entries.first { $0.id == id }
    }
}
