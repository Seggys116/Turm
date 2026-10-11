import Foundation
import Testing
@testable import TurmCore

private func makeEntry(name: String, path: String, isDirectory: Bool) -> FileEntry {
    FileEntry(
        name: name,
        path: path,
        isDirectory: isDirectory,
        size: isDirectory ? nil : Int64(name.utf8.count),
        modified: nil,
        kind: FileListing.kind(name: name, isDirectory: isDirectory)
    )
}

struct FileListingTests {
    @Test func presentSortsFoldersFirstHidesDotfilesAndFiltersCase() {
        let entries = [
            makeEntry(name: "zebra.txt", path: "/zebra.txt", isDirectory: false),
            makeEntry(name: "Aardvark", path: "/Aardvark", isDirectory: true),
            makeEntry(name: ".hidden", path: "/.hidden", isDirectory: false),
            makeEntry(name: "beta", path: "/beta", isDirectory: true),
            makeEntry(name: "Notes.txt", path: "/Notes.txt", isDirectory: false),
        ]

        let visible = FileListing.present(entries, includeHidden: false, filter: "")
        #expect(visible.map(\.name) == ["Aardvark", "beta", "Notes.txt", "zebra.txt"])

        let withHidden = FileListing.present(entries, includeHidden: true, filter: "")
        #expect(withHidden.first?.isDirectory == true)
        #expect(withHidden.contains(where: { $0.name == ".hidden" }))

        let filtered = FileListing.present(entries, includeHidden: false, filter: "NOTE")
        #expect(filtered.map(\.name) == ["Notes.txt"])

        let noMatch = FileListing.present(entries, includeHidden: false, filter: "xyz")
        #expect(noMatch.isEmpty)
    }

    @Test func kindReturnsCorrectStrings() {
        #expect(FileListing.kind(name: "anything", isDirectory: true) == "Folder")
        #expect(FileListing.kind(name: "readme.md", isDirectory: false) == "MD")
        #expect(FileListing.kind(name: "Makefile", isDirectory: false) == "File")
    }
}

struct LocalDirectoryTests {
    @Test func listsChildrenAndHandlesMissingPath() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let subdir = tmp.appendingPathComponent("subdir")
        try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("file.txt")
        try Data("hello".utf8).write(to: file)
        let hidden = tmp.appendingPathComponent(".hidden")
        try Data("hidden".utf8).write(to: hidden)

        let listed = LocalDirectory.list(tmp.path)
        #expect(listed.failure == nil)
        #expect(listed.entries.count == 3)

        let visible = FileListing.present(listed.entries, includeHidden: false, filter: "")
        #expect(visible.count == 2)
        #expect(!visible.contains(where: { $0.isHidden }))

        let withHidden = FileListing.present(listed.entries, includeHidden: true, filter: "")
        #expect(withHidden.count == 3)

        let missingPath = "/tmp/turm-nonexistent-\(UUID().uuidString)"
        let failed = LocalDirectory.list(missingPath)
        #expect(failed.failure != nil)
        #expect(failed.entries.isEmpty)
        #expect(try #require(failed.failure).contains(missingPath))
    }

    @Test func emptyFoldersHaveNoVisibleEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-empty-" + UUID().uuidString, isDirectory: true)
        let empty = root.appendingPathComponent("Toolbox", isDirectory: true)
        let dotted = root.appendingPathComponent("HiddenOnly", isDirectory: true)
        let filled = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filled, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dotted.appendingPathComponent(".keep"))
        try Data("x".utf8).write(to: filled.appendingPathComponent("main.swift"))
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = [empty.path, dotted.path, filled.path]
        let visible = LocalDirectory.directoriesWithVisibleEntries(paths, includeHidden: false)
        #expect(visible == Set([filled.path]))

        let withHidden = LocalDirectory.directoriesWithVisibleEntries(paths, includeHidden: true)
        #expect(withHidden == Set([dotted.path, filled.path]))
        #expect(LocalDirectory.containsVisibleEntry(root.appendingPathComponent("missing").path, includeHidden: false))
    }

    @Test func remoteListingParsesKindsSizesAndNames() {
        let text = "d\t\tsrc\nf\t12\tmain.swift\n"
        let listed = RemoteFiles.parseListing(text, directory: "/home/zak")
        #expect(listed.failure == nil)
        #expect(listed.entries.map(\.name) == ["src", "main.swift"])
        #expect(listed.entries[0].isDirectory)
        #expect(listed.entries[0].path == "/home/zak/src")
        #expect(listed.entries[1].size == 12)
        #expect(listed.entries[1].kind == "SWIFT")
        #expect(RemoteFiles.listScript("/home/zak").contains("cd '/home/zak'"))
        #expect(RemoteFiles.listScript("/tmp/a'b").contains("'/tmp/a'\\''b'"))
    }

    @Test func visibleRemoteDirectoriesAreThePathsThatPrinted() {
        let found = RemoteFiles.parseVisibleDirectories("/home/zak/src\n\n/home/zak/bin\n")
        #expect(found == ["/home/zak/src", "/home/zak/bin"])
        #expect(RemoteFiles.readScript("/home/zak/main.swift").contains("[ -f "))
    }
}

struct FileNamesTests {
    @Test func suffixedCreatesUniqueNames() {
        #expect(FileNames.suffixed("report.pdf", existing: []) == "report.pdf")

        #expect(FileNames.suffixed("notes.txt", existing: ["notes.txt"]) == "notes 2.txt")

        #expect(FileNames.suffixed("notes.txt", existing: ["notes.txt", "notes 2.txt"]) == "notes 3.txt")

        #expect(FileNames.suffixed("Makefile", existing: ["Makefile"]) == "Makefile 2")
    }
}

struct MemoryFilesTests {
    private func makeFiles() -> MemoryFiles {
        MemoryFiles(nodes: [
            "/": .init(isDirectory: true),
            "/docs": .init(isDirectory: true),
            "/docs/readme.txt": .init(data: Data("hello".utf8), isDirectory: false),
        ])
    }

    @Test func listDownloadUploadAndErrors() throws {
        var files = makeFiles()

        let root = try files.list(directory: "/")
        #expect(root.count == 1)
        #expect(root[0].name == "docs")
        #expect(root[0].isDirectory)

        let docs = try files.list(directory: "/docs")
        #expect(docs.count == 1)
        #expect(docs[0].name == "readme.txt")

        let downloaded = try files.download(path: "/docs/readme.txt")
        #expect(downloaded == Data("hello".utf8))

        #expect(throws: FileTransferError.fileExists("/docs/readme.txt")) {
            try files.upload(Data("world".utf8), to: "/docs/readme.txt", overwrite: false)
        }

        try files.upload(Data("world".utf8), to: "/docs/readme.txt", overwrite: true)
        #expect(try files.download(path: "/docs/readme.txt") == Data("world".utf8))

        #expect(throws: FileTransferError.notFound("/docs/missing")) {
            try files.upload(Data("x".utf8), to: "/docs/missing/file.txt", overwrite: false)
        }

        #expect(throws: FileTransferError.notFound("/nonexistent")) {
            try files.list(directory: "/nonexistent")
        }

        #expect(throws: FileTransferError.notFound("/docs/absent.txt")) {
            try files.download(path: "/docs/absent.txt")
        }
    }

    @Test func disconnectedPreventsAllOperationsAndTreeIsUnchanged() throws {
        var files = MemoryFiles(nodes: [
            "/": .init(isDirectory: true),
            "/docs": .init(isDirectory: true),
            "/docs/file.txt": .init(data: Data("x".utf8), isDirectory: false),
        ], connected: false)

        #expect(throws: FileTransferError.disconnected) {
            try files.list(directory: "/")
        }
        #expect(throws: FileTransferError.disconnected) {
            try files.download(path: "/docs/file.txt")
        }
        #expect(throws: FileTransferError.disconnected) {
            try files.upload(Data("y".utf8), to: "/new.txt", overwrite: false)
        }

        #expect(files.nodes["/new.txt"] == nil)

        files.connected = true
        try files.upload(Data("z".utf8), to: "/new.txt", overwrite: false)
        #expect(files.nodes["/new.txt"] != nil)
    }
}

struct TransferProgressTests {
    @Test func fractionAdvancedCancelled() {
        let p = TransferProgress(transferred: 50, total: 100)
        #expect(p.fraction == 0.5)

        #expect(TransferProgress(transferred: 50, total: nil).fraction == nil)
        #expect(TransferProgress(transferred: 0, total: 0).fraction == nil)

        let advanced = p.advanced(by: 25)
        #expect(advanced.transferred == 75)
        #expect(advanced.total == 100)
        #expect(!advanced.isCancelled)

        let stopped = p.cancelled()
        #expect(stopped.isCancelled)
        #expect(stopped.transferred == 50)
        #expect(stopped.total == 100)

        let advancedAfterCancel = stopped.advanced(by: 10)
        #expect(advancedAfterCancel.isCancelled)
        #expect(advancedAfterCancel.transferred == 60)
    }
}

private final class MemoryAdapter: RemoteFileSystem, @unchecked Sendable {
    var files: MemoryFiles

    init(_ files: MemoryFiles) { self.files = files }

    func list(directory: String) async throws -> [FileEntry] { try files.list(directory: directory) }
    func download(path: String) async throws -> Data { try files.download(path: path) }
    func upload(_ data: Data, to path: String, overwrite: Bool) async throws { try files.upload(data, to: path, overwrite: overwrite) }
}

struct RemoteFileSystemConformanceTests {
    @Test func memoryAdapterConformsToRemoteFileSystem() async throws {
        let adapter = MemoryAdapter(MemoryFiles(nodes: [
            "/": .init(isDirectory: true),
            "/hello.txt": .init(data: Data("hi".utf8), isDirectory: false),
        ]))

        let entries = try await adapter.list(directory: "/")
        #expect(entries.count == 1)
        #expect(entries[0].name == "hello.txt")

        let data = try await adapter.download(path: "/hello.txt")
        #expect(data == Data("hi".utf8))

        try await adapter.upload(Data("bye".utf8), to: "/hello.txt", overwrite: true)
        let updated = try await adapter.download(path: "/hello.txt")
        #expect(updated == Data("bye".utf8))
    }
}
