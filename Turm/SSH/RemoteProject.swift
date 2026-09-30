import Foundation

nonisolated struct RemoteDirectory: Equatable {
    struct Entry: Equatable {
        var name: String
        var isDirectory: Bool
    }

    var path: String
    var entries: [Entry] = []
    var existing: Set<String> = []
    var files: [String: String] = [:]
    var manifest: (name: String, content: String)?

    static func == (lhs: RemoteDirectory, rhs: RemoteDirectory) -> Bool {
        lhs.path == rhs.path && lhs.entries == rhs.entries && lhs.existing == rhs.existing && lhs.files == rhs.files
            && lhs.manifest?.name == rhs.manifest?.name && lhs.manifest?.content == rhs.manifest?.content
    }

    static func parse(_ output: String) -> [RemoteDirectory] {
        var result: [RemoteDirectory] = []
        for line in output.split(separator: "\n") {
            guard line.count > 2, line[line.index(line.startIndex, offsetBy: 1)] == " " else { continue }
            let body = line.dropFirst(2)
            if line.first == "D" {
                result.append(RemoteDirectory(path: String(body)))
                continue
            }
            guard !result.isEmpty else { continue }
            switch line.first {
            case "E":
                guard body.count > 2, body.first == "d" || body.first == "f" else { continue }
                result[result.count - 1].entries.append(Entry(name: String(body.dropFirst(2)), isDirectory: body.first == "d"))
            case "X":
                result[result.count - 1].existing.insert(String(body))
            case "F", "M":
                let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = parts.first, !name.isEmpty else { continue }
                let encoded = parts.count > 1 ? String(parts[1]) : ""
                guard let data = Data(base64Encoded: encoded) else { continue }
                let content = String(decoding: data, as: UTF8.self)
                if line.first == "F" {
                    result[result.count - 1].files[String(name)] = content
                } else {
                    result[result.count - 1].manifest = (String(name), content)
                }
            default:
                continue
            }
        }
        return result
    }
}

nonisolated extension RemoteChannel {
    static let projectNestedPaths = [
        "src-tauri/tauri.conf.json", "src-tauri/tauri.conf.json5", "src-tauri/Tauri.toml", "src-tauri/Cargo.toml",
        "src/main.rs", "src/bin", "bin/rails", "config/application.rb", "tests/conftest.py",
    ]

    static let projectReadFiles = [
        "Cargo.toml", "Package.swift", "GNUmakefile", "Makefile", "makefile",
        "build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle", "pom.xml",
        "mix.exs", "pubspec.yaml", "package.json", "deno.json", "composer.json",
        "pyproject.toml", "requirements.txt", "tox.ini", "setup.cfg", "Gemfile",
        "justfile", "Justfile", ".justfile", "Taskfile.yml", "Taskfile.yaml", "taskfile.yml", "taskfile.yaml",
    ]

    private static let projectFunctions = """
        emit() { if [ "$(wc -c < "$2" | tr -d ' ')" -le \(ProjectManifest.maxBytes) ]; then printf '%s %s ' "$1" "$2"; base64 < "$2" | tr -d '\\n'; printf '\\n'; fi; }
        """

    private static let projectBody = """
        for n in .[!.]* ..?* *; do
          if [ -e "$n" ] || [ -L "$n" ]; then
            if [ -d "$n" ]; then printf 'E d %s\\n' "$n"; else printf 'E f %s\\n' "$n"; fi
          fi
        done
        for p in \(projectNestedPaths.map(RemoteChannel.quote).joined(separator: " ")); do
          if [ -e "$p" ]; then printf 'X %s\\n' "$p"; fi
        done
        for f in \(projectReadFiles.map(RemoteChannel.quote).joined(separator: " ")); do
          if [ -f "$f" ]; then emit F "$f"; fi
        done
        for f in \(RemoteChannel.quote(ProjectManifest.fileName)) [Tt][Uu][Rr][Mm].[Jj][Ss][Oo][Nn]; do
          if [ -f "$f" ]; then emit M "$f"; break; fi
        done
        """

    static func projectScript(for places: [String]) -> String {
        let sections = places.map { place in
            "( cd \(quote(place)) 2>/dev/null || exit 0\nprintf 'D %s\\n' \(quote(place))\n\(projectBody)\n)"
        }
        return ([projectFunctions] + sections).joined(separator: "\n") + "\n"
    }

    @concurrent
    func project(in directory: String) async -> ProjectSnapshot {
        let places = ProjectDetection.candidates(from: directory, home: home ?? "/")
        guard let result = run(Self.projectScript(for: places), timeout: 6), result.status == 0 else { return ProjectSnapshot() }
        let found = Dictionary(RemoteDirectory.parse(result.output).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return ProjectDetection.snapshot(
            places: places,
            probe: { place in ProjectProbe(directory: place, remote: found[place] ?? RemoteDirectory(path: place)) },
            manifest: { place in
                guard let manifest = found[place]?.manifest else { return nil }
                return ((place as NSString).appendingPathComponent(manifest.name), Data(manifest.content.utf8))
            }
        )
    }
}
