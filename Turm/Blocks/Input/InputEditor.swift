import AppKit
import SwiftUI
import TurmCore

struct InputEditor: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let isEnabled: Bool
    let directory: String
    let completion: CompletionModel
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onFocus: () -> Void
    let onAttach: ([URL]) -> Void
    let onDragTarget: (Bool) -> Void
    var onSelectAllBlocks: () -> Void = {}
    var isRemote = false
    var remoteChannel: RemoteChannel?
    var onTags: (Bool) -> Void = { _ in }
    var history = CommandHistory.shared

    private static let maxLines: CGFloat = 8

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScroller = SquareScroller()
        let view = EditorTextView()
        scroll.documentView = view
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.font = TerminalMetrics.font
        view.textColor = Theme.text.dynamicNS
        view.insertionPointColor = Theme.text.dynamicNS
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.delegate = context.coordinator
        context.coordinator.textView = view
        view.onFocus = { context.coordinator.parent.onFocus() }
        view.onControl = { context.coordinator.control($0) }
        view.onAttach = { context.coordinator.attached() }
        view.onFiles = { context.coordinator.parent.onAttach($0) }
        view.onDragTarget = { context.coordinator.parent.onDragTarget($0) }
        view.onClick = { context.coordinator.dismissPopup() }
        view.onSelectAllBlocks = { context.coordinator.parent.onSelectAllBlocks() }
        view.extraMenuItems = { context.coordinator.shortcutMenuItems(at: $0) }
        context.coordinator.observeLayout(of: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let wasFocused = coordinator.parent.isFocused
        let wasRemote = coordinator.parent.isRemote
        coordinator.parent = self
        guard let view = coordinator.textView else { return }
        if wasRemote != isRemote { coordinator.environmentChanged() }
        if view.string != text {
            view.string = text
            view.moveToEndOfDocument(nil)
            completion.close()
            coordinator.afterEdit()
        }
        view.isEditable = isEnabled
        if !isEnabled { completion.close() }
        if isFocused, !wasFocused || !coordinator.didFocus || view.window?.firstResponder === view.window {
            coordinator.attached()
        }
        coordinator.refreshTags()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.parent.completion.close()
        coordinator.removeTags()
        coordinator.reportTags(false)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let view = nsView.documentView as? NSTextView,
              let layout = view.layoutManager,
              let container = view.textContainer
        else { return nil }
        let width = proposal.width ?? 400
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = TerminalMetrics.lineHeight
        let used = layout.usedRect(for: container).height
        let height = min(max(used, line), line * Self.maxLines)
        return CGSize(width: width, height: ceil(height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private enum Mode {
            case tab
            case refresh
            case auto
            case cycle(Int)
        }

        private struct Candidates {
            let text: String
            let range: NSRange
            let items: [CompletionItem]
        }

        var parent: InputEditor
        weak var textView: EditorTextView?
        var didFocus = false
        private var historyIndex: Int?
        private var stash = ""
        private var generation = 0
        private var completionRange = NSRange(location: 0, length: 0)
        private var latest: Candidates?
        private var pinned: String?
        private var ghostItem: (item: CompletionItem, range: NSRange)?
        private var autoTask: Task<Void, Never>?
        private var suppressAuto = false
        private var showsTags = false
        private var browsing = false
        private var isBrowsing: Bool { browsing && parent.completion.isOpen }
        private static let historyRows = 100
        private let tags = ShortcutTagLayer()
        private let shellKind = ShellIntegration.userKind
        private var shortcutPopover: NSPopover?
        private weak var observedWindow: NSWindow?
        private var environment: CompletionEnvironment {
            parent.isRemote
                ? RemoteCompletionEnvironment(base: SystemCompletionEnvironment.shared, channel: parent.remoteChannel)
                : SystemCompletionEnvironment.shared
        }

        init(_ parent: InputEditor) {
            self.parent = parent
            super.init()
            parent.completion.onAccept = { [weak self] in self?.accept($0) }
            parent.completion.onPresentation = { [weak self] in self?.refreshTags() }
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged), name: .completionEnvironmentChanged, object: nil
            )
        }

        @objc func environmentChanged() {
            restyle()
            refreshTags()
        }

        func observeLayout(of scroll: NSScrollView) {
            let center = NotificationCenter.default
            scroll.postsFrameChangedNotifications = true
            scroll.contentView.postsBoundsChangedNotifications = true
            textView?.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: scroll)
            center.addObserver(self, selector: #selector(layoutChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            center.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: textView)
        }

        @objc private func layoutChanged() {
            refreshTags()
        }

        func refreshTags() {
            guard let view = textView else { return }
            if let window = view.window, window !== observedWindow {
                let center = NotificationCenter.default
                if let old = observedWindow { center.removeObserver(self, name: NSWindow.didResizeNotification, object: old) }
                center.addObserver(self, selector: #selector(layoutChanged), name: NSWindow.didResizeNotification, object: window)
                observedWindow = window
            }
            let kind = shellKind
            let selection = view.selectedRange()
            let shown = tags.update(
                in: view,
                shortcuts: ShortcutStore.shared.effective(in: parent.directory),
                quote: { ShellIntegration.quoted($0, for: kind) },
                visible: parent.isEnabled && !parent.completion.isOpen,
                caret: selection.length == 0 ? selection.location : nil,
                select: { [weak self] in self?.selectShortcut($0) },
                expand: { [weak self] in self?.expandShortcut($0, with: $1) },
                save: { [weak self] in self?.offerShortcut($0, near: $1) }
            )
            reportTags(shown)
        }

        func reportTags(_ shown: Bool) {
            guard shown != showsTags else { return }
            showsTags = shown
            let report = parent.onTags
            DispatchQueue.main.async { report(shown) }
        }

        private func offerShortcut(_ key: String, near range: NSRange) {
            let directory = parent.directory
            let match = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.first { name in
                var isDirectory: ObjCBool = false
                let path = (directory as NSString).appendingPathComponent(name)
                return name.caseInsensitiveCompare(key) == .orderedSame
                    && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            let value = match.map { (directory as NSString).appendingPathComponent($0) } ?? directory
            presentShortcutEditor(Shortcut(kind: .directory, key: key, name: "", value: value), near: range)
        }

        private func expandShortcut(_ range: NSRange, with text: String) {
            guard let view = textView, NSMaxRange(range) <= (view.string as NSString).length else { return }
            autoTask?.cancel()
            parent.completion.close()
            view.window?.makeFirstResponder(view)
            suppressAuto = true
            view.insertText(text, replacementRange: range)
            suppressAuto = false
        }

        func shortcutMenuItems(at point: NSPoint) -> [NSMenuItem] {
            guard let view = textView, !view.string.isEmpty else { return [] }
            let text = view.string
            let index = view.characterIndexForInsertion(at: point)
            let store = ShortcutStore.shared
            for match in Shortcuts.scan(text, in: store.items) {
                let range = NSRange(match.range, in: text)
                guard index >= range.location, index <= NSMaxRange(range) else { continue }
                return [ActionMenuItem(title: "Edit \(match.shortcut.token) Shortcut...") { [weak self] in
                    self?.presentShortcutEditor(match.shortcut, near: range)
                }]
            }
            let masked = Shortcuts.masked(text, matches: Shortcuts.scan(text, in: store.effective(in: parent.directory)))
            for token in ShellTokenizer.tokenize(masked) where token.kind == .word {
                let range = NSRange(token.range, in: masked)
                guard index >= range.location, index <= NSMaxRange(range) else { continue }
                let path = resolvedPath(token.value)
                var isDirectory: ObjCBool = false
                guard !token.value.isEmpty, !token.value.hasPrefix("-"),
                      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                else { return [] }
                let kind: ShortcutKind = isDirectory.boolValue ? .directory : .file
                if let existing = store.items.first(where: { $0.kind == kind && $0.value == path }) {
                    return [ActionMenuItem(title: "Edit \(existing.token) Shortcut...") { [weak self] in
                        self?.presentShortcutEditor(existing, near: range)
                    }]
                }
                let name = (path as NSString).lastPathComponent
                let draft = kind == .directory
                    ? Shortcut(kind: .directory, key: Shortcuts.sanitize(name).lowercased(), name: name, value: path)
                    : Shortcut(kind: .file, key: Shortcuts.sanitize((name as NSString).deletingPathExtension).lowercased(), name: "", value: path)
                return [ActionMenuItem(title: "Save as \(kind.title) Shortcut...") { [weak self] in
                    self?.presentShortcutEditor(draft, near: range)
                }]
            }
            return []
        }

        private func resolvedPath(_ value: String) -> String {
            let home = NSHomeDirectory()
            let absolute: String
            if value == "~" {
                absolute = home
            } else if value.hasPrefix("~/") {
                absolute = home + value.dropFirst()
            } else if value.hasPrefix("/") {
                absolute = value
            } else {
                absolute = (parent.directory as NSString).appendingPathComponent(value)
            }
            return URL(fileURLWithPath: absolute).standardizedFileURL.path
        }

        private func presentShortcutEditor(_ shortcut: Shortcut, near range: NSRange) {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            let content = ShortcutEditor(shortcut) { [weak popover] in popover?.performClose(nil) }
            popover.contentViewController = NSHostingController(rootView: content)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            shortcutPopover = popover
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }

        func removeTags() {
            tags.clear()
        }

        private func selectShortcut(_ range: NSRange) {
            guard let view = textView, NSMaxRange(range) <= (view.string as NSString).length else { return }
            parent.completion.close()
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
        }

        func attached() {
            guard parent.isFocused else { return }
            DispatchQueue.main.async { [weak self] in
                guard let view = self?.textView, let window = view.window else { return }
                if window.firstResponder !== view { window.makeFirstResponder(view) }
                self?.didFocus = true
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            parent.text = view.string
            historyIndex = nil
            endBrowsing()
            afterEdit()
            scheduleCompletion(in: view)
        }

        private func scheduleCompletion(in view: EditorTextView) {
            autoTask?.cancel()
            let completion = parent.completion
            if suppressAuto {
                completion.close()
                return
            }
            if completion.isOpen, completion.engaged {
                request(.refresh)
                return
            }
            let text = view.string
            let selection = view.selectedRange()
            guard parent.isEnabled, selection.length == 0, !view.hasMarkedText(), AutoTrigger.eligible(text) else {
                completion.close()
                return
            }
            autoTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.request(.auto)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateGhost()
            refreshTags()
        }

        func afterEdit() {
            restyle()
            updateGhost()
            refreshTags()
        }

        func control(_ key: Character) {
            guard let view = textView else { return }
            switch key {
            case "c":
                set("")
            case "l":
                parent.onClear()
            case "d":
                if view.string.isEmpty {
                    set("exit")
                    parent.onSubmit()
                }
            default:
                break
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let completion = parent.completion
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    endBrowsing()
                    completion.close()
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if isBrowsing, parent.isEnabled {
                    endBrowsing()
                    parent.onSubmit()
                } else if completion.consumesEnter {
                    accept(completion.selected)
                } else if parent.isEnabled, !CommandCompleteness.isComplete(textView.string, fish: shellKind == .fish) {
                    completion.close()
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if parent.isEnabled {
                    autoTask?.cancel()
                    completion.close()
                    historyIndex = nil
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                if isBrowsing {
                    browse(by: -1)
                    return true
                }
                if completion.isOpen {
                    completion.move(by: -1)
                    updateGhost()
                    return true
                }
                guard onFirstLine(textView) else { return false }
                if textView.string.isEmpty { browseHistory() } else if canCycle(textView) { cycle(-1) } else { recall(older: true) }
                return true
            case #selector(NSResponder.moveDown(_:)):
                if isBrowsing {
                    browse(by: 1)
                    return true
                }
                if completion.isOpen {
                    completion.move(by: 1)
                    updateGhost()
                    return true
                }
                guard onLastLine(textView) else { return false }
                if canCycle(textView) { cycle(1) } else { recall(older: false) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                tab()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                guard completion.isOpen else { return false }
                completion.move(by: -1)
                updateGhost()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if isBrowsing {
                    endBrowsing()
                    set("")
                } else if completion.isOpen {
                    completion.close()
                    updateGhost()
                } else {
                    set("")
                }
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
                if acceptChosenItem() || acceptGhost(wordOnly: false) { return true }
                completion.close()
                return false
            case #selector(NSResponder.moveWordRight(_:)):
                if acceptGhost(wordOnly: true) { return true }
                completion.close()
                return false
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)),
                 #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)),
                 #selector(NSResponder.moveToEndOfLine(_:)):
                completion.close()
                return false
            default:
                return false
            }
        }

        private func set(_ value: String) {
            autoTask?.cancel()
            browsing = false
            parent.completion.close()
            textView?.string = value
            textView?.moveToEndOfDocument(nil)
            parent.text = value
            afterEdit()
        }

        private func canCycle(_ view: NSTextView) -> Bool {
            let text = view.string
            let selection = view.selectedRange()
            return parent.isEnabled && historyIndex == nil && !text.isEmpty && !view.hasMarkedText()
                && selection.length == 0 && selection.location == (text as NSString).length
        }

        private func cycle(_ step: Int) {
            guard let view = textView else { return }
            let text = view.string
            if let latest, latest.text == text,
               latest.items.contains(where: { SuggestionList.ghost(for: $0, typed: typed(in: latest.range, of: text)) != nil }) {
                present(latest, step: step)
            } else {
                request(.cycle(step))
            }
        }

        private func present(_ candidates: Candidates, step: Int) {
            completionRange = candidates.range
            parent.completion.show(candidates.items, engaged: false)
            updateGhost()
            parent.completion.move(by: step)
            updateGhost()
        }

        private func browseHistory() {
            guard parent.isEnabled else { return }
            let entries = Array(parent.history.entries.suffix(Self.historyRows))
            guard !entries.isEmpty else { return }
            autoTask?.cancel()
            browsing = true
            parent.completion.show(entries.map { CompletionItem(insert: $0, kind: .history, terminator: "") }, engaged: true)
            parent.completion.selected = entries.count - 1
            fill(entries[entries.count - 1])
        }

        private func browse(by step: Int) {
            let completion = parent.completion
            let target = completion.selected + step
            if target >= completion.items.count {
                endBrowsing()
                set("")
                return
            }
            completion.selected = max(target, 0)
            fill(completion.items[completion.selected].insert)
        }

        private func fill(_ value: String) {
            guard let view = textView else { return }
            view.string = value
            view.moveToEndOfDocument(nil)
            parent.text = value
            completionRange = NSRange(location: 0, length: (value as NSString).length)
            afterEdit()
        }

        func dismissPopup() {
            browsing = false
            parent.completion.close()
        }

        private func endBrowsing() {
            guard browsing else { return }
            browsing = false
            parent.completion.close()
        }

        private func tab() {
            guard let view = textView else { return }
            browsing = false
            let completion = parent.completion
            if acceptChosenItem() { return }
            if let chosen = ghostItem {
                completionRange = chosen.range
                accept(item: chosen.item)
                return
            }
            guard !view.ghost.isEmpty else {
                request(.tab)
                return
            }
            let text = view.string
            let step = GhostStep.next(text: text, ghost: view.ghost, directory: parent.directory, env: environment)
            pinned = text + view.ghost
            autoTask?.cancel()
            completion.close()
            suppressAuto = true
            view.insertText(step, replacementRange: NSRange(location: (text as NSString).length, length: 0))
            suppressAuto = false
        }

        private func acceptChosenItem() -> Bool {
            let completion = parent.completion
            guard completion.isOpen, completion.engaged, completion.items.indices.contains(completion.selected),
                  completion.items[completion.selected].kind != .history,
                  let view = textView, view.selectedRange().location == (view.string as NSString).length
            else { return false }
            accept(completion.selected)
            return true
        }

        private func typed(in range: NSRange, of text: String) -> String {
            let string = text as NSString
            guard NSMaxRange(range) <= string.length else { return "" }
            return string.substring(with: range)
        }

        private func acceptGhost(wordOnly: Bool) -> Bool {
            guard let view = textView, !view.ghost.isEmpty else { return false }
            if !wordOnly, let chosen = ghostItem {
                completionRange = chosen.range
                accept(item: chosen.item)
                return true
            }
            let ghost = wordOnly ? Self.firstWord(of: view.ghost) : view.ghost
            view.insertText(ghost, replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
            return true
        }

        static func firstWord(of text: String) -> String {
            var result = ""
            var seenWord = false
            for character in text {
                if character.isWhitespace {
                    if seenWord { break }
                } else {
                    seenWord = true
                }
                result.append(character)
            }
            return result
        }

        private func updateGhost() {
            guard let view = textView else { return }
            let text = view.string
            let length = (text as NSString).length
            let selection = view.selectedRange()
            let completion = parent.completion
            if let line = pinned, text.isEmpty || line.count <= text.count || !line.hasPrefix(text) { pinned = nil }
            var ghost = ""
            ghostItem = nil
            if parent.isEnabled, !text.isEmpty, selection.length == 0, !view.hasMarkedText(), selection.location == length {
                if completion.isOpen, completion.engaged {
                    if completion.items.indices.contains(completion.selected), NSMaxRange(completionRange) == length {
                        let item = completion.items[completion.selected]
                        ghost = SuggestionList.ghost(for: item, typed: typed(in: completionRange, of: text)) ?? ""
                    }
                } else if let line = pinned {
                    ghost = String(line.dropFirst(text.count))
                } else if let suggestion = CommandHistory.shared.suggestion(for: text) {
                    ghost = suggestion
                } else if let latest, latest.text == text, NSMaxRange(latest.range) == length,
                          let item = SuggestionList.sole(latest.items),
                          let suffix = SuggestionList.ghost(for: item, typed: typed(in: latest.range, of: text)) {
                    ghost = suffix
                    ghostItem = (item, latest.range)
                }
            }
            view.ghost = ghost
            var hinted = false
            if completion.isOpen, !completion.engaged, !ghost.isEmpty, let first = completion.items.first {
                hinted = SuggestionList.ghost(for: first, typed: typed(in: completionRange, of: text)) == ghost
            }
            if completion.hinted != hinted { completion.hinted = hinted }
        }

        private func restyle() {
            guard let view = textView, !view.hasMarkedText(), let storage = view.textStorage else { return }
            let spans = SyntaxHighlighter.spans(for: view.string, directory: parent.directory, environment: environment)
            view.typingAttributes = HighlightStyle.apply(spans, to: storage)
        }

        private func request(_ mode: Mode) {
            guard let view = textView else { return }
            let text = view.string
            let selection = view.selectedRange()
            guard selection.length == 0, let range = Range(selection, in: text) else {
                parent.completion.close()
                return
            }
            let cursor = range.lowerBound
            let directory = parent.directory
            let history = CommandHistory.shared.entries
            let env = environment
            let cycling: Bool
            if case .cycle = mode { cycling = true } else { cycling = false }
            generation += 1
            let ticket = generation
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    let found = CommandCompleter.complete(
                        line: text, cursor: cursor, directory: directory, history: history, environment: env
                    )
                    guard cycling, !SuggestionList.extends(found, line: text) else { return found }
                    return CommandCompleter.siblings(line: text, cursor: cursor, directory: directory, environment: env) ?? found
                }.value
                guard let self, ticket == self.generation else { return }
                self.apply(result, mode: mode, text: text)
            }
        }

        private func apply(_ result: CompletionResult?, mode: Mode, text: String) {
            guard let view = textView, view.string == text else { return }
            let completion = parent.completion
            let merged = SuggestionList.merge(
                text: text,
                range: result.map { NSRange($0.range, in: text) },
                items: result?.items ?? [],
                history: CommandHistory.shared.entries
            )
            let candidates = Candidates(text: text, range: merged.range, items: merged.items)
            latest = candidates
            if case .cycle(let step) = mode {
                if candidates.items.isEmpty {
                    completion.close()
                    recall(older: step < 0)
                } else {
                    present(candidates, step: step)
                }
                return
            }
            guard let result, !result.items.isEmpty else {
                completion.close()
                updateGhost()
                return
            }
            var range = NSRange(result.range, in: text)
            switch mode {
            case .refresh:
                completionRange = candidates.range
                completion.show(candidates.items, engaged: completion.engaged)
            case .auto:
                completion.close()
            case .cycle:
                break
            case .tab:
                if result.items.count == 1 {
                    completionRange = range
                    accept(item: result.items[0])
                    return
                }
                let common = CommandCompleter.commonPrefix(of: result.items)
                let typed = (text as NSString).substring(with: range)
                if common.count > typed.count, common.lowercased().hasPrefix(typed.lowercased()) {
                    suppressAuto = true
                    view.insertText(common, replacementRange: range)
                    suppressAuto = false
                    range = NSRange(location: range.location, length: (common as NSString).length)
                }
                completionRange = range
                completion.show(result.items, engaged: true)
            }
            updateGhost()
        }

        func accept(_ index: Int) {
            let items = parent.completion.items
            guard items.indices.contains(index) else { return }
            if isBrowsing {
                endBrowsing()
                fill(items[index].insert)
                textView?.window?.makeFirstResponder(textView)
                return
            }
            accept(item: items[index])
        }

        private func accept(item: CompletionItem) {
            guard let view = textView else { return }
            parent.completion.close()
            guard NSMaxRange(completionRange) <= (view.string as NSString).length else { return }
            autoTask?.cancel()
            suppressAuto = true
            view.insertText(item.insert + item.terminator, replacementRange: completionRange)
            suppressAuto = false
            view.window?.makeFirstResponder(view)
        }

        private func recall(older: Bool) {
            let entries = parent.history.entries
            if older {
                guard !entries.isEmpty else { return }
                if historyIndex == nil {
                    stash = textView?.string ?? ""
                    historyIndex = entries.count - 1
                } else if let index = historyIndex, index > 0 {
                    historyIndex = index - 1
                }
                if let index = historyIndex { set(entries[index]) }
            } else {
                guard let index = historyIndex else { return }
                if index + 1 < entries.count {
                    historyIndex = index + 1
                    set(entries[index + 1])
                } else {
                    historyIndex = nil
                    set(stash)
                }
            }
        }

        private func onFirstLine(_ view: NSTextView) -> Bool {
            let location = view.selectedRange().location
            let text = view.string as NSString
            return text.substring(to: min(location, text.length)).contains("\n") == false
        }

        private func onLastLine(_ view: NSTextView) -> Bool {
            let location = view.selectedRange().location
            let text = view.string as NSString
            return text.substring(from: min(location, text.length)).contains("\n") == false
        }
    }
}

enum HighlightStyle {
    static var base: [NSAttributedString.Key: Any] {
        [.font: TerminalMetrics.font, .foregroundColor: Theme.text.dynamicNS]
    }

    @discardableResult
    static func apply(_ spans: [HighlightSpan], to storage: NSTextStorage) -> [NSAttributedString.Key: Any] {
        let base = base
        storage.beginEditing()
        storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
        for span in spans where NSMaxRange(span.range) <= storage.length {
            switch span.kind {
            case .existingPath:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .error:
                let color = Theme.syntaxError.dynamicNS
                storage.addAttributes(
                    [.foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: color],
                    range: span.range
                )
            default:
                if let color = span.kind.themeColor {
                    storage.addAttribute(.foregroundColor, value: color.dynamicNS, range: span.range)
                }
            }
        }
        storage.endEditing()
        return base
    }
}

private extension HighlightKind {
    var themeColor: ThemeColor? {
        switch self {
        case .command: return Theme.syntaxCommand
        case .builtin: return Theme.syntaxBuiltin
        case .alias, .function: return Theme.syntaxFunction
        case .keyword: return Theme.syntaxKeyword
        case .unknownCommand, .error: return Theme.syntaxError
        case .flag: return Theme.syntaxFlag
        case .string: return Theme.syntaxString
        case .variable: return Theme.syntaxVariable
        case .op, .redirect: return Theme.syntaxOperator
        case .comment: return Theme.syntaxComment
        case .group: return Theme.syntaxGroup
        case .existingPath: return nil
        }
    }
}

final class EditorTextView: NSTextView {
    var onFocus: () -> Void = {}
    var onControl: (Character) -> Void = { _ in }
    var onAttach: () -> Void = {}
    var onFiles: ([URL]) -> Void = { _ in }
    var onDragTarget: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onSelectAllBlocks: () -> Void = {}
    var extraMenuItems: (NSPoint) -> [NSMenuItem] = { _ in [] }
    var ghost = "" {
        didSet { if ghost != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !ghost.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? TerminalMetrics.font,
            .foregroundColor: Theme.inputGhost.dynamicNS,
        ]
        (ghost as NSString).draw(at: caretOrigin(layout, container), withAttributes: attributes)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let items = extraMenuItems(convert(event.locationInWindow, from: nil))
        guard !items.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    override func selectAll(_ sender: Any?) {
        if string.isEmpty { onSelectAllBlocks() } else { super.selectAll(sender) }
    }

    private func caretOrigin(_ layout: NSLayoutManager, _ container: NSTextContainer) -> NSPoint {
        let origin = textContainerOrigin
        let length = (string as NSString).length
        if length == 0 || string.hasSuffix("\n") {
            let extra = layout.extraLineFragmentRect
            return NSPoint(x: origin.x + extra.minX + container.lineFragmentPadding, y: origin.y + extra.minY)
        }
        let glyph = layout.glyphIndexForCharacter(at: length - 1)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSPoint(x: origin.x + rect.maxX, y: origin.y + rect.minY)
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let urls = AttachmentStore.urls(from: .general, imageOverridesText: false)
        if urls.isEmpty {
            super.paste(sender)
        } else {
            onFiles(urls)
        }
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes(newTypes + AttachmentStore.dragTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard AttachmentStore.canAccept(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        onDragTarget(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        AttachmentStore.canAccept(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTarget(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        AttachmentStore.canAccept(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragTarget(false)
        let urls = AttachmentStore.urls(from: sender.draggingPasteboard, imageOverridesText: true)
        if urls.isEmpty { return super.performDragOperation(sender) }
        onFiles(urls)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([])
        if window != nil { onAttach() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .command, .option, .shift])
        if flags == .control, let key = event.charactersIgnoringModifiers?.lowercased().first, "cld".contains(key) {
            onControl(key)
            return
        }
        super.keyDown(with: event)
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
