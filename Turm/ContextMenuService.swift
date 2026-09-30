import AppKit
import FinderSync

/// Opens folders sent by the Turm Finder extension, which adds "Open in Turm" to Finder's context menus.
final class ContextMenuService: NSObject {
    static let shared = ContextMenuService()

    static let title = "Open in Turm"
    static let extensionIdentifier = "com.zak-noble-clarke.Turm.FinderSync"

    private static let configuredKey = "turm.finderExtension.configured"

    private let workspaces = NSMapTable<NSWindow, Workspace>.weakToWeakObjects()
    private weak var lastKeyWindow: NSWindow?
    private var pending: [String] = []

    static var isEnabled: Bool {
        get { FIFinderSyncController.isExtensionEnabled }
        set {
            UserDefaults.standard.set(true, forKey: configuredKey)
            pluginkit([["-e", newValue ? "use" : "ignore", "-i", extensionIdentifier]])
        }
    }

    private static let pluginkitQueue = DispatchQueue(label: "turm.pluginkit", qos: .utility)
    private static let pluginkitTimeout: TimeInterval = 5

    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var extensionURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("TurmFinder.appex")
    }

    private static func pluginkit(_ commands: [[String]]) {
        guard !isTestHost else { return }
        pluginkitQueue.async {
            for arguments in commands { runPluginkit(arguments) }
        }
    }

    private static func runPluginkit(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pluginkitTimeout) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
    }

    func install() {
        var commands: [[String]] = []
        if let path = Self.extensionURL?.path { commands.append(["-a", path]) }
        if !UserDefaults.standard.bool(forKey: Self.configuredKey) {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
            commands.append(["-e", "use", "-i", Self.extensionIdentifier])
        }
        Self.pluginkit(commands)
    }

    func handle(_ url: URL) {
        let directories = Self.directories(for: Self.fileURLs(in: url))
        guard !directories.isEmpty else { return }
        pending += directories
        openPending()
    }

    static func fileURLs(in url: URL) -> [URL] {
        guard url.scheme == "turm", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [] }
        return items.compactMap { item in
            guard item.name == "path", let path = item.value, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    func register(_ workspace: Workspace, in window: NSWindow) {
        workspaces.setObject(workspace, forKey: window)
        if window.isKeyWindow || lastKeyWindow == nil { lastKeyWindow = window }
        openPending()
    }

    func unregister(_ window: NSWindow) {
        workspaces.removeObject(forKey: window)
        if lastKeyWindow === window { lastKeyWindow = nil }
    }

    func windowBecameKey(_ window: NSWindow) {
        guard workspaces.object(forKey: window) != nil else { return }
        lastKeyWindow = window
        openPending()
    }

    static func directories(for urls: [URL]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
            let path = (isDirectory ? url : url.deletingLastPathComponent()).standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }

    private var target: (window: NSWindow, workspace: Workspace)? {
        let ordered = [lastKeyWindow].compactMap(\.self) + NSApp.orderedWindows
        for window in ordered where window.isVisible {
            if let workspace = workspaces.object(forKey: window) { return (window, workspace) }
        }
        return nil
    }

    private func openPending() {
        guard !pending.isEmpty, let target else { return }
        let directories = pending
        pending.removeAll()
        directories.forEach { target.workspace.open(directory: $0) }
        NSApp.activate()
        target.window.makeKeyAndOrderFront(nil)
    }
}
