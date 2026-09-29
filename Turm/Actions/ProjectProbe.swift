import Foundation

/// Read-only view of one directory that detectors ask questions of.
nonisolated struct ProjectProbe {
    let directory: String
    private let entries: Set<String>

    init(directory: String) {
        self.directory = directory
        entries = Set((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
    }

    var isEmpty: Bool { entries.isEmpty }

    func has(_ path: String) -> Bool {
        if path.contains("/") {
            return FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(path))
        }
        return entries.contains(path)
    }

    func first(of names: [String]) -> String? {
        names.first(where: has)
    }

    func files(withExtension ext: String) -> [String] {
        entries.filter { $0.hasSuffix(".\(ext)") && !$0.hasPrefix(".") }.sorted()
    }

    func text(_ path: String, limit: Int = 262_144) -> String? {
        let full = (directory as NSString).appendingPathComponent(path)
        guard let handle = FileHandle(forReadingAtPath: full) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func json(_ path: String) -> [String: Any]? {
        guard let text = text(path, limit: 2_097_152), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var folderName: String {
        (directory as NSString).lastPathComponent
    }
}

nonisolated struct Detection {
    var kind: String
    var actions: [ProjectAction]
    var variants: [ProjectVariant]
}

nonisolated struct DetectionBuilder {
    let root: String
    let prefix: String
    private(set) var actions: [ProjectAction] = []
    private(set) var variants: [ProjectVariant] = []

    init(probe: ProjectProbe, prefix: String) {
        root = probe.directory
        self.prefix = prefix
    }

    mutating func add(
        _ id: String, _ title: String, _ command: String, _ category: ActionCategory,
        symbol: String? = nil, featured: Bool = false
    ) {
        let full = "\(prefix).\(id)"
        guard !actions.contains(where: { $0.id == full }) else { return }
        actions.append(ProjectAction(
            id: full, title: title, command: command, category: category,
            symbol: symbol, featured: featured, root: root
        ))
    }

    mutating func variant(_ id: String, title: String, _ options: [(label: String, value: String)], defaultIndex: Int = 0) {
        variants.append(ProjectVariant(
            id: id, title: title,
            options: options.map { ProjectVariant.Option(label: $0.label, value: $0.value) },
            defaultIndex: defaultIndex
        ))
    }

    func finish(kind: String) -> Detection? {
        actions.isEmpty ? nil : Detection(kind: kind, actions: actions, variants: variants)
    }
}

nonisolated enum ActionClassifier {
    private static let words: [ActionCategory: Set<String>] = [
        .test: ["test", "tests", "spec", "specs", "e2e", "unit", "integration", "coverage", "bench", "benchmark"],
        .build: ["build", "compile", "bundle", "package", "dist", "release", "all", "assemble", "generate", "codegen"],
        .run: ["dev", "start", "serve", "run", "watch", "preview", "up", "demo", "storybook"],
        .clean: ["clean", "distclean", "clobber", "purge"],
        .check: ["lint", "format", "fmt", "typecheck", "tsc", "check", "verify", "analyze", "prettier", "eslint", "vet", "types"],
        .deps: ["install", "deps", "setup", "bootstrap", "update", "upgrade", "init", "prepare"],
    ]

    static func category(forName name: String) -> ActionCategory {
        let lead = name.lowercased()
            .split(whereSeparator: { ":_-./ ".contains($0) })
            .first.map(String.init) ?? name.lowercased()
        for (category, members) in words where members.contains(lead) { return category }
        return .other
    }

    static func symbol(forName name: String) -> String? {
        switch name.lowercased() {
        case "dev", "serve": "bolt.fill"
        case "start": "play.fill"
        case "preview": "eye"
        case "lint": "checklist"
        case "format", "fmt", "prettier": "text.alignleft"
        case "install", "deps": "arrow.down.circle"
        case "docs", "doc": "book"
        case "deploy": "paperplane"
        default: nil
        }
    }
}

nonisolated struct LinePattern: Sendable {
    private nonisolated(unsafe) let expression: NSRegularExpression

    init(_ pattern: String) {
        expression = try! NSRegularExpression(pattern: pattern)
    }

    func capture(in line: Substring) -> String? {
        let text = String(line)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captured])
    }
}
