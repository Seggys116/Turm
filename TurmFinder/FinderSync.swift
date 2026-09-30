import AppKit
import FinderSync

final class FinderSync: FIFinderSync {
    private static let title = "Open in Turm"

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
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override var toolbarItemName: String { "Turm" }

    override var toolbarItemToolTip: String { "Open the current folder in Turm" }

    override var toolbarItemImage: NSImage { Self.icon }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        self.menuKind = menuKind
        let menu = NSMenu(title: "")
        let item = menu.addItem(withTitle: Self.title, action: #selector(openInTurm(_:)), keyEquivalent: "")
        item.image = Self.icon
        return menu
    }

    @objc private func openInTurm(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        var urls = menuKind == .contextualMenuForItems ? controller.selectedItemURLs() ?? [] : []
        if urls.isEmpty, let target = controller.targetedURL() { urls = [target] }
        guard !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "turm"
        components.host = "open"
        components.queryItems = urls.map { URLQueryItem(name: "path", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
