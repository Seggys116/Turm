import Foundation
import Testing
@testable import TurmCore

struct FinderDirectoriesTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func theStartupDiskIsRegisteredAndItsFoldersAreNot() {
        let volumes = [
            FinderDirectories.VolumeRoot(url: url("/"), isStartupDisk: true),
            FinderDirectories.VolumeRoot(url: url("/Volumes/Extra"), isStartupDisk: false),
        ]
        let monitored = FinderDirectories.monitored(volumes: volumes) { volume in
            #expect(volume.path == "/Volumes/Extra")
            return [volume.appendingPathComponent("Projects"), volume.appendingPathComponent("My Disk")]
        }
        #expect(Set(monitored.map(\.path)) == ["/", "/Volumes/Extra/Projects", "/Volumes/Extra/My Disk"])
    }

    @Test func anExternalDiskIsNotRegistered() {
        let disk = FinderDirectories.VolumeRoot(url: url("/Volumes/Extra"), isStartupDisk: false)
        let monitored = FinderDirectories.monitored(volumes: [disk]) { volume in
            [volume, volume.appendingPathComponent("Projects")]
        }
        #expect(Set(monitored.map(\.path)) == ["/", "/Volumes/Extra/Projects"])
    }

    @Test func theRootPathIsNeverSplitIntoFolders() {
        let root = FinderDirectories.VolumeRoot(url: url("/"), isStartupDisk: false)
        var asked = false
        let monitored = FinderDirectories.monitored(volumes: [root]) { _ in
            asked = true
            return [url("/Users")]
        }
        #expect(!asked)
        #expect(monitored.map(\.path) == ["/"])
    }

    @Test func aFolderFromAnotherDiskIsIgnored() {
        let disk = FinderDirectories.VolumeRoot(url: url("/Volumes/Extra"), isStartupDisk: false)
        let monitored = FinderDirectories.monitored(volumes: [disk]) { _ in
            [url("/Volumes/Other/Projects"), url("/Volumes/Extra/Projects")]
        }
        #expect(Set(monitored.map(\.path)) == ["/", "/Volumes/Extra/Projects"])
    }
}
