import Foundation

nonisolated struct CLIInvocation: Hashable, Sendable {
    let tool: String
    let arguments: [String]
}

nonisolated enum DockerListing: Sendable {
    case images
    case allContainers
    case runningContainers
    case volumes
    case networks
}

nonisolated enum CLIListing {
    static let deadline: TimeInterval = 3
    static let ttl: TimeInterval = 10

    static func kubectl(kind: String, context: String?, namespace: String?, kubeconfig: String?) -> CLIInvocation {
        var arguments = ["get", kind, "-o", "name", "--request-timeout=2s"]
        if let context { arguments += ["--context", context] }
        if let namespace { arguments += ["-n", namespace] }
        if let kubeconfig { arguments += ["--kubeconfig", kubeconfig] }
        return CLIInvocation(tool: "kubectl", arguments: arguments)
    }

    static func helmReleases(namespace: String?, context: String?, kubeconfig: String?) -> CLIInvocation {
        var arguments = ["list", "-q"]
        if let namespace { arguments += ["--namespace", namespace] }
        if let context { arguments += ["--kube-context", context] }
        if let kubeconfig { arguments += ["--kubeconfig", kubeconfig] }
        return CLIInvocation(tool: "helm", arguments: arguments)
    }

    static func dockerTail(_ listing: DockerListing) -> [String] {
        switch listing {
        case .images: return ["images", "--format", "{{.Repository}}:{{.Tag}}"]
        case .allContainers: return ["ps", "-a", "--format", "{{.Names}}"]
        case .runningContainers: return ["ps", "--format", "{{.Names}}"]
        case .volumes: return ["volume", "ls", "--format", "{{.Name}}"]
        case .networks: return ["network", "ls", "--format", "{{.Name}}"]
        }
    }

    static func docker(_ listing: DockerListing, context: String?) -> CLIInvocation {
        var arguments: [String] = []
        if let context { arguments += ["--context", context] }
        return CLIInvocation(tool: "docker", arguments: arguments + dockerTail(listing))
    }

    static func safeValue(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.count < 512 && !value.contains("\0") && !value.contains("\n")
    }

    static func validKind(_ kind: String) -> Bool {
        guard !kind.isEmpty, kind.count < 100 else { return false }
        return kind.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }
            && !kind.hasPrefix(".") && !kind.hasPrefix("-")
    }

    static func optionPairs(_ rest: ArraySlice<String>, allowed: Set<String>) -> Bool {
        guard rest.count % 2 == 0 else { return false }
        var seen = Set<String>()
        var index = rest.startIndex
        while index < rest.endIndex {
            let key = rest[index]
            let value = rest[index + 1]
            guard allowed.contains(key), seen.insert(key).inserted, safeValue(value) else { return false }
            index += 2
        }
        return true
    }

    static func isAllowed(_ invocation: CLIInvocation) -> Bool {
        let a = invocation.arguments
        switch invocation.tool {
        case "kubectl":
            guard a.count >= 5, a[0] == "get", validKind(a[1]), a[2] == "-o", a[3] == "name", a[4] == "--request-timeout=2s" else {
                return false
            }
            return optionPairs(a[5...], allowed: ["--context", "-n", "--kubeconfig"])
        case "helm":
            guard a.count >= 2, a[0] == "list", a[1] == "-q" else { return false }
            return optionPairs(a[2...], allowed: ["--namespace", "--kube-context", "--kubeconfig"])
        case "docker":
            var tail = a[...]
            if a.count >= 2, a[0] == "--context" {
                guard safeValue(a[1]) else { return false }
                tail = a[2...]
            }
            let shapes: [DockerListing] = [.images, .allContainers, .runningContainers, .volumes, .networks]
            return shapes.contains { Array(tail) == dockerTail($0) }
        default:
            return false
        }
    }

    static func kubectlNames(_ output: String) -> [(kind: String, name: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let slash = text.firstIndex(of: "/") else { return nil }
            let name = String(text[text.index(after: slash)...])
            return name.isEmpty ? nil : (String(text[..<slash]), name)
        }
    }
}

nonisolated final class CLIListingCache: @unchecked Sendable {
    typealias Runner = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> String?

    private let locate: (String) -> String?
    private let runner: Runner
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [CLIInvocation: (time: Date, lines: [String])] = [:]

    init(locate: @escaping (String) -> String?, runner: @escaping Runner, now: @escaping () -> Date = { Date() }) {
        self.locate = locate
        self.runner = runner
        self.now = now
    }

    func lines(_ invocation: CLIInvocation) -> [String] {
        guard CLIListing.isAllowed(invocation) else { return [] }
        lock.lock()
        if let entry = entries[invocation], now().timeIntervalSince(entry.time) < CLIListing.ttl {
            lock.unlock()
            return entry.lines
        }
        lock.unlock()
        guard let executable = locate(invocation.tool) else { return [] }
        let output = runner(executable, invocation.arguments, CLIListing.deadline)
        let lines = output?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        lock.lock()
        entries[invocation] = (now(), lines)
        lock.unlock()
        return lines
    }
}
