import Foundation

nonisolated struct GitStatus: Equatable {
    var branch: String
    var files: Int
    var added: Int
    var removed: Int
}

nonisolated enum GitInspector {
    static func parseNumstat(_ text: String) -> (files: Int, added: Int, removed: Int) {
        var files = 0
        var added = 0
        var removed = 0
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            files += 1
            added += Int(columns[0]) ?? 0
            removed += Int(columns[1]) ?? 0
        }
        return (files, added, removed)
    }

    @concurrent
    static func status(in directory: String) async -> GitStatus? {
        guard let branch = run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory)
            ?? run(["rev-parse", "--short", "HEAD"], in: directory)
        else { return nil }
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let totals = parseNumstat(run(["diff", "HEAD", "--numstat"], in: directory) ?? "")
        return GitStatus(branch: name, files: totals.files, added: totals.added, removed: totals.removed)
    }

    @concurrent
    static func branches(in directory: String) async -> [String] {
        let text = run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], in: directory) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    @concurrent
    static func switchBranch(to name: String, in directory: String) async -> String? {
        var failure = ""
        guard run(["switch", name], in: directory, errors: &failure) != nil else {
            let message = failure.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Could not switch to \(name)" : message
        }
        return nil
    }

    private static func trustedArguments(_ arguments: [String], in directory: String) -> [String] {
        guard ignoresOwnership(directory), let root = repositoryRoot(from: directory) else { return [] }
        return ["-c", "safe.directory=" + root]
    }

    private static func ignoresOwnership(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
    }

    private static func repositoryRoot(from directory: String) -> String? {
        var url = URL(fileURLWithPath: directory)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func run(_ arguments: [String], in directory: String) -> String? {
        var ignored = ""
        return run(arguments, in: directory, errors: &ignored)
    }

    private static func run(_ arguments: [String], in directory: String, errors: inout String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = trustedArguments(arguments, in: directory) + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = SpawnGuard.pipe()
        process.standardOutput = output
        let errorPipe = SpawnGuard.pipe()
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            errors = String(decoding: errorData, as: UTF8.self)
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
