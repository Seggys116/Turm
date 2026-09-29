import Foundation

/// Turm.json: repository-level settings for the status bar.
nonisolated struct ProjectManifest: Decodable {
    static let fileName = "Turm.json"

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

    var inherit: Bool?
    var hide: [String]?
    var variants: [Variant]?
    var actions: [Action]?

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

    /// The directory itself, then its ancestors, never reaching the home folder or the filesystem root unless the shell is already there.
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
        let places = candidates(from: directory, home: home)
        var snapshot = ProjectSnapshot()

        var detections: [Detection] = []
        for place in places {
            let probe = ProjectProbe(directory: place)
            guard !probe.isEmpty else { continue }
            detections = detectors.compactMap { $0(probe) }
            if !detections.isEmpty { break }
        }

        var manifestRoot: String?
        for place in places where FileManager.default.fileExists(atPath: (place as NSString).appendingPathComponent(ProjectManifest.fileName)) {
            manifestRoot = place
            break
        }

        var manifest: ProjectManifest?
        if let manifestRoot {
            let path = (manifestRoot as NSString).appendingPathComponent(ProjectManifest.fileName)
            snapshot.manifestPath = path
            do {
                guard let data = FileManager.default.contents(atPath: path) else { throw CocoaError(.fileReadNoPermission) }
                manifest = try ProjectManifest.decode(data)
            } catch {
                snapshot.notice = "Turm.json: \(describe(error))"
            }
        }

        if manifest?.inherit != false {
            for detection in detections {
                snapshot.kinds.append(detection.kind)
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
                id: variant.id, title: variant.title ?? variant.id, options: options,
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
            let action = ProjectAction(
                id: spec.id ?? "turm.\(index)", title: title, command: command, category: category,
                symbol: spec.icon, featured: spec.featured ?? true, root: root, environment: spec.env ?? [:]
            )
            if let existing = snapshot.actions.firstIndex(where: { $0.id == action.id }) {
                snapshot.actions[existing] = action
            } else {
                custom.append(action)
            }
        }
        snapshot.actions.insert(contentsOf: custom, at: 0)
        if !custom.isEmpty { snapshot.kinds.insert(ProjectManifest.fileName, at: 0) }
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
