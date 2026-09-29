import Foundation

nonisolated enum PathCompleter {
    nonisolated struct Result: Equatable {
        let range: Range<String.Index>
        let replacement: String
    }

    static func complete(_ line: String, directory: String) -> Result? {
        let start = wordStart(in: line)
        let word = unescape(String(line[start...]))
        guard !word.isEmpty else { return nil }

        let expanded = word.hasPrefix("~") ? NSHomeDirectory() + word.dropFirst() : word
        let slash = expanded.lastIndex(of: "/")
        let folderPart = slash.map { String(expanded[...$0]) } ?? ""
        let prefix = slash.map { String(expanded[expanded.index(after: $0)...]) } ?? expanded
        let base = folderPart.isEmpty ? directory : (folderPart.hasPrefix("/") ? folderPart : directory + "/" + folderPart)

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        let showHidden = prefix.hasPrefix(".")
        let matches = names
            .filter { $0.hasPrefix(prefix) && (showHidden || !$0.hasPrefix(".")) }
            .sorted()
        guard !matches.isEmpty else { return nil }

        let common = matches.dropFirst().reduce(matches[0]) { commonPrefix($0, $1) }
        var completed = common
        if matches.count == 1 {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: base + "/" + common, isDirectory: &isDirectory)
            if isDirectory.boolValue { completed += "/" }
        }
        guard completed != prefix else { return nil }

        let typedFolder = word.lastIndex(of: "/").map { String(word[...$0]) } ?? ""
        return Result(range: start..<line.endIndex, replacement: escape(typedFolder + completed))
    }

    private static func wordStart(in line: String) -> String.Index {
        var index = line.endIndex
        while index > line.startIndex {
            let previous = line.index(before: index)
            if line[previous].isWhitespace {
                var backslashes = 0
                var probe = previous
                while probe > line.startIndex, line[line.index(before: probe)] == "\\" {
                    backslashes += 1
                    probe = line.index(before: probe)
                }
                if backslashes % 2 == 0 { break }
            }
            index = previous
        }
        return index
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        String(zip(a, b).prefix { $0.0 == $0.1 }.map(\.0))
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if " ()[]{}&;|<>*?$`'\"\\!#".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
