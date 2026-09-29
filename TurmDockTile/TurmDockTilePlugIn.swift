import AppKit

@objc(TurmDockTilePlugIn)
final class TurmDockTilePlugIn: NSObject, NSDockTilePlugIn {
    private static let changed = Notification.Name("com.zak-noble-clarke.Turm.dockTileChanged")
    private static let themeChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    private var dockTile: NSDockTile?
    private var observers: [NSObjectProtocol] = []

    func setDockTile(_ dockTile: NSDockTile?) {
        self.dockTile = dockTile
        let center = DistributedNotificationCenter.default()
        observers.forEach(center.removeObserver)
        observers = []
        guard dockTile != nil else { return }
        for name in [Self.changed, Self.themeChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        guard let dockTile else { return }
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        if let image = NSImage(contentsOf: Self.render(dark: dark)) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            dockTile.contentView = view
        } else {
            dockTile.contentView = nil
        }
        dockTile.display()
    }

    private static func render(dark: Bool) -> URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Turm", isDirectory: true)
            .appendingPathComponent(dark ? "DockTile-dark.png" : "DockTile-light.png")
    }
}
