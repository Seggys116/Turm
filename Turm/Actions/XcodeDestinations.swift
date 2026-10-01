import Foundation
import IOKit.ps

nonisolated struct XcodeDestination: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case mac, iPhone, iPad, watch, tv, vision
    }

    var kind: Kind
    var platform: String
    var name: String
    var id = ""
    var isSimulator = false
    var isBooted = false
    var os = ""

    static let mac = XcodeDestination(kind: .mac, platform: "macOS", name: "My Mac")

    var symbol: String {
        switch kind {
        case .mac: XcodeDestinations.macSymbol
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .watch: "applewatch"
        case .tv: "appletv"
        case .vision: "visionpro"
        }
    }

    var specifier: String {
        switch kind {
        case .mac: "platform=macOS"
        default: "platform=\(platform)\(isSimulator ? " Simulator" : ""),id=\(id)"
        }
    }

    var argument: String { "-destination \(ShellQuoting.quote(specifier))" }

    var detail: String {
        var parts: [String] = []
        if !os.isEmpty { parts.append("\(platform) \(os)") }
        if !isSimulator, kind != .mac { parts.append("Device") }
        if isBooted { parts.append("Booted") }
        return parts.joined(separator: ", ")
    }

    var option: ProjectVariant.Option {
        ProjectVariant.Option(label: name, value: argument, symbol: symbol, detail: detail.isEmpty ? nil : detail, tags: [platform])
    }
}

nonisolated final class DestinationCache: @unchecked Sendable {
    static let shared = DestinationCache()

    private let lock = NSLock()
    private var stored: [XcodeDestination]?
    private var fetched = Date.distantPast
    private var refreshing = false
    private var discovery: Task<Void, Never>?

    var destinations: [XcodeDestination]? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var age: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(fetched)
    }

    func store(_ destinations: [XcodeDestination]) {
        lock.lock()
        stored = destinations
        fetched = Date()
        refreshing = false
        discovery = nil
        lock.unlock()
    }

    func firstDiscovery() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let discovery { return discovery }
        let task = Task.detached { [self] in
            store(XcodeDestinations.discover())
        }
        discovery = task
        return task
    }

    /// True for the caller that should start a background refresh; others see one already running.
    func beginRefresh() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if refreshing { return false }
        refreshing = true
        return true
    }

    func endRefresh() {
        lock.lock()
        refreshing = false
        lock.unlock()
    }
}

nonisolated enum XcodeDestinations {
    static let staleAfter: TimeInterval = 60

    static let macSymbol: String = {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue()
        return CFArrayGetCount(sources) > 0 ? "laptopcomputer" : "desktopcomputer"
    }()

    private static let runtimePlatforms = ["iOS": "iOS", "tvOS": "tvOS", "watchOS": "watchOS", "xrOS": "visionOS", "visionOS": "visionOS"]
    private static let devicePlatforms = ["iOS": "iOS", "tvOS": "tvOS", "watchOS": "watchOS", "xrOS": "visionOS", "visionOS": "visionOS"]

    private static func kind(platform: String, name: String) -> XcodeDestination.Kind {
        switch platform {
        case "watchOS": .watch
        case "tvOS": .tv
        case "visionOS": .vision
        default: name.hasPrefix("iPad") ? .iPad : .iPhone
        }
    }

    static func parseSimulators(_ json: String) -> [XcodeDestination] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let runtimes = root["devices"] as? [String: Any]
        else { return [] }
        var result: [XcodeDestination] = []
        for (runtime, list) in runtimes {
            guard let name = runtime.components(separatedBy: "SimRuntime.").last, let devices = list as? [[String: Any]] else { continue }
            let pieces = name.split(separator: "-").map(String.init)
            guard let family = pieces.first, let platform = runtimePlatforms[family] else { continue }
            let version = pieces.dropFirst().joined(separator: ".")
            for device in devices {
                guard let deviceName = device["name"] as? String, let udid = device["udid"] as? String,
                      device["isAvailable"] as? Bool ?? true else { continue }
                result.append(XcodeDestination(
                    kind: kind(platform: platform, name: deviceName), platform: platform, name: deviceName, id: udid,
                    isSimulator: true, isBooted: device["state"] as? String == "Booted", os: version
                ))
            }
        }
        return sorted(result)
    }

    /// Reads the file written by `xcrun devicectl list devices --json-output`; only connected devices are offered.
    static func parseDevices(_ json: Data) -> [XcodeDestination] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else { return [] }
        var result: [XcodeDestination] = []
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            guard connection["tunnelState"] as? String == "connected",
                  let udid = hardware["udid"] as? String ?? device["identifier"] as? String,
                  let name = properties["name"] as? String,
                  let family = hardware["platform"] as? String, let platform = devicePlatforms[family]
            else { continue }
            let type = hardware["deviceType"] as? String ?? name
            result.append(XcodeDestination(
                kind: kind(platform: platform, name: type), platform: platform, name: name, id: udid,
                isSimulator: false, isBooted: false, os: properties["osVersionNumber"] as? String ?? ""
            ))
        }
        return sorted(result)
    }

    static func sorted(_ destinations: [XcodeDestination]) -> [XcodeDestination] {
        func rank(_ platform: String) -> Int { XcodeSchemes.platformOrder.firstIndex(of: platform) ?? XcodeSchemes.platformOrder.count }
        return destinations.sorted { lhs, rhs in
            if lhs.platform != rhs.platform { return rank(lhs.platform) < rank(rhs.platform) }
            if lhs.isSimulator != rhs.isSimulator { return !lhs.isSimulator }
            if lhs.os != rhs.os { return lhs.os.compare(rhs.os, options: .numeric) == .orderedDescending }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func options(_ destinations: [XcodeDestination]) -> [ProjectVariant.Option] {
        destinations.map(\.option)
    }

    static func discover() -> [XcodeDestination] {
        var found = [XcodeDestination.mac]
        if let json = ProcessRunner.run("/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "available", "-j"], timeout: 10, requireSuccess: true) {
            found += parseSimulators(json)
        }
        let output = (NSTemporaryDirectory() as NSString).appendingPathComponent("turm-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(atPath: output) }
        if ProcessRunner.run(
            "/usr/bin/xcrun", arguments: ["devicectl", "list", "devices", "--json-output", output, "--timeout", "5"], timeout: 10, requireSuccess: true
        ) != nil, let data = FileManager.default.contents(atPath: output) {
            found += parseDevices(data)
        }
        return found
    }

    @concurrent
    static func prepare() async {
        let cache = DestinationCache.shared
        guard cache.destinations != nil else {
            await cache.firstDiscovery().value
            return
        }
        guard cache.age > staleAfter, cache.beginRefresh() else { return }
        Task.detached(priority: .utility) {
            cache.store(discover())
        }
    }
}

nonisolated enum XcodeRun {
    static let script: String = [
        #"dest=; prev=; for a in "$@"; do [ "$prev" = -destination ] && dest=$a; prev=$a; done;"#,
        #"xcodebuild "$@" build || exit $?;"#,
        #"xcodebuild "$@" -showBuildSettings 2>/dev/null | { d=; n=; b=; w=;"#,
        #"while IFS= read -r l; do case $l in"#,
        #""Build settings for"*) [ "$w" = app ] && break; d=; n=; b=; w=;;"#,
        #""    TARGET_BUILD_DIR = "*) d=${l#*= };;"#,
        #""    FULL_PRODUCT_NAME = "*) n=${l#*= };;"#,
        #""    PRODUCT_BUNDLE_IDENTIFIER = "*) b=${l#*= };;"#,
        #""    WRAPPER_EXTENSION = "*) w=${l#*= };;"#,
        #"esac; done;"#,
        #"[ "$w" = app ] || { echo "Turm: the scheme builds no app to run" >&2; exit 1; };"#,
        #"app="$d/$n"; case "$dest" in"#,
        #""platform=macOS"*) open "$app";;"#,
        #"*Simulator*) id=${dest#*id=}; id=${id%%,*};"#,
        #"xcrun simctl boot "$id" 2>/dev/null; xcrun simctl bootstatus "$id" >/dev/null; open -a Simulator;"#,
        #"xcrun simctl install "$id" "$app" && xcrun simctl launch "$id" "$b";;"#,
        #"platform=*id=*) id=${dest#*id=}; id=${id%%,*};"#,
        #"xcrun devicectl device install app --device "$id" "$app" && xcrun devicectl device process launch --device "$id" "$b";;"#,
        #"*) echo "Turm: choose a run destination" >&2; exit 1;;"#,
        #"esac; }"#,
    ].joined(separator: " ")

    static func command(arguments: String) -> String {
        "sh -c \(ShellQuoting.quote(script)) turm-run \(arguments)"
    }
}
