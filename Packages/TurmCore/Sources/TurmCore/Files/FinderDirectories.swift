import Foundation

/// Folders a Finder Sync extension can register without Finder painting the app icon onto a disk.
///
/// Finder gives every registered folder except the startup disk the extension's icon in the sidebar.
/// A registered external disk therefore shows the app icon. Register the folders on that disk instead:
/// the menu still appears inside them, and the disk keeps its own icon.
///
/// The Finder extension does not link TurmCore, so this is a copy of `FinderDirectories` in the package.
/// The tests cover the package one. Keep the two copies the same.
nonisolated enum FinderDirectories {
    struct VolumeRoot: Equatable {
        var url: URL
        var isStartupDisk: Bool
    }

    static func monitored(volumes: [VolumeRoot], directoriesIn: (URL) -> [URL]) -> Set<URL> {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        for volume in volumes {
            let root = volume.url.standardizedFileURL
            guard !volume.isStartupDisk, root.path != "/" else { continue }
            let prefix = root.path + "/"
            for child in directoriesIn(root) {
                let child = child.standardizedFileURL
                guard child.path.hasPrefix(prefix) else { continue }
                urls.insert(child)
            }
        }
        return urls
    }
}
