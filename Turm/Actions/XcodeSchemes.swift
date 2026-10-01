import Foundation

nonisolated struct XcodeScheme: Equatable, Hashable, Sendable {
    var name: String
    var symbol: String
    var platforms: [String] = []
}

nonisolated enum XcodeSchemes {
    struct Target: Equatable, Sendable {
        var id: String
        var name: String
        var productType: String
        var platforms: [String]
    }

    static let platformOrder = ["macOS", "iOS", "watchOS", "tvOS", "visionOS"]

    private static let sdkPlatforms = [
        "macosx": "macOS", "iphoneos": "iOS", "iphonesimulator": "iOS", "watchos": "watchOS", "watchsimulator": "watchOS",
        "appletvos": "tvOS", "appletvsimulator": "tvOS", "xros": "visionOS", "xrsimulator": "visionOS",
    ]

    private static let platformSymbols = [
        "macOS": "macwindow", "iOS": "iphone", "watchOS": "applewatch", "tvOS": "appletv", "visionOS": "visionpro",
    ]

    static func symbol(forExtension ext: String?, platforms: [String] = []) -> String {
        guard let ext else { return "cube" }
        switch ext.lowercased() {
        case "app":
            return platforms.count == 1 ? platformSymbols[platforms[0]] ?? "app" : "app"
        case "appex": return "puzzlepiece.extension"
        case "framework", "xcframework": return "shippingbox"
        case "xctest": return "checkmark.diamond"
        case "a", "dylib": return "books.vertical"
        case "": return "terminal"
        default: return "cube"
        }
    }

    static func symbol(buildableName: String?, platforms: [String] = []) -> String {
        symbol(forExtension: buildableName.map { ($0 as NSString).pathExtension }, platforms: platforms)
    }

    static func fileExtension(forProductType type: String) -> String? {
        let prefix = "com.apple.product-type."
        guard type.hasPrefix(prefix) else { return nil }
        let kind = type.dropFirst(prefix.count)
        if kind.hasPrefix("application") { return "app" }
        if kind.hasPrefix("app-extension") || kind.hasSuffix("-extension") { return "appex" }
        if kind.hasPrefix("framework") { return "framework" }
        if kind.hasPrefix("bundle.unit-test") || kind.hasPrefix("bundle.ui-testing") { return "xctest" }
        if kind == "library.static" { return "a" }
        if kind == "library.dynamic" { return "dylib" }
        if kind == "tool" { return "" }
        return nil
    }

    static func discover(container: String, in directory: String) -> [XcodeScheme] {
        let path = (directory as NSString).appendingPathComponent(container)
        let projects = path.hasSuffix(".xcworkspace") ? workspaceProjects(at: path) : [path]
        let owners = (path.hasSuffix(".xcworkspace") ? [path] : []) + projects
        var targets: [Target] = []
        var byProject: [String: [Target]] = [:]
        for project in projects {
            let found = self.targets(inProject: project)
            byProject[project] = found
            targets += found
        }

        var schemes: [XcodeScheme] = []
        for owner in owners {
            for file in schemeFiles(in: owner) {
                let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                    schemes.append(XcodeScheme(name: name, symbol: symbol(buildableName: nil)))
                    continue
                }
                let reference = runnableReference(in: text)
                let target = reference.flatMap { ref in
                    targets.first { $0.id == ref["BlueprintIdentifier"] } ?? targets.first { $0.name == ref["BlueprintName"] }
                }
                let platforms = target?.platforms ?? []
                var buildable = reference?["BuildableName"]
                if buildable == nil, let target, let ext = fileExtension(forProductType: target.productType) {
                    buildable = "\(target.name).\(ext)"
                }
                schemes.append(XcodeScheme(name: name, symbol: symbol(buildableName: buildable, platforms: platforms), platforms: platforms))
            }
        }
        if schemes.isEmpty {
            for project in projects {
                for target in byProject[project] ?? [] where fileExtension(forProductType: target.productType) != nil {
                    schemes.append(XcodeScheme(
                        name: target.name,
                        symbol: symbol(forExtension: fileExtension(forProductType: target.productType), platforms: target.platforms),
                        platforms: target.platforms
                    ))
                }
            }
        }

        var seen = Set<String>()
        let unique = schemes.filter { seen.insert($0.name).inserted }
        let preferred = (container as NSString).deletingPathExtension
        return unique.sorted { lhs, rhs in
            if (lhs.name == preferred) != (rhs.name == preferred) { return lhs.name == preferred }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func schemeFiles(in container: String) -> [String] {
        let manager = FileManager.default
        var folders = [(container as NSString).appendingPathComponent("xcshareddata/xcschemes")]
        let users = (container as NSString).appendingPathComponent("xcuserdata")
        for user in ((try? manager.contentsOfDirectory(atPath: users)) ?? []).sorted() where user.hasSuffix(".xcuserdatad") {
            folders.append((users as NSString).appendingPathComponent(user + "/xcschemes"))
        }
        return folders.flatMap { folder in
            ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).sorted()
                .filter { $0.hasSuffix(".xcscheme") && !$0.hasPrefix(".") }
                .map { (folder as NSString).appendingPathComponent($0) }
        }
    }

    /// Projects a workspace lists, resolved against the folder holding the workspace; Pods is left out as Xcode hides its schemes.
    static func workspaceProjects(at workspace: String) -> [String] {
        let file = (workspace as NSString).appendingPathComponent("contents.xcworkspacedata")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return workspaceProjects(in: text, base: (workspace as NSString).deletingLastPathComponent)
    }

    static func workspaceProjects(in text: String, base: String) -> [String] {
        guard let tags = try? NSRegularExpression(pattern: #"<(/?)(Group|FileRef)\b([^>]*?)(/?)>"#) else { return [] }
        var stack: [String] = []
        var result: [String] = []
        for match in tags.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func part(_ index: Int) -> String {
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            let closing = part(1) == "/"
            let isGroup = part(2) == "Group"
            let selfClosing = part(4) == "/"
            let location = attributes(of: part(3))["location"] ?? ""
            if isGroup {
                if closing { _ = stack.popLast() } else if !selfClosing { stack.append(relative(location) ?? "") }
                continue
            }
            guard !closing, location.hasPrefix("absolute:") || relative(location) != nil else { continue }
            var path: String
            if location.hasPrefix("absolute:") {
                path = String(location.dropFirst("absolute:".count))
            } else {
                path = ([base] + stack + [relative(location) ?? ""]).filter { !$0.isEmpty }.joined(separator: "/")
            }
            path = URL(fileURLWithPath: path).standardizedFileURL.path
            guard path.hasSuffix(".xcodeproj"), (path as NSString).lastPathComponent != "Pods.xcodeproj",
                  !result.contains(path) else { continue }
            result.append(path)
        }
        return result
    }

    private static func relative(_ location: String) -> String? {
        for prefix in ["group:", "container:"] where location.hasPrefix(prefix) {
            return String(location.dropFirst(prefix.count))
        }
        return nil
    }

    static func targets(inProject project: String) -> [Target] {
        let file = (project as NSString).appendingPathComponent("project.pbxproj")
        guard let data = FileManager.default.contents(atPath: file),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]]
        else { return [] }
        let projectObject = (root["rootObject"] as? String).flatMap { objects[$0] }
        let inherited = buildSettings(of: projectObject, in: objects)
        var result: [Target] = []
        for id in projectObject?["targets"] as? [String] ?? [] {
            guard let object = objects[id], object["isa"] as? String == "PBXNativeTarget", let name = object["name"] as? String else { continue }
            let own = buildSettings(of: object, in: objects)
            result.append(Target(
                id: id, name: name, productType: object["productType"] as? String ?? "",
                platforms: platforms(
                    sdkroot: own["SDKROOT"] ?? inherited["SDKROOT"],
                    supported: own["SUPPORTED_PLATFORMS"] ?? inherited["SUPPORTED_PLATFORMS"]
                )
            ))
        }
        return result
    }

    static func platforms(sdkroot: String?, supported: String?) -> [String] {
        let tokens = (supported ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let names = (tokens.isEmpty ? [sdkroot ?? ""] : tokens).compactMap { sdkPlatforms[$0.lowercased()] }
        return platformOrder.filter(names.contains)
    }

    private static func buildSettings(of owner: [String: Any]?, in objects: [String: [String: Any]]) -> [String: String] {
        guard let list = (owner?["buildConfigurationList"] as? String).flatMap({ objects[$0] }),
              let ids = list["buildConfigurations"] as? [String]
        else { return [:] }
        let configurations = ids.compactMap { objects[$0] }
        let chosen = configurations.first { $0["name"] as? String == "Debug" } ?? configurations.first
        var settings: [String: String] = [:]
        for (key, value) in chosen?["buildSettings"] as? [String: Any] ?? [:] {
            if let text = value as? String {
                settings[key] = text
            } else if let list = value as? [String] {
                settings[key] = list.joined(separator: " ")
            }
        }
        return settings
    }

    /// The reference a scheme launches, else the first one it builds for running, else any.
    static func runnableReference(in scheme: String) -> [String: String]? {
        if let launch = section("LaunchAction", in: scheme), let reference = references(in: launch).first { return reference }
        if let build = section("BuildAction", in: scheme) {
            let entries = build.components(separatedBy: "<BuildActionEntry").dropFirst()
            for entry in entries where entry.prefix(while: { $0 != ">" }).contains("buildForRunning = \"YES\"") {
                if let reference = references(in: entry).first { return reference }
            }
        }
        return references(in: scheme).first
    }

    private static func section(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    private static func references(in text: String) -> [[String: String]] {
        guard let expression = try? NSRegularExpression(pattern: #"<BuildableReference\b[^>]*>"#) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { attributes(of: String(text[$0])) }
        }
    }

    static func attributes(of tag: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)""#) else { return [:] }
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let key = Range(match.range(at: 1), in: tag), let value = Range(match.range(at: 2), in: tag) else { continue }
            result[String(tag[key])] = unescape(String(tag[value]))
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
