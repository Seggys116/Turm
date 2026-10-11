import Foundation
import Testing
@testable import TurmCore

struct FileCopyTests {
    @Test func copyingReportsProgressAndKeepsTheOriginal() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.txt")
        let payload = Data(repeating: 7, count: FileCopy.chunk + 32)
        try payload.write(to: source)
        var marks: [Int64] = []
        let destination = root.appendingPathComponent("out/note.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileCopy.transfer(from: source, to: destination, move: false) { sent, total in
            marks.append(sent)
            #expect(total == Int64(payload.count))
        }
        #expect(marks.last == Int64(payload.count))
        #expect(try Data(contentsOf: destination) == payload)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func cancellingRemovesThePartialFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("big.bin")
        try Data(repeating: 1, count: FileCopy.chunk * 4).write(to: source)
        let destination = root.appendingPathComponent("copy.bin")
        var calls = 0
        #expect(throws: FileDropError.cancelled) {
            try FileCopy.transfer(from: source, to: destination, move: false, isCancelled: {
                calls += 1
                return calls > 2
            }, onProgress: { _, _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turm-copy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
