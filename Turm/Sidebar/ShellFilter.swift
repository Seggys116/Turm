import Foundation

nonisolated enum ShellFilter {
    static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            fields.contains { $0.localizedStandardContains(term) }
        }
    }
}

extension TerminalSession {
    var searchFields: [String] {
        var fields = [title, directory, Block.abbreviate(directory)]
        if let git { fields.append(git.branch) }
        fields.append(contentsOf: blocks.map(\.command))
        return fields
    }

    var customTitle: String? {
        if let userTitle { return userTitle }
        guard let programTitle, !programTitle.isEmpty else { return nil }
        return programTitle
    }
}

extension Workspace {
    func sessions(in tab: ShellTab) -> [TerminalSession] {
        tab.layout.leaves.compactMap { session(for: $0) }
    }

    func representative(of tab: ShellTab) -> TerminalSession? {
        session(for: tab.focusedPane) ?? sessions(in: tab).first
    }

    func shells(matching query: String) -> [ShellTab] {
        tabs.filter { tab in
            ShellFilter.matches(query, fields: sessions(in: tab).flatMap(\.searchFields))
        }
    }
}
