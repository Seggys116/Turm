import Foundation

nonisolated enum GitCompletion {
    nonisolated enum Arguments {
        case refs
        case localBranches
        case remoteThenRefs
        case remotes
        case paths
        case none
    }

    static let subcommands: [(name: String, detail: String)] = [
        ("add", "Add file contents to the index"),
        ("am", "Apply patches from a mailbox"),
        ("archive", "Create an archive of files from a tree"),
        ("bisect", "Find the change that introduced a bug"),
        ("blame", "Show what revision and author last modified each line"),
        ("branch", "List, create, or delete branches"),
        ("bundle", "Move objects and refs by archive"),
        ("checkout", "Switch branches or restore working tree files"),
        ("cherry-pick", "Apply the changes introduced by existing commits"),
        ("clean", "Remove untracked files from the working tree"),
        ("clone", "Clone a repository into a new directory"),
        ("commit", "Record changes to the repository"),
        ("config", "Get and set repository or global options"),
        ("describe", "Describe a commit using the most recent tag"),
        ("diff", "Show changes between commits, index, and working tree"),
        ("fetch", "Download objects and refs from another repository"),
        ("format-patch", "Prepare patches for e-mail submission"),
        ("gc", "Clean up unnecessary files and optimize the repository"),
        ("grep", "Print lines matching a pattern"),
        ("init", "Create an empty repository"),
        ("log", "Show commit logs"),
        ("merge", "Join two or more development histories together"),
        ("mv", "Move or rename a file, directory, or symlink"),
        ("pull", "Fetch from and integrate with another repository"),
        ("push", "Update remote refs along with associated objects"),
        ("range-diff", "Compare two commit ranges"),
        ("rebase", "Reapply commits on top of another base tip"),
        ("reflog", "Manage reflog information"),
        ("remote", "Manage set of tracked repositories"),
        ("reset", "Reset current HEAD to the specified state"),
        ("restore", "Restore working tree files"),
        ("revert", "Revert some existing commits"),
        ("rm", "Remove files from the working tree and the index"),
        ("shortlog", "Summarize git log output"),
        ("show", "Show various types of objects"),
        ("sparse-checkout", "Reduce your working tree to a subset of tracked files"),
        ("stash", "Stash the changes in a dirty working directory away"),
        ("status", "Show the working tree status"),
        ("submodule", "Initialize, update or inspect submodules"),
        ("switch", "Switch branches"),
        ("tag", "Create, list, delete or verify a tag object"),
        ("worktree", "Manage multiple working trees"),
    ]

    static let stashActions: [(name: String, detail: String)] = [
        ("push", "Save local modifications to a new stash"),
        ("pop", "Apply and remove the latest stash"),
        ("apply", "Apply a stash without removing it"),
        ("drop", "Remove a single stash entry"),
        ("list", "List stash entries"),
        ("show", "Show the changes recorded in a stash"),
        ("branch", "Create a branch from a stash"),
        ("clear", "Remove all stash entries"),
    ]

    static let remoteActions: [(name: String, detail: String)] = [
        ("add", "Add a remote"),
        ("remove", "Remove a remote"),
        ("rename", "Rename a remote"),
        ("show", "Show information about a remote"),
        ("prune", "Delete stale tracking branches"),
        ("set-url", "Change the URL of a remote"),
        ("get-url", "Show the URL of a remote"),
    ]

    static func arguments(for subcommand: String) -> Arguments {
        switch subcommand {
        case "checkout", "switch", "merge", "rebase", "cherry-pick", "diff", "log", "show", "reset", "revert",
             "blame", "describe", "format-patch", "shortlog", "reflog", "range-diff", "bisect", "archive":
            return .refs
        case "branch":
            return .localBranches
        case "tag":
            return .refs
        case "push", "pull", "fetch":
            return .remoteThenRefs
        case "remote":
            return .remotes
        case "add", "rm", "mv", "restore", "clean", "grep", "sparse-checkout", "commit", "clone", "init", "worktree", "submodule":
            return .paths
        default:
            return .none
        }
    }

    static let globalOptionsWithValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]

    nonisolated struct Parsed {
        var subcommand: String?
        var subcommandArguments: [String]
        var pastDoubleDash: Bool
    }

    static func parse(arguments words: [String]) -> Parsed {
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("-") {
                index += globalOptionsWithValue.contains(word) ? 2 : 1
            } else {
                break
            }
        }
        guard index < words.count else {
            return Parsed(subcommand: nil, subcommandArguments: [], pastDoubleDash: false)
        }
        let rest = Array(words[(index + 1)...])
        return Parsed(subcommand: words[index], subcommandArguments: rest, pastDoubleDash: rest.contains("--"))
    }
}
