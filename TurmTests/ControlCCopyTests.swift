import AppKit
import SwiftTerm
import SwiftUI
import Testing
import TurmCore
@testable import Turm

@MainActor
private func copyWait(timeout: Duration = .seconds(60), until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// A pasteboard of its own, so the tests never touch the user's clipboard.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("turm-test-\(UUID().uuidString)"))
}

private func controlC() -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
        characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
    )!
}

@MainActor
struct ControlCCopyTests {
    @Test func controlCIsRecognisedOnlyWithoutOtherModifiers() {
        #expect(BlockSelection.isControlC(controlC()))
        let commandC = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{3}", charactersIgnoringModifiers: "C", isARepeat: false, keyCode: 8
        )!
        #expect(!BlockSelection.isControlC(commandC))
    }

    @Test func controlCCopiesSelectedOutputAndDropsTheSelection() async throws {
        let session = TerminalSession()
        defer { session.terminate() }
        #expect(await copyWait { session.phase == .ready })
        session.submit("echo copy-me-please")
        #expect(await copyWait { session.blocks.first?.isRunning == false })
        session.selection.selectAll()
        #expect(session.selection.hasSelection)
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        #expect(session.selection.copyForControlC(to: pasteboard))
        #expect(pasteboard.string(forType: .string)?.contains("copy-me-please") == true)
        #expect(!session.selection.hasSelection)
        #expect(!session.selection.copyForControlC(to: pasteboard))
    }

    @Test func controlCInAFullScreenProgramCopiesTheSelectionInsteadOfSendingIt() throws {
        let host = AltScreenHost(cols: 40, rows: 6)
        host.feed(Array("\u{1B}[?1049hselected words".utf8))
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        #expect(!host.view.copySelectionForControlC(controlC(), to: pasteboard))
        host.view.selectAll(nil)
        #expect(host.view.copySelectionForControlC(controlC(), to: pasteboard))
        #expect(pasteboard.string(forType: .string)?.contains("selected words") == true)
        #expect(!host.view.selectionActive)
    }
}

@MainActor
struct ControlCInputTests {
    private final class Box {
        var text = ""
    }

    private func editor(copies: Bool) throws -> (NSWindow, EditorTextView) {
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = InputEditor(
            text: Binding(get: { box.text }, set: { box.text = $0 }), isFocused: true, isEnabled: true, directory: NSTemporaryDirectory(),
            completion: CompletionModel(), onSubmit: {}, onClear: {}, onFocus: {}, onAttach: { _ in }, onDragTarget: { _ in },
            onCopySelection: { copies }
        )
        window.contentView = NSHostingView(rootView: editor.frame(width: 600, height: 60))
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> EditorTextView? {
            if let match = view as? EditorTextView { return match }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        return (window, try #require(window.contentView.flatMap(find)))
    }

    @Test func controlCKeepsTheLineWhenItCopiedOutput() throws {
        let (window, view) = try editor(copies: true)
        defer { window.close() }
        view.insertText("half typed", replacementRange: view.selectedRange())
        view.keyDown(with: controlC())
        #expect(view.string == "half typed")
    }

    @Test func controlCStillClearsTheLineWithNothingSelected() throws {
        let (window, view) = try editor(copies: false)
        defer { window.close() }
        view.insertText("half typed", replacementRange: view.selectedRange())
        view.keyDown(with: controlC())
        #expect(view.string.isEmpty)
    }
}

struct CompletionNarrowingTests {
    private func item(_ insert: String, kind: CompletionItem.Kind = .directory) -> CompletionItem {
        CompletionItem(insert: insert, kind: kind, terminator: "")
    }

    @Test func typingMoreDropsWhatNoLongerFits() {
        let items = [item("/Users/me/Library/iTunes/"), item("/Users/me/Library/Caches/"), item("/Users/me/Library/com.apple.x/"), item("/Users/me/Library/Calendars/")]
        #expect(SuggestionList.narrow(items, typed: "/Users/me/Library/ca").map(\.insert) == [
            "/Users/me/Library/Caches/", "/Users/me/Library/Calendars/",
        ])
        #expect(SuggestionList.narrow(items, typed: "/Users/me/Library/c").count == 3)
        #expect(SuggestionList.narrow(items, typed: "/Users/me/Library/zz").isEmpty)
    }

    @Test func historyRowsAreNeverKeptByNarrowing() {
        #expect(SuggestionList.narrow([item("git status", kind: .history)], typed: "git").isEmpty)
    }
}
