import AppKit
import Foundation
import Observation
import SwiftUI

struct SegmentHighlights: Equatable {
    var ranges: [NSRange]
    var active: NSRange?

    static let none = SegmentHighlights(ranges: [], active: nil)
}

nonisolated struct SearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var useRegex = false
}

nonisolated struct SearchDocument: Sendable {
    nonisolated struct Part: Sendable {
        let index: Int
        let text: String
    }

    let id: UUID
    let command: String
    let parts: [Part]
}

nonisolated struct SearchMatch: Equatable, Sendable {
    nonisolated enum Target: Hashable, Sendable {
        case command
        case segment(Int)
    }

    let blockID: UUID
    let target: Target
    let range: NSRange
    let position: Double

    func sameSpot(as other: SearchMatch) -> Bool {
        blockID == other.blockID && target == other.target && range == other.range
    }
}

nonisolated enum SearchOutcome: Sendable {
    case matches([SearchMatch], truncated: Bool)
    case invalid(String)
}

nonisolated enum SearchEngine {
    static let matchLimit = 100_000

    static func regex(query: String, options: SearchOptions) -> Result<NSRegularExpression, SearchFailure> {
        var pattern = options.useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            pattern = "(?<!\\w)(?:" + pattern + ")(?!\\w)"
        }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do {
            return .success(try NSRegularExpression(pattern: pattern, options: flags))
        } catch {
            return .failure(SearchFailure(message: error.localizedDescription))
        }
    }

    static func ranges(in text: String, regex: NSRegularExpression, limit: Int = matchLimit) -> [NSRange] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var found: [NSRange] = []
        regex.enumerateMatches(in: text, options: [], range: whole) { result, _, stop in
            if Task.isCancelled || found.count >= limit {
                stop.pointee = true
                return
            }
            guard let range = result?.range, range.length > 0 else { return }
            found.append(range)
        }
        return found
    }

    static func find(query: String, options: SearchOptions, in documents: [SearchDocument]) -> SearchOutcome {
        guard !query.isEmpty else { return .matches([], truncated: false) }
        let regex: NSRegularExpression
        switch Self.regex(query: query, options: options) {
        case .success(let built): regex = built
        case .failure(let failure): return .invalid(failure.message)
        }
        var matches: [SearchMatch] = []
        var truncated = false
        for document in documents {
            if Task.isCancelled || truncated { break }
            let commandLength = (document.command as NSString).length
            let total = Double(max(commandLength + document.parts.reduce(0) { $0 + ($1.text as NSString).length }, 1))
            let remaining = matchLimit - matches.count
            for range in ranges(in: document.command, regex: regex, limit: remaining) {
                matches.append(SearchMatch(blockID: document.id, target: .command, range: range, position: 0))
            }
            var offset = commandLength
            for part in document.parts {
                let room = matchLimit - matches.count
                if room <= 0 {
                    truncated = true
                    break
                }
                for range in ranges(in: part.text, regex: regex, limit: room) {
                    let position = Double(offset + range.location) / total
                    matches.append(SearchMatch(blockID: document.id, target: .segment(part.index), range: range, position: position))
                }
                offset += (part.text as NSString).length
            }
            if matches.count >= matchLimit { truncated = true }
        }
        return .matches(matches, truncated: truncated)
    }

    @concurrent
    static func run(query: String, options: SearchOptions, documents: [SearchDocument]) async -> SearchOutcome {
        find(query: query, options: options, in: documents)
    }
}

nonisolated struct SearchFailure: Error, Sendable {
    let message: String
}

extension SearchDocument {
    init(block: Block) {
        var parts: [Part] = []
        for (index, segment) in block.segments.enumerated() {
            switch segment {
            case .text(let text):
                parts.append(Part(index: index, text: String(text.characters)))
            case .stack(let stack):
                if !stack.lines.isEmpty {
                    parts.append(Part(index: index, text: String(stack.text.characters)))
                }
            case .image:
                break
            }
        }
        self.init(id: block.id, command: block.command, parts: parts)
    }
}

extension Theme {
    static let searchCommandMatch = ThemeColor(
        light: NSColor(hex: 0xFFD33D, alpha: 0.45), dark: NSColor(hex: 0xE3B341, alpha: 0.35)
    )
    static let searchCommandActive = ThemeColor(
        light: NSColor(hex: 0xFB8C00, alpha: 0.75), dark: NSColor(hex: 0xF0883E, alpha: 0.7)
    )
    static let searchBarFill = ThemeColor(light: 0xF6F6F8, dark: 0x1B1B1F)
}

struct ScrollRequest: Equatable {
    let id: Int
    let blockID: UUID
    let position: Double
}

@Observable
final class BlockSearch {
    private struct Key: Hashable {
        let blockID: UUID
        let target: SearchMatch.Target
    }

    var query = "" {
        didSet { if query != oldValue { settingsChanged() } }
    }
    var caseSensitive = false {
        didSet { if caseSensitive != oldValue { settingsChanged() } }
    }
    var wholeWord = false {
        didSet { if wholeWord != oldValue { settingsChanged() } }
    }
    var useRegex = false {
        didSet { if useRegex != oldValue { settingsChanged() } }
    }
    var isPresented = false

    private(set) var matchCount = 0
    private(set) var activeIndex = 0
    private(set) var isTruncated = false
    private(set) var invalidPattern: String?
    private(set) var matches: [SearchMatch] = []
    private(set) var scrollRequest: ScrollRequest?
    private(set) var focusRequest = 0

    @ObservationIgnored var source: () -> [SearchDocument] = { [] }
    @ObservationIgnored private var lookup: [Key: [NSRange]] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var throttling = false
    @ObservationIgnored private var requestCounter = 0
    @ObservationIgnored private var cache: [UUID: SearchDocument] = [:]

    private static let debounceDelay = Duration.milliseconds(140)
    private static let throttleDelay = Duration.milliseconds(300)

    var options: SearchOptions {
        SearchOptions(caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex)
    }

    func highlights(for block: Block, segment: Int) -> SegmentHighlights {
        highlights(blockID: block.id, target: .segment(segment))
    }

    func commandHighlights(for block: Block) -> SegmentHighlights {
        highlights(blockID: block.id, target: .command)
    }

    func highlights(blockID: UUID, target: SearchMatch.Target) -> SegmentHighlights {
        guard let ranges = lookup[Key(blockID: blockID, target: target)] else { return .none }
        var active: NSRange?
        if matches.indices.contains(activeIndex) {
            let current = matches[activeIndex]
            if current.blockID == blockID, current.target == target { active = current.range }
        }
        return SegmentHighlights(ranges: ranges, active: active)
    }

    var activeMatch: SearchMatch? {
        matches.indices.contains(activeIndex) ? matches[activeIndex] : nil
    }

    func snapshot(_ blocks: [Block]) -> [SearchDocument] {
        var kept: [UUID: SearchDocument] = [:]
        var documents: [SearchDocument] = []
        documents.reserveCapacity(blocks.count)
        for block in blocks {
            if !block.isRunning, let cached = cache[block.id] {
                kept[block.id] = cached
                documents.append(cached)
                continue
            }
            let document = SearchDocument(block: block)
            if !block.isRunning { kept[block.id] = document }
            documents.append(document)
        }
        cache = kept
        return documents
    }

    func present() {
        isPresented = true
        focusRequest += 1
        if !query.isEmpty { debounceRefresh(reveal: true) }
    }

    func close() {
        isPresented = false
        debounce?.cancel()
        generation += 1
        clearResults()
    }

    func useSelection(_ text: String) {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !line.isEmpty else { return }
        useRegex = false
        query = line
        present()
    }

    func next() {
        step(1)
    }

    func previous() {
        step(-1)
    }

    func contentChanged() {
        guard isPresented, !query.isEmpty, !throttling else { return }
        throttling = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.throttleDelay)
            guard let self else { return }
            self.throttling = false
            await self.refresh(reveal: false)
        }
    }

    func refresh(reveal: Bool) async {
        generation += 1
        let mine = generation
        let documents = source()
        let outcome = await SearchEngine.run(query: query, options: options, documents: documents)
        guard mine == generation, !Task.isCancelled, isPresented else { return }
        apply(outcome, reveal: reveal)
    }

    func apply(_ outcome: SearchOutcome, reveal: Bool) {
        let previous = activeMatch
        switch outcome {
        case .invalid(let message):
            invalidPattern = message
            isTruncated = false
            matches = []
        case .matches(let found, let truncated):
            invalidPattern = nil
            isTruncated = truncated
            matches = found
        }
        matchCount = matches.count
        var table: [Key: [NSRange]] = [:]
        for match in matches {
            table[Key(blockID: match.blockID, target: match.target), default: []].append(match.range)
        }
        lookup = table
        if reveal {
            activeIndex = max(matches.count - 1, 0)
            requestScroll()
        } else if let previous, let kept = matches.firstIndex(where: { $0.sameSpot(as: previous) }) {
            activeIndex = kept
        } else {
            activeIndex = min(activeIndex, max(matches.count - 1, 0))
        }
    }

    private func step(_ delta: Int) {
        if !isPresented {
            present()
            return
        }
        guard !matches.isEmpty else { return }
        activeIndex = (activeIndex + delta + matches.count) % matches.count
        requestScroll()
    }

    private func requestScroll() {
        guard let match = activeMatch else { return }
        requestCounter += 1
        scrollRequest = ScrollRequest(id: requestCounter, blockID: match.blockID, position: match.position)
    }

    private func settingsChanged() {
        guard isPresented else { return }
        debounceRefresh(reveal: true)
    }

    private func debounceRefresh(reveal: Bool) {
        debounce?.cancel()
        if query.isEmpty {
            generation += 1
            clearResults()
            return
        }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.refresh(reveal: reveal)
        }
    }

    private func clearResults() {
        matches = []
        lookup = [:]
        matchCount = 0
        activeIndex = 0
        isTruncated = false
        invalidPattern = nil
    }
}
