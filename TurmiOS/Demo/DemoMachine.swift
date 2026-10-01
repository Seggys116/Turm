#if targetEnvironment(simulator)
import Foundation
import TurmCore

final class DemoMachine {
    struct Reply {
        var output: [String] = []
        var exitCode: Int32 = 0
    }

    enum Flavor {
        case zsh
        case bash
    }

    let user: String
    let host: String
    let home: String
    let flavor: Flavor
    private(set) var directory: String
    private let projectRoot: String?
    private(set) var branch: String?
    private let branches: [String]
    private let git: CompanionGit?

    init(user: String, host: String, home: String, flavor: Flavor, directory: String, git: CompanionGit? = nil, branches: [String] = []) {
        self.user = user
        self.host = host
        self.home = home
        self.flavor = flavor
        self.directory = directory
        self.git = git
        projectRoot = git == nil ? nil : directory
        branch = git?.branch
        self.branches = git.map { Array(Set(branches + [$0.branch])).sorted() } ?? []
    }

    var location: String {
        PathDisplay.abbreviate(directory, home: home)
    }

    var branchNames: [String] { branches }

    var currentGit: CompanionGit? {
        guard let git, let branch, let projectRoot, directory == projectRoot || directory.hasPrefix(projectRoot + "/") else { return nil }
        return CompanionGit(branch: branch, files: git.files, added: git.added, removed: git.removed)
    }

    func switchBranch(to name: String) -> String? {
        guard branches.contains(name) else { return "error: pathspec '\(name)' did not match any file(s) known to git" }
        branch = name
        return nil
    }

    func run(_ line: String) -> Reply {
        let words = Self.words(line)
        guard let command = words.first else { return Reply() }
        let arguments = Array(words.dropFirst())
        switch command {
        case "cd":
            return changeDirectory(arguments.first)
        case "pwd":
            return Reply(output: [directory])
        case "ls":
            return Reply(output: listing(long: arguments.contains { $0.hasPrefix("-") && $0.contains("l") }))
        case "echo":
            return Reply(output: [arguments.joined(separator: " ")])
        case "whoami":
            return Reply(output: [user])
        case "hostname":
            return Reply(output: [host])
        case "date":
            return Reply(output: [Date().formatted(.dateTime.weekday().day().month().hour().minute().second().year())])
        case "uname":
            return Reply(output: [flavor == .zsh ? (arguments.isEmpty ? "Darwin" : "Darwin \(host) 25.0.0 Darwin Kernel arm64") : (arguments.isEmpty ? "Linux" : "Linux \(host) 6.8.0-45-generic x86_64 GNU/Linux")])
        case "git":
            return gitCommand(arguments)
        case "clear", "true", "sleep", "exit", "logout":
            return Reply()
        case "false":
            return Reply(exitCode: 1)
        default:
            let message = flavor == .zsh ? "zsh: command not found: \(command)" : "bash: \(command): command not found"
            return Reply(output: [message], exitCode: 127)
        }
    }

    private func changeDirectory(_ target: String?) -> Reply {
        guard let target, target != "~" else {
            directory = home
            return Reply()
        }
        let expanded = target.hasPrefix("~/") ? home + target.dropFirst(1) : target
        let base = expanded.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        var parts = base
        for part in expanded.split(separator: "/").map(String.init) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        directory = "/" + parts.joined(separator: "/")
        return Reply()
    }

    private func listing(long: Bool) -> [String] {
        let entries: [(name: String, folder: Bool)] = if currentGit != nil {
            [("Packages", true), ("README.md", false), ("Turm", true), ("Turm.xcodeproj", true), ("TurmiOS", true), ("docs", true)]
        } else if directory == home {
            [("Desktop", true), ("Documents", true), ("Downloads", true), ("Projects", true)]
        } else {
            [("README.md", false), ("src", true)]
        }
        let styled = entries.map { $0.folder ? "\u{1B}[34m\($0.name)\u{1B}[0m" : $0.name }
        guard long else { return [styled.joined(separator: "  ")] }
        return zip(entries, styled).map { entry, name in
            (entry.folder ? "drwxr-xr-x  5 " : "-rw-r--r--  1 ") + "\(user)  staff  \(entry.folder ? 160 : 2048)  Oct  1 17:44 \(name)"
        }
    }

    private func gitCommand(_ arguments: [String]) -> Reply {
        guard let git = currentGit else {
            return Reply(output: ["fatal: not a git repository (or any of the parent directories): .git"], exitCode: 128)
        }
        switch arguments.first {
        case "status":
            return Reply(output: [
                "On branch \(git.branch)",
                "Changes not staged for commit:",
                "\t\u{1B}[31mmodified:   TurmiOS/Blocks/CommandField.swift\u{1B}[0m",
                "",
                "no changes added to commit (use \"git add\" and/or \"git commit -a\")",
            ])
        case "branch":
            return Reply(output: branches.map { $0 == git.branch ? "* \u{1B}[32m\($0)\u{1B}[0m" : "  \($0)" })
        case "switch", "checkout":
            guard let name = arguments.dropFirst().first else { return Reply(output: ["fatal: missing branch name"], exitCode: 128) }
            if let failure = switchBranch(to: name) { return Reply(output: [failure], exitCode: 1) }
            return Reply(output: ["Switched to branch '\(name)'"])
        case nil:
            return Reply(output: ["usage: git [-v | --version] [-h | --help] <command> [<args>]"], exitCode: 1)
        default:
            return Reply()
        }
    }

    private static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
#endif
