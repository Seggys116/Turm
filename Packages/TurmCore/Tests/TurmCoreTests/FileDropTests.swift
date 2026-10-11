import Foundation
import Testing
@testable import TurmCore

struct FileDropTests {
    @Test func aFolderCannotMoveIntoItselfOrAChild() {
        #expect(!FileDrop.canPlace("/work/src", into: "/work/src", move: true))
        #expect(!FileDrop.canPlace("/work/src", into: "/work/src/lib", move: true))
        #expect(FileDrop.canPlace("/work/src/a.txt", into: "/work/docs", move: true))
    }

    @Test func movingIntoTheCurrentFolderIsANoOpAndCopyingThereIsAllowed() {
        #expect(!FileDrop.canPlace("/work/a.txt", into: "/work", move: true))
        #expect(FileDrop.canPlace("/work/a.txt", into: "/work", move: false))
    }

    @Test func destinationAddsASuffixWhenTheNameIsTaken() {
        let path = FileDrop.destination(named: "notes.txt", into: "/work", existing: ["notes.txt", "notes 2.txt"])
        #expect(path == "/work/notes 3.txt")
    }

    @Test func movingAFileIntoAnotherFolderRemovesItFromTheSource() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a/note.txt")
        let folder = root.appendingPathComponent("b").path
        let placed = try FileDrop.place(source: source, into: folder, move: true)
        #expect(placed?.lastPathComponent == "note.txt")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b/note.txt").path))
    }

    @Test func anExternalDropCopiesAndLeavesTheOriginal() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("hello".utf8).write(to: outside)
        let folder = root.appendingPathComponent("b").path
        let placed = try FileDrop.place(source: outside, into: folder, move: false)
        #expect(placed?.lastPathComponent == "outside.txt")
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try Data(contentsOf: root.appendingPathComponent("b/outside.txt")) == Data("hello".utf8))
    }

    @Test func aCopyBesideAnExistingNameGetsASuffix() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("note.txt")
        try Data("new".utf8).write(to: outside)
        let placed = try FileDrop.place(source: outside, into: root.appendingPathComponent("a").path, move: false)
        #expect(placed?.lastPathComponent == "note 2.txt")
        #expect(try String(contentsOf: root.appendingPathComponent("a/note.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: root.appendingPathComponent("a/note 2.txt"), encoding: .utf8) == "new")
    }

    @Test func movingAFolderIntoItsChildDoesNothing() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let placed = try FileDrop.place(
            source: root.appendingPathComponent("a"), into: root.appendingPathComponent("a/nested").path, move: true
        )
        #expect(placed == nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/note.txt").path))
    }

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-drop-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("a/note.txt"))
        return root
    }
}
