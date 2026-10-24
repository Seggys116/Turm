import AppKit
import FinderSync

final class FinderSync: FIFinderSync {
    private static let title = "Open in Turm"
    private static let copyTitle = "Copy Path"
    private static let settings = UserDefaults(suiteName: "com.zak-noble-clarke.Turm")

    private var menuKind = FIMenuKind.contextualMenuForContainer
    private var observers: [NSObjectProtocol] = []
    private var watchers: [String: VolumeWatcher] = [:]
    private var knownChildren: [String: [URL]] = [:]
    private var applied: Set<URL> = []
    private var refreshPending = false

    private static var appURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.watchedVolumes() }
        }
        watchedVolumes()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        watchers.values.forEach { $0.cancel() }
    }

    private struct MountedVolume {
        var url: URL
        var isStartupDisk: Bool
        var isLocal: Bool

        var root: FinderDirectories.VolumeRoot {
            FinderDirectories.VolumeRoot(url: url, isStartupDisk: isStartupDisk)
        }
    }

    /// Registers the startup disk, and the folders on every other disk. Finder draws the app icon
    /// on a disk when the disk itself is registered.
    private func watchedVolumes() {
        let mounted = mountedVolumes()
        let next = FinderDirectories.monitored(volumes: mounted.map(\.root)) { self.childDirectories(of: $0) }
        if next != applied {
            applied = next
            FIFinderSyncController.default().directoryURLs = next
        }
        watch(mounted)
    }

    private func mountedVolumes() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [.volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return mounted.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return MountedVolume(
                url: url,
                isStartupDisk: url.standardizedFileURL.path == "/" || values?.volumeIsRootFileSystem == true,
                isLocal: values?.volumeIsLocal == true
            )
        }
    }

    private func childDirectories(of volume: URL) -> [URL] {
        let root = volume.standardizedFileURL
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .volumeURLKey],
                options: [.skipsHiddenFiles]
            )
            let children = items.filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .volumeURLKey]),
                      values.isDirectory == true else { return false }
                guard let container = values.volume?.standardizedFileURL.path else { return true }
                return container == root.path
            }
            knownChildren[root.path] = children
            return children
        } catch {
            return knownChildren[root.path] ?? []
        }
    }

    private func watch(_ mounted: [MountedVolume]) {
        let local = Set(mounted.compactMap { volume -> String? in
            guard volume.isLocal, !volume.isStartupDisk else { return nil }
            let path = volume.url.standardizedFileURL.path
            return path == "/" ? nil : path
        })
        for path in watchers.keys where !local.contains(path) {
            watchers.removeValue(forKey: path)?.cancel()
        }
        let present = Set(mounted.map { $0.url.standardizedFileURL.path })
        for path in knownChildren.keys where !present.contains(path) {
            knownChildren.removeValue(forKey: path)
        }
        for path in local where watchers[path] == nil {
            watchers[path] = VolumeWatcher(path: path) { [weak self] in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.watchedVolumes()
        }
    }

    override var toolbarItemName: String { "Turm" }

    override var toolbarItemToolTip: String { "Open the current folder in Turm" }

    override var toolbarItemImage: NSImage { Self.icon }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        self.menuKind = menuKind
        let menu = NSMenu(title: "")
        let item = menu.addItem(withTitle: Self.title, action: #selector(openInTurm(_:)), keyEquivalent: "")
        item.image = Self.icon
        if Self.settings?.bool(forKey: "turm.finderExtension.copyPath") == true {
            menu.addItem(withTitle: Self.copyTitle, action: #selector(copyPath(_:)), keyEquivalent: "")
        }
        return menu
    }

    private func targetURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        var urls = menuKind == .contextualMenuForItems ? controller.selectedItemURLs() ?? [] : []
        if urls.isEmpty, let target = controller.targetedURL() { urls = [target] }
        return urls
    }

    @objc private func copyPath(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func openInTurm(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "turm"
        components.host = "open"
        components.queryItems = urls.map { URLQueryItem(name: "path", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

private final class VolumeWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, onChange: @escaping () -> Void) {
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
