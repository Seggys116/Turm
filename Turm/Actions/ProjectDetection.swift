import Foundation
import TurmCore

nonisolated struct ProjectManifest: Decodable {
    static let fileName = "Turm.json"
    static let maxBytes = 262_144

    static func resolvedFile(in directory: String) -> String? {
        guard let name = entryName(in: directory) else { return nil }
        let path = (directory as NSString).appendingPathComponent(name)
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= maxBytes else { return nil }
        return resolved
    }

    static func entryName(in directory: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        let matches = entries.filter { $0.caseInsensitiveCompare(fileName) == .orderedSame }
        return matches.contains(fileName) ? fileName : matches.sorted().first
    }

    static let template = """
        {
          "inherit": true,
          "variants": [
            { "id": "target", "title": "Target", "options": [{ "label": "Debug", "value": "debug" }, { "label": "Release", "value": "release" }] }
          ],
          "actions": [
            { "id": "hello", "title": "Hello", "command": "echo building {target}", "icon": "hand.wave", "category": "other" }
          ]
        }

        """

    struct Action: Decodable {
        var id: String?
        var title: String
        var command: String
        var icon: String?
        var category: String?
        var featured: Bool?
        var env: [String: String]?
    }

    struct Variant: Decodable {
        struct Option: Decodable {
            var label: String
            var value: String

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer().decode(String.self) {
                    label = single
                    value = single
                    return
                }
                let container = try decoder.container(keyedBy: Key.self)
                label = try container.decode(String.self, forKey: .label)
                value = try container.decodeIfPresent(String.self, forKey: .value) ?? label
            }

            private enum Key: String, CodingKey { case label, value }
        }

        var id: String
        var title: String?
        var options: [Option]
        var defaultOption: Int?
    }

    struct Bar: Decodable {
        struct Ecosystem: Decodable {
            var title: String?
            var icon: String?
            var hidden: Bool?
        }

        var pinned: [String]?
        var icons: [String: String]?
        var ecosystems: [String: Ecosystem]?
        var titles: String?
        var alignment: String?
        var subShell: Bool?

        var overrides: BarOverrides {
            var result = BarOverrides()
            result.pinned = pinned
            result.icons = icons ?? [:]
            result.ecosystems = (ecosystems ?? [:]).mapValues {
                BarOverrides.Ecosystem(title: $0.title, symbol: $0.icon, hidden: $0.hidden ?? false)
            }
            result.titles = titles.flatMap { TitleMode(rawValue: $0.lowercased()) }
            result.alignment = alignment.flatMap { BarAlignment(rawValue: $0.lowercased()) }
            result.subShell = subShell
            return result
        }
    }

    var inherit: Bool?
    var hide: [String]?
    var variants: [Variant]?
    var actions: [Action]?
    var bar: Bar?
    var shortcuts: [String: String]?

    static func decode(_ data: Data) throws -> ProjectManifest {
        try JSONDecoder().decode(ProjectManifest.self, from: data)
    }
}

nonisolated enum ProjectDetection {
    static let detectors: [(ProjectProbe) -> Detection?] = [
        BuildSystemDetectors.cargo,
        BuildSystemDetectors.swiftPackage,
        BuildSystemDetectors.xcode,
        ScriptDetectors.node,
        ScriptDetectors.tauri,
        ScriptDetectors.deno,
        ScriptDetectors.python,
        BuildSystemDetectors.go,
        BuildSystemDetectors.cmake,
        BuildSystemDetectors.meson,
        BuildSystemDetectors.make,
        BuildSystemDetectors.gradle,
        BuildSystemDetectors.maven,
        BuildSystemDetectors.dotnet,
        BuildSystemDetectors.zig,
        BuildSystemDetectors.elixir,
        BuildSystemDetectors.dart,
        ScriptDetectors.ruby,
        ScriptDetectors.php,
        BuildSystemDetectors.nix,
        ScriptDetectors.just,
        ScriptDetectors.taskfile,
        ScriptDetectors.docker,
        ScriptDetectors.terraform,
    ]

    private static let maxDepth = 10

    static func candidates(from directory: String, home: String) -> [String] {
        let start = URL(fileURLWithPath: directory).standardizedFileURL.path
        let home = URL(fileURLWithPath: home).standardizedFileURL.path
        var result = [start]
        guard start != home, start != "/" else { return result }
        var current = start
        while result.count < maxDepth {
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current || parent == "/" || parent == home { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    @concurrent
    static func detect(in directory: String) async -> ProjectSnapshot {
        snapshot(for: directory)
    }

    static func snapshot(for directory: String, home: String = NSHomeDirectory()) -> ProjectSnapshot {
        snapshot(
            places: candidates(from: directory, home: home),
            probe: { ProjectProbe(directory: $0) },
            manifest: { place in
                guard let file = ProjectManifest.resolvedFile(in: place) else { return nil }
                return (file, FileManager.default.contents(atPath: file))
            }
        )
    }

    static func snapshot(
        places: [String],
        probe makeProbe: (String) -> ProjectProbe,
        manifest findManifest: (String) -> (path: String, data: Data?)?
    ) -> ProjectSnapshot {
        var snapshot = ProjectSnapshot()

        var detections: [Detection] = []
        for place in places {
            let probe = makeProbe(place)
            guard !probe.isEmpty else { continue }
            detections = detectors.compactMap { $0(probe) }
            if !detections.isEmpty { break }
        }

        var manifestRoot: String?
        var manifestFile: (path: String, data: Data?)?
        for place in places {
            if let file = findManifest(place) {
                manifestRoot = place
                manifestFile = file
                break
            }
        }

        var manifest: ProjectManifest?
        if manifestRoot != nil, let file = manifestFile {
            snapshot.manifestPath = file.path
            do {
                guard let data = file.data else { throw CocoaError(.fileReadNoPermission) }
                manifest = try ProjectManifest.decode(data)
            } catch {
                snapshot.notice = "Turm.json: \(describe(error))"
            }
        }

        if manifest?.inherit != false {
            for detection in detections {
                snapshot.ecosystems.append(ProjectEcosystem(
                    id: detection.id, title: detection.kind, symbol: ProjectEcosystem.symbol(for: detection.id)
                ))
                snapshot.actions.append(contentsOf: detection.actions)
                snapshot.variants.append(contentsOf: detection.variants)
            }
        }
        if let manifest, let manifestRoot {
            apply(manifest, root: manifestRoot, to: &snapshot)
        }
        return snapshot
    }

    private static func apply(_ manifest: ProjectManifest, root: String, to snapshot: inout ProjectSnapshot) {
        if let hidden = manifest.hide, !hidden.isEmpty {
            let hiddenSet = Set(hidden)
            snapshot.actions.removeAll { hiddenSet.contains($0.id) }
        }
        for variant in manifest.variants ?? [] {
            let options = variant.options.filter { !$0.label.isEmpty }.map { ProjectVariant.Option(label: $0.label, value: $0.value) }
            guard !variant.id.isEmpty, !options.isEmpty else { continue }
            let resolved = ProjectVariant(
                id: variant.id, title: variant.title ?? variant.id, ecosystem: ProjectEcosystem.projectID, options: options,
                defaultIndex: min(max(variant.defaultOption ?? 0, 0), options.count - 1)
            )
            snapshot.variants.removeAll { $0.id == resolved.id }
            snapshot.variants.append(resolved)
        }
        var custom: [ProjectAction] = []
        for (index, spec) in (manifest.actions ?? []).enumerated() {
            let title = spec.title.trimmingCharacters(in: .whitespaces)
            let command = spec.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !command.isEmpty else { continue }
            let category = spec.category.flatMap { ActionCategory(rawValue: $0.lowercased()) } ?? .other
            var action = ProjectAction(
                id: spec.id ?? "turm.\(index)", title: title, command: command, category: category,
                ecosystem: ProjectEcosystem.projectID, symbol: spec.icon, featured: spec.featured ?? true, root: root, environment: spec.env ?? [:]
            )
            if let existing = snapshot.actions.firstIndex(where: { $0.id == action.id }) {
                action.ecosystem = snapshot.actions[existing].ecosystem
                action.featured = spec.featured ?? snapshot.actions[existing].featured
                snapshot.actions[existing] = action
            } else {
                custom.append(action)
            }
        }
        snapshot.actions.insert(contentsOf: custom, at: 0)
        if !custom.isEmpty || snapshot.variants.contains(where: { $0.ecosystem == ProjectEcosystem.projectID }) {
            snapshot.ecosystems.insert(ProjectEcosystem(
                id: ProjectEcosystem.projectID, title: "Project", symbol: ProjectEcosystem.symbol(for: ProjectEcosystem.projectID)
            ), at: 0)
        }
        snapshot.bar = manifest.bar?.overrides ?? BarOverrides()
        let shortcuts = Shortcuts.project(manifest.shortcuts ?? [:], root: root)
        snapshot.shortcuts = shortcuts.shortcuts
        if !shortcuts.invalid.isEmpty {
            snapshot.notice = "Turm.json: invalid shortcut \(shortcuts.invalid.joined(separator: ", "))"
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "could not be read" }
        switch decoding {
        case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "invalid JSON" : "invalid value at \(path)"
        @unknown default: return "invalid"
        }
    }
}
