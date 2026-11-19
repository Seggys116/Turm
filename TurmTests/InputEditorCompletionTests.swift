import AppKit
import SwiftUI
import Testing
import TurmCore
@testable import Turm

/// Hosts the real input editor in a window that is never shown, and types into it.
@MainActor
private final class EditorRig {
    let completion = CompletionModel()
    let window: NSWindow
    let folder: URL

    /// Owned by the binding, which SwiftUI may still read after the test is done with the rig.
    private final class TextBox {
        var text = ""
    }

    init(folder: URL) {
        self.folder = folder
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let box = TextBox()
        let binding = Binding<String>(get: { box.text }, set: { box.text = $0 })
        let editor = InputEditor(
            text: binding, isFocused: true, isEnabled: true, directory: folder.path, completion: completion,
            onSubmit: {}, onClear: {}, onFocus: {}, onAttach: { _ in }, onDragTarget: { _ in }
        )
        window.contentView = NSHostingView(rootView: editor.frame(width: 600, height: 60))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    var textView: EditorTextView? {
        func find(_ view: NSView) -> EditorTextView? {
            if let match = view as? EditorTextView { return match }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    func type(_ characters: String) {
        guard let view = textView else { return }
        for character in characters {
            view.insertText(String(character), replacementRange: view.selectedRange())
        }
    }

    func press(_ selector: Selector) {
        textView?.doCommand(by: selector)
    }

    func wait(timeout: Duration = .seconds(20), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func close() {
        completion.close()
        window.close()
    }
}

@MainActor
struct InputEditorCompletionTests {
    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("turm-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("zeta-dir"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("zeta notes.txt"))
        return folder
    }

    @Test func theListOpensWhileTypingAndTabAcceptsTheHighlightedItem() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = EditorRig(folder: folder)
        defer { rig.close() }
        // the shell helper may still be loading the user's configuration, so typing is retried until the list opens
        var opened = false
        for _ in 0..<10 where !opened {
            rig.textView?.string = ""
            rig.type("cat ze")
            opened = await rig.wait(timeout: .seconds(3)) { rig.completion.isOpen }
        }
        #expect(opened)
        let inserts = Set(rig.completion.items.map(\.insert))
        #expect(inserts.isSuperset(of: ["zeta\\ notes.txt", "zeta-dir/"]), "\(rig.completion.items)")
        #expect(!rig.completion.engaged)
        let chosen = rig.completion.items[rig.completion.selected]
        rig.press(#selector(NSResponder.insertTab(_:)))
        #expect(rig.textView?.string == "cat " + chosen.insert + chosen.terminator)
    }

    @Test func tabStillTakesTheGreySuggestionFirst() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = "zeta-marker-\(UUID().uuidString.prefix(6))"
        CommandHistory.shared.record("echo \(marker) again", directory: folder.path)
        let rig = EditorRig(folder: folder)
        defer { rig.close() }
        rig.type("echo \(marker.prefix(8))")
        #expect(await rig.wait(timeout: .seconds(3)) { rig.textView?.ghost.isEmpty == false })
        #expect(rig.textView?.ghost == String(marker.dropFirst(8)) + " again")
        rig.press(#selector(NSResponder.insertTab(_:)))
        #expect(rig.textView?.string == "echo \(marker)")
    }

    @Test func anImpossibleHistoryLineIsNotSuggested() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = "gone-\(UUID().uuidString.prefix(6))"
        CommandHistory.shared.record("cd \(missing)", directory: "/somewhere/else")
        let rig = EditorRig(folder: folder)
        defer { rig.close() }
        rig.type("cd gone-")
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.textView?.ghost.hasPrefix(String(missing.dropFirst(5))) != true)
    }
}
