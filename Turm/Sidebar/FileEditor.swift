import AppKit
import AVKit
import SwiftUI
import TurmCore
import UniformTypeIdentifiers

struct ViewerPaneView: View {
    let workspace: Workspace
    let pane: PaneID
    let viewer: ViewerPane

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    workspace.close(pane)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText.color)
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.sidebar.color)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground.color)
        .clipped()
    }

    private var title: String {
        switch viewer {
        case .diff(_, let staged): staged ? "Staged diff" : "Diff"
        case .file(let path), .remoteFile(_, let path): (path as NSString).lastPathComponent
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewer {
        case .diff(let shell, let staged):
            if let session = workspace.session(for: shell) {
                GitDiffPanel(session: session, staged: staged, embedded: true)
            } else {
                Text("The shell for this diff was closed.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file(let path):
            FileEditor(path: path)
        case .remoteFile(let shell, let path):
            if let session = workspace.session(for: shell) {
                RemoteFileEditor(session: session, path: path)
            } else {
                Text("The shell for this file was closed.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct FileEditor: View {
    let path: String
    @State private var text = ""
    @State private var saved = ""
    @State private var notice: String?
    @State private var image: NSImage?
    @State private var videoURL: URL?
    @State private var loaded = false

    private var language: SourceLanguage { SourceLanguage.detect(path) }
    private var dirty: Bool { loaded && image == nil && videoURL == nil && text != saved }
    private var showsEditorChrome: Bool { image == nil && videoURL == nil && notice == nil }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay { AnimatedImage(image: image).padding(16) }
                        .clipped()
                } else if let videoURL {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay { VideoPreview(url: videoURL) }
                        .clipped()
                } else if let notice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(16)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            SourceEditor(text: $text, language: language, onSave: save)
                        }
                        .clipped()
                }
            }
            if showsEditorChrome {
                HStack {
                    Text(dirty ? "Edited" : "Saved")
                        .foregroundStyle(dirty ? Theme.syntaxFlag.color : Theme.secondaryText.color)
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .disabled(!dirty)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.sidebar.color)
            }
        }
        .task { load() }
    }

    private func load() {
        let url = URL(fileURLWithPath: path)
        switch Self.mediaKind(path) {
        case .image:
            if let image = NSImage(contentsOf: url), image.isValid {
                self.image = image
            } else {
                loadText(url)
                return
            }
        case .video:
            videoURL = url
        case .text:
            loadText(url)
            return
        }
        loaded = true
    }

    private func loadText(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000, !data.contains(0) else {
            notice = dataNotice(url)
            loaded = true
            return
        }
        let contents = String(decoding: data, as: UTF8.self)
        text = contents
        saved = contents
        loaded = true
    }

    enum MediaKind {
        case text, image, video
    }

    static func mediaKind(_ path: String) -> MediaKind {
        let ext = (path as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return .text }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) { return .video }
        return .text
    }

    private func dataNotice(_ url: URL) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        if data.contains(0) { return "This file isn’t text." }
        if data.count > 1_000_000 { return "This file is too large to open here." }
        return "Could not read this file."
    }

    private func save() {
        guard dirty else { return }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            saved = text
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }
}

private struct RemoteFileEditor: View {
    let session: TerminalSession
    let path: String
    @State private var text = ""
    @State private var saved = ""
    @State private var notice: String?
    @State private var loaded = false
    @State private var image: NSImage?
    @State private var videoURL: URL?

    private var language: SourceLanguage { SourceLanguage.detect(path) }
    private var dirty: Bool { loaded && image == nil && videoURL == nil && text != saved }
    private var showsText: Bool { loaded && image == nil && videoURL == nil && notice == nil }

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { AnimatedImage(image: image).padding(16) }
                    .clipped()
            } else if let videoURL {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { VideoPreview(url: videoURL) }
                    .clipped()
            } else if let notice, !loaded {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else if showsText {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        SourceEditor(text: $text, language: language, onSave: save)
                    }
                    .clipped()
                HStack {
                    Text(dirty ? "Edited" : "Saved")
                        .foregroundStyle(dirty ? Theme.syntaxFlag.color : Theme.secondaryText.color)
                    if let notice {
                        Text(notice)
                            .lineLimit(1)
                            .foregroundStyle(Theme.removed.color)
                    }
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .disabled(!dirty)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.sidebar.color)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .onDisappear {
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        }
    }

    private func load() async {
        guard let channel = session.remoteChannel else {
            notice = "The remote shell is not connected."
            return
        }
        let path = path
        switch Self.mediaKind(path) {
        case .image:
            let outcome = await Task.detached { channel.readFileData(path) }.value
            switch outcome {
            case .data(let data):
                if let image = NSImage(data: data), image.isValid {
                    self.image = image
                    loaded = true
                } else {
                    notice = "Could not preview this image."
                }
            case .failure(let message):
                notice = message
            case .text:
                notice = "Could not preview this image."
            }
        case .video:
            let outcome = await Task.detached { channel.readFileData(path) }.value
            switch outcome {
            case .data(let data):
                let ext = (path as NSString).pathExtension
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
                do {
                    try data.write(to: file)
                    videoURL = file
                    loaded = true
                } catch {
                    notice = "Could not preview this video."
                }
            case .failure(let message):
                notice = message
            case .text:
                notice = "Could not preview this video."
            }
        case .text:
            let outcome = await Task.detached { channel.readFileText(path) }.value
            switch outcome {
            case .text(let value):
                text = value
                saved = value
                loaded = true
            case .failure(let message):
                notice = message
            case .data:
                notice = "This file isn’t text."
            }
        }
    }

    private static func mediaKind(_ path: String) -> FileEditor.MediaKind {
        FileEditor.mediaKind(path)
    }

    private func save() {
        guard dirty, let channel = session.remoteChannel else { return }
        let path = path
        let text = text
        Task {
            let failure = await Task.detached { channel.writeFileText(path, text: text) }.value
            if let failure {
                notice = failure
            } else {
                saved = text
                notice = nil
            }
        }
    }
}

private struct AnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.image = image
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
        view.animates = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 1, height: 1) }
        let widthLimit = proposal.width.map { $0.isFinite ? $0 : imageSize.width } ?? imageSize.width
        let heightLimit = proposal.height.map { $0.isFinite ? $0 : imageSize.height } ?? imageSize.height
        let scale = min(widthLimit / imageSize.width, heightLimit / imageSize.height, 1)
        return CGSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }
}

private struct VideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

enum SourceLanguage {
    case plain, python, javascript, swift, go, shell, json

    static func detect(_ path: String) -> SourceLanguage {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "pyi": .python
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": .javascript
        case "swift": .swift
        case "go": .go
        case "sh", "bash", "zsh": .shell
        case "json": .json
        default: .plain
        }
    }

    var keywords: Set<String> {
        switch self {
        case .python:
            ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except", "finally", "lambda", "pass", "break", "continue", "yield", "async", "await", "True", "False", "None", "and", "or", "not", "in", "is"]
        case .javascript:
            ["function", "const", "let", "var", "if", "else", "for", "while", "return", "import", "export", "class", "extends", "async", "await", "new", "this", "true", "false", "null", "undefined"]
        case .swift:
            ["func", "class", "struct", "enum", "if", "else", "guard", "let", "var", "return", "import", "protocol", "extension", "switch", "case", "true", "false", "nil", "async", "await"]
        case .go:
            ["func", "package", "import", "if", "else", "for", "return", "var", "const", "type", "struct", "interface", "switch", "case", "true", "false", "nil"]
        case .shell:
            ["if", "then", "else", "fi", "for", "while", "do", "done", "case", "esac", "function", "in"]
        case .json, .plain:
            []
        }
    }

    var comment: String? {
        switch self {
        case .python, .shell: "#"
        case .javascript, .swift, .go: "//"
        case .json, .plain: nil
        }
    }
}

struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    let language: SourceLanguage
    let onSave: () -> Void

    func makeNSView(context: Context) -> SourceHost {
        let textView = EditingTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        textView.onSave = onSave
        let host = SourceHost(textView: textView)
        context.coordinator.host = host
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.drawsBackground = true
        textView.backgroundColor = Theme.terminalBackground.resolved(dark: dark)
        textView.insertionPointColor = Theme.text.resolved(dark: dark)
        textView.string = text
        context.coordinator.view = textView
        context.coordinator.apply(text, language: language)
        host.noteTextChanged()
        return host
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SourceHost, context: Context) -> CGSize? {
        let width = proposal.width ?? 0
        let height = proposal.height ?? 0
        guard width.isFinite, height.isFinite else { return CGSize(width: 1, height: 1) }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    func updateNSView(_ host: SourceHost, context: Context) {
        let textView = host.textView
        textView.onSave = onSave
        textView.backgroundColor = Theme.terminalBackground.resolved(dark: dark)
        host.gutter.needsDisplay = true
        if textView.string != text, host.window?.firstResponder !== textView {
            textView.string = text
            context.coordinator.apply(text, language: language)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language, onSave: onSave)
    }

    private var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let language: SourceLanguage
        let onSave: () -> Void
        weak var view: NSTextView?
        weak var host: SourceHost?
        private var highlighting = false

        init(text: Binding<String>, language: SourceLanguage, onSave: @escaping () -> Void) {
            _text = text
            self.language = language
            self.onSave = onSave
        }

        func textDidChange(_ notification: Notification) {
            guard let view, !highlighting else { return }
            text = view.string
            apply(view.string, language: language)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            host?.gutter.needsDisplay = true
        }

        func apply(_ string: String, language: SourceLanguage) {
            guard let view, let storage = view.textStorage else { return }
            highlighting = true
            let selected = view.selectedRanges
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let full = NSRange(location: 0, length: (string as NSString).length)
            storage.setAttributes([
                .font: font,
                .foregroundColor: Theme.text.resolved(dark: dark),
            ], range: full)
            SourceColoring.paint(string, language: language, dark: dark, storage: storage)
            view.selectedRanges = selected
            highlighting = false
            host?.noteTextChanged()
        }
    }
}

final class SourceHost: NSView {
    let textView: EditingTextView
    let gutter: LineNumberGutter
    let scroll = NSScrollView()
    private var positioning = false

    init(textView: EditingTextView) {
        self.textView = textView
        gutter = LineNumberGutter(textView: textView)
        super.init(frame: .zero)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(gutter)
        addSubview(scroll)
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func noteTextChanged() {
        if gutter.noteTextChanged() { needsLayout = true }
    }

    @objc private func scrolled() {
        gutter.needsDisplay = true
    }

    override func layout() {
        super.layout()
        positionChildren()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        positionChildren()
    }

    private func positionChildren() {
        guard !positioning else { return }
        positioning = true
        defer { positioning = false }
        let gutterWidth = gutter.thickness
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scroll.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
        let contentWidth = scroll.contentSize.width
        guard contentWidth > 1 else { return }
        var frame = textView.frame
        guard abs(frame.width - contentWidth) > 0.5 else { return }
        frame.size.width = contentWidth
        textView.frame = frame
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
    }
}

final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var thickness: CGFloat = 36

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func noteTextChanged() -> Bool {
        guard let textView else { return false }
        let lines = max(1, textView.string.components(separatedBy: "\n").count)
        let digits = max(2, String(lines).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: numberFont]).width
        let needed = ceil(width) + 18
        let changed = thickness != needed
        if changed { thickness = needed }
        needsDisplay = true
        return changed
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Theme.terminalBackground.resolved(dark: dark).setFill()
        dirtyRect.fill()
        drawNumbers(in: textView, dark: dark)
        Theme.divider.resolved(dark: dark).setFill()
        NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    private func drawNumbers(in textView: NSTextView, dark: Bool) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let regular = Theme.secondaryText.resolved(dark: dark)
        let active = Theme.text.resolved(dark: dark)
        let current = currentLine(in: textView, text: text)

        if text.length == 0 {
            paint(1, y: textView.textContainerOrigin.y, height: numberFont.ascender - numberFont.descender, current: true, active: active, regular: regular, textView: textView)
            return
        }

        let visible = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = text.lineRange(for: NSRange(location: min(chars.location, text.length - 1), length: 0)).location
        var line = lineNumber(at: index, in: text)
        let end = NSMaxRange(chars)

        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            fragment.origin.y += textView.textContainerOrigin.y
            paint(line, y: fragment.origin.y, height: fragment.height, current: line == current, active: active, regular: regular, textView: textView)
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
            line += 1
            if index >= end { break }
        }

        if text.character(at: text.length - 1) == 10 {
            var extra = layoutManager.extraLineFragmentRect
            guard extra.height > 0 else { return }
            extra.origin.y += textView.textContainerOrigin.y
            paint(line, y: extra.origin.y, height: extra.height, current: line == current, active: active, regular: regular, textView: textView)
        }
    }

    private func paint(_ line: Int, y: CGFloat, height: CGFloat, current: Bool, active: NSColor, regular: NSColor, textView: NSTextView) {
        let label = "\(line)" as NSString
        let font = current ? NSFont.monospacedSystemFont(ofSize: 11, weight: .medium) : numberFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: current ? active : regular,
        ]
        let size = label.size(withAttributes: attributes)
        let point = convert(NSPoint(x: 0, y: y), from: textView)
        label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: point.y + (height - size.height) / 2), withAttributes: attributes)
    }

    private func lineNumber(at location: Int, in text: NSString) -> Int {
        guard location > 0 else { return 1 }
        var count = 1
        var search = NSRange(location: 0, length: min(location, text.length))
        while search.length > 0 {
            let found = text.range(of: "\n", options: [], range: search)
            if found.location == NSNotFound { break }
            count += 1
            let next = found.location + found.length
            search = NSRange(location: next, length: search.location + search.length - next)
        }
        return count
    }

    private func currentLine(in textView: NSTextView, text: NSString) -> Int {
        if text.length == 0 { return 1 }
        return lineNumber(at: min(textView.selectedRange().location, text.length), in: text)
    }
}

final class EditingTextView: NSTextView {
    var onSave: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            onSave()
            return
        }
        super.keyDown(with: event)
    }
}

enum SourceColoring {
    static func paint(_ text: String, language: SourceLanguage, dark: Bool, storage: NSTextStorage) {
        let ns = text as NSString
        func paint(_ range: NSRange, _ color: NSColor) {
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= ns.length else { return }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        if let mark = language.comment {
            let pattern = NSRegularExpression.escapedPattern(for: mark) + ".*$"
            if let expression = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) {
                for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    paint(match.range, Theme.syntaxComment.resolved(dark: dark))
                }
            }
        }
        if let strings = try? NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'") {
            for match in strings.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                paint(match.range, Theme.syntaxString.resolved(dark: dark))
            }
        }
        if let numbers = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b") {
            for match in numbers.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                paint(match.range, Theme.syntaxFlag.resolved(dark: dark))
            }
        }
        guard !language.keywords.isEmpty else { return }
        let words = language.keywords.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        guard let keywords = try? NSRegularExpression(pattern: "\\b(?:\(words))\\b") else { return }
        for match in keywords.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            paint(match.range, Theme.syntaxKeyword.resolved(dark: dark))
        }
    }
}
