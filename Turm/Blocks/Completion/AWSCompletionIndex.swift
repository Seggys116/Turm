import Foundation
import SQLite3

nonisolated struct AWSIndexEntry: Equatable, Sendable {
    let name: String
    let detail: String?
    let type: String?
}

nonisolated enum AWSCompletionIndex {
    static func candidatePaths(_ env: CompletionEnvironment) -> [String] {
        let home = env.homeDirectory
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let configured = env.variables["HOMEBREW_PREFIX"] { prefixes.insert(configured, at: 0) }
        var libs = prefixes.map { $0 + "/opt/awscli/libexec/lib" }
        libs += [home + "/.local/pipx/venvs/awscli/lib", home + "/Library/Python"]
        if let venv = env.variables["VIRTUAL_ENV"] { libs.append(venv + "/lib") }
        var paths: [String] = []
        for lib in libs {
            for entry in env.directoryEntries(atPath: lib) ?? [] where entry.isDirectory {
                paths.append(lib + "/" + entry.name + "/site-packages/awscli/data/ac.index")
                paths.append(lib + "/" + entry.name + "/lib/python/site-packages/awscli/data/ac.index")
            }
        }
        for version in env.directoryEntries(atPath: "/usr/local/aws-cli/v2") ?? [] where version.isDirectory {
            paths.append("/usr/local/aws-cli/v2/" + version.name + "/dist/awscli/data/ac.index")
        }
        paths.append("/usr/local/aws-cli/v2/current/dist/awscli/data/ac.index")
        return paths
    }

    static func locate(_ env: CompletionEnvironment) -> String? {
        candidatePaths(env).first { env.fileExists(atPath: $0) }
    }

    private static func rows(path: String, sql: String, parameters: [String], columns: Int) -> [[String?]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW, result.count < 20000 {
            result.append((0..<columns).map { column in
                sqlite3_column_text(statement, Int32(column)).map { String(cString: $0) }
            })
        }
        return result
    }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private static func columnNames(path: String, table: String) -> [String] {
        guard isIdentifier(table) else { return [] }
        return rows(path: path, sql: "PRAGMA table_info(\(table))", parameters: [], columns: 2).compactMap { $0[1] }
    }

    private static func tables(path: String) -> (commands: (table: String, columns: [String])?, params: (table: String, columns: [String])?) {
        var commands: (table: String, columns: [String])?
        var params: (table: String, columns: [String])?
        for row in rows(path: path, sql: "SELECT name FROM sqlite_master WHERE type = 'table'", parameters: [], columns: 1) {
            guard let name = row[0], isIdentifier(name) else { continue }
            let columns = columnNames(path: path, table: name)
            if columns.contains("argname") || columns.contains("arg_name"), columns.contains("parent"), columns.contains("command"), params == nil {
                params = (name, columns)
            } else if columns.contains("parent"), columns.contains("command"), commands == nil {
                commands = (name, columns)
            }
        }
        return (commands, params)
    }

    static func commands(path: String, parent: String) -> [AWSIndexEntry] {
        guard let table = tables(path: path).commands else { return [] }
        let description = table.columns.contains("help_summary") ? "help_summary" : (table.columns.contains("full_name") ? "full_name" : "NULL")
        let kind = table.columns.contains("command_type") ? "command_type" : "NULL"
        let sql = "SELECT command, \(description), \(kind) FROM \(table.table) WHERE parent = ? AND command != '' ORDER BY command"
        for candidate in [parent, parent.replacingOccurrences(of: ".", with: " ")] {
            let found = rows(path: path, sql: sql, parameters: [candidate], columns: 3).compactMap { row -> AWSIndexEntry? in
                guard let name = row[0] else { return nil }
                return AWSIndexEntry(name: name, detail: row[1].flatMap(clean), type: row[2])
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    static func options(path: String, parent: String, command: String) -> [AWSIndexEntry] {
        guard let table = tables(path: path).params else { return [] }
        let description = table.columns.contains("help_summary") ? "help_summary" : "NULL"
        let type = table.columns.contains("type_name") ? "type_name" : "NULL"
        let positional = table.columns.contains("positional_arg")
            ? " AND (positional_arg IS NULL OR positional_arg = '' OR positional_arg = '0')"
            : ""
        let nameColumn = table.columns.contains("argname") ? "argname" : "arg_name"
        let sql = "SELECT \(nameColumn), \(description), \(type) FROM \(table.table) WHERE parent = ? AND command = ?\(positional) ORDER BY \(nameColumn)"
        var lookups = [(parent, command)]
        if command.isEmpty { lookups.append(("", parent.split(separator: ".").last.map(String.init) ?? parent)) }
        for (lookupParent, lookupCommand) in lookups {
            var seen = Set<String>()
            let found = rows(path: path, sql: sql, parameters: [lookupParent, lookupCommand], columns: 3).compactMap { row -> AWSIndexEntry? in
                guard var name = row[0], !name.isEmpty else { return nil }
                if !name.hasPrefix("-") { name = "--" + name }
                guard seen.insert(name).inserted else { return nil }
                return AWSIndexEntry(name: name, detail: row[1].flatMap(clean), type: row[2])
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func clean(_ text: String) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return ManPageFlags.summarize(flat)
    }
}
