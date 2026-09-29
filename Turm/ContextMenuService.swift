import AppKit

/// Handles the "Open in Turm" service that Finder shows in its context menu for files and folders.
final class ContextMenuService: NSObject {
    static let shared = ContextMenuService()

    static let title = "Open in Turm"
    static let message = "openInTurm"

    private let workspaces = NSMapTable<NSWindow, Workspace>.weakToWeakObjects()
    private weak var lastKeyWindow: NSWindow?
    private var pending: [String] = []

    static var isEnabled: Bool {
        get {
            let status = CFPreferencesCopyAppValue(statusKey as CFString, statusDomain) as? [String: Any]
            let entry = status?[statusEntry] as? [String: Any]
            return (entry?["enabled_context_menu"] as? NSNumber)?.boolValue ?? true
        }
        set {
            var status = CFPreferencesCopyAppValue(statusKey as CFString, statusDomain) as? [String: Any] ?? [:]
            let flag = NSNumber(value: newValue)
            status[statusEntry] = [
                "enabled_context_menu": flag,
                "enabled_services_menu": flag,
                "presentation_modes": ["ContextMenu": flag, "ServicesMenu": flag],
            ]
            CFPreferencesSetAppValue(statusKey as CFString, status as CFDictionary, statusDomain)
            CFPreferencesAppSynchronize(statusDomain)
            refreshServices()
        }
    }

    private static let statusDomain = "pbs" as CFString
    private static let statusKey = "NSServicesStatus"

    private static var statusEntry: String {
        "\(Bundle.main.bundleIdentifier ?? "com.zak-noble-clarke.Turm") - \(title) - \(message)"
    }

    private static func refreshServices() {
        NSUpdateDynamicServices()
        let pbs = Process()
        pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        pbs.arguments = ["-flush"]
        pbs.standardOutput = FileHandle.nullDevice
        pbs.standardError = FileHandle.nullDevice
        try? pbs.run()
    }

    func install() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
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

    @objc func openInTurm(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let directories = Self.directories(for: urls)
        guard !directories.isEmpty else {
            error.pointee = "Turm could not find a folder in the selection." as NSString
            return
        }
        pending += directories
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
