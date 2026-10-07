import AppKit
import FinderSync

final class FinderSync: FIFinderSync {
    private static let title = "Open in Turm"
    private static let copyTitle = "Copy Path"
    private static let settings = UserDefaults(suiteName: "com.zak-noble-clarke.Turm")

    private var menuKind = FIMenuKind.contextualMenuForContainer

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
        watchedVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.watchedVolumes() }
        }
    }

    private func watchedVolumes() {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        FIFinderSyncController.default().directoryURLs = Set([URL(fileURLWithPath: "/")] + mounted)
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
