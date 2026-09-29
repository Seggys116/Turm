import AppKit
import SwiftUI

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

    private static let maxLines: CGFloat = 8

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
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
        view.onClick = { context.coordinator.parent.completion.close() }
        view.onSelectAllBlocks = { context.coordinator.parent.onSelectAllBlocks() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let wasFocused = coordinator.parent.isFocused
        coordinator.parent = self
        guard let view = coordinator.textView else { return }
        if view.string != text {
            view.string = text
            view.moveToEndOfDocument(nil)
            completion.close()
            coordinator.afterEdit()
        }
        view.isEditable = isEnabled
        if !isEnabled { completion.close() }
        if completion.isOpen { coordinator.syncPopup() }
        if isFocused, !wasFocused || !coordinator.didFocus {
            coordinator.attached()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.parent.completion.close()
        coordinator.removePopup()
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
        }

        var parent: InputEditor
        weak var textView: EditorTextView?
        var didFocus = false
        private var historyIndex: Int?
        private var stash = ""
        private var generation = 0
        private var completionRange = NSRange(location: 0, length: 0)
        private var autoTask: Task<Void, Never>?
        private var suppressAuto = false
        private var popupHost: NSHostingView<CompletionPopup>?
        private let environment = SystemCompletionEnvironment.shared

        init(_ parent: InputEditor) {
            self.parent = parent
            super.init()
            parent.completion.onAccept = { [weak self] in self?.accept($0) }
            parent.completion.onPresentation = { [weak self] in self?.syncPopup() }
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged), name: .completionEnvironmentChanged, object: nil
            )
        }

        @objc private func environmentChanged() {
            restyle()
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

        func syncPopup() {
            let model = parent.completion
            guard model.isOpen, let view = textView, let window = view.window, let content = window.contentView,
                  let scroll = view.enclosingScrollView
            else {
                removePopup()
                return
            }
            let host: NSHostingView<CompletionPopup>
            if let existing = popupHost {
                host = existing
            } else {
                host = NSHostingView(rootView: CompletionPopup(model: model, width: 460))
                popupHost = host
            }
            let margin = CompletionPopup.margin
            let width = min(460, max(240, content.bounds.width - 16 - margin * 2))
            host.rootView = CompletionPopup(model: model, width: width)
            let height = CompletionPopup.height(forRows: model.items.count)
            let anchor = content.convert(scroll.bounds, from: scroll)
            var x = anchor.minX - margin
            x = max(4, min(x, content.bounds.width - width - margin * 2 - 4))
            var y: CGFloat
            if content.isFlipped {
                y = anchor.minY - height - margin * 2 - 4
                if y < 0 { y = anchor.maxY + 4 }
            } else {
                y = anchor.maxY + 4
                if y + height + margin * 2 > content.bounds.height { y = anchor.minY - height - margin * 2 - 4 }
            }
            host.frame = NSRect(x: x, y: y, width: width + margin * 2, height: height + margin * 2)
            if host.superview !== content { content.addSubview(host, positioned: .above, relativeTo: nil) }
        }

        func removePopup() {
            popupHost?.removeFromSuperview()
            popupHost = nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateGhost()
        }

        func afterEdit() {
            restyle()
            updateGhost()
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
                    completion.close()
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if completion.consumesEnter {
                    accept(completion.selected)
                } else if parent.isEnabled {
                    autoTask?.cancel()
                    completion.close()
                    historyIndex = nil
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                if completion.isOpen {
                    completion.move(by: -1)
                    return true
                }
                guard onFirstLine(textView) else { return false }
                recall(older: true)
                return true
            case #selector(NSResponder.moveDown(_:)):
                if completion.isOpen {
                    completion.move(by: 1)
                    return true
                }
                guard onLastLine(textView) else { return false }
                recall(older: false)
                return true
            case #selector(NSResponder.insertTab(_:)):
                if completion.isOpen {
                    completion.move(by: 1)
                } else {
                    request(.tab)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                guard completion.isOpen else { return false }
                completion.move(by: -1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if completion.isOpen {
                    completion.close()
                    updateGhost()
                } else {
                    set("")
                }
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
                if acceptGhost(wordOnly: false) { return true }
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
            parent.completion.close()
            textView?.string = value
            textView?.moveToEndOfDocument(nil)
            parent.text = value
            afterEdit()
        }

        private func acceptGhost(wordOnly: Bool) -> Bool {
            guard let view = textView, !view.ghost.isEmpty else { return false }
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
            let selection = view.selectedRange()
            var ghost = ""
            if !(parent.completion.isOpen && parent.completion.engaged), parent.isEnabled, selection.length == 0, !view.hasMarkedText(),
               selection.location == (text as NSString).length,
               let suggestion = CommandHistory.shared.suggestion(for: text) {
                ghost = suggestion
            }
            view.ghost = ghost
        }

        private func restyle() {
            guard let view = textView, !view.hasMarkedText(), let storage = view.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let base: [NSAttributedString.Key: Any] = [.font: TerminalMetrics.font, .foregroundColor: Theme.text.dynamicNS]
            let spans = SyntaxHighlighter.spans(for: view.string, directory: parent.directory, environment: environment)
            storage.beginEditing()
            storage.setAttributes(base, range: full)
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
            view.typingAttributes = base
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
            generation += 1
            let ticket = generation
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    CommandCompleter.complete(
                        line: text, cursor: cursor, directory: directory, history: history, environment: env
                    )
                }.value
                guard let self, ticket == self.generation else { return }
                self.apply(result, mode: mode, text: text)
            }
        }

        private func apply(_ result: CompletionResult?, mode: Mode, text: String) {
            guard let view = textView, view.string == text else { return }
            let completion = parent.completion
            guard let result, !result.items.isEmpty else {
                completion.close()
                updateGhost()
                return
            }
            var range = NSRange(result.range, in: text)
            switch mode {
            case .refresh:
                completionRange = range
                completion.show(result.items, engaged: completion.engaged)
            case .auto:
                if AutoTrigger.shouldShow(text: text, range: range, items: result.items) {
                    completionRange = range
                    completion.show(result.items, engaged: false)
                } else {
                    completion.close()
                }
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
            let entries = CommandHistory.shared.entries
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
