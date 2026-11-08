import AppKit
import Foundation
import SwiftTerm
import TurmCore

extension BlockEmulator {
    var cursorRow: Int {
        terminal.buffer.yDisp + terminal.buffer.y + terminal.buffer.totalLinesTrimmed
    }

    var normalStore: KittyImageStore {
        engine.store
    }

    var altStore: KittyImageStore {
        engine.alternateStore
    }

    private var activeStore: KittyImageStore {
        engine.activeStore
    }

    var images: [InlineImage] {
        let kitty = activeStore.images.map { InlineImage(placement: $0) }
        return terminal.isCurrentBufferAlternate ? kitty : inlineImages + kitty
    }

    var virtualPlacements: [InlineImage] {
        activeStore.virtualPlacements.map { InlineImage(placement: $0) }
    }

    var sources: [UInt32: KittyAnimation] {
        activeStore.sources
    }

    var placedIDs: Set<UInt32> {
        activeStore.placedIDs()
    }

    var usedStorage: Int {
        activeStore.usedStorage
    }

    var cacheSize: Int {
        activeStore.cacheSize
    }

    var storageLimit: Int {
        get { activeStore.storageLimit }
        set { activeStore.storageLimit = newValue }
    }

    func clearGraphics(_ scope: KittyGraphicsScanner.ClearScope) {
        if scope == .scrollback {
            if let push = terminal.scrollbackPush() { terminal.feed(byteArray: push) }
            terminal.feed(byteArray: Array("\u{1B}[2J".utf8))
        }
        engine.clear(scope, host: graphicsHost)
        guard scope == .reset || !terminal.isCurrentBufferAlternate else { return }
        if scope == .everything {
            inlineImages.removeAll()
        } else {
            let top = terminal.buffer.yDisp + terminal.buffer.totalLinesTrimmed
            inlineImages.removeAll { $0.anchor + max($0.rowSpan, 1) > top }
        }
    }

    func pruneScrolledOff() {
        let trimmed = terminal.buffer.totalLinesTrimmed
        guard trimmed > 0 else { return }
        engine.pruneScrolledOff(trimmed: trimmed)
        guard !terminal.isCurrentBufferAlternate else { return }
        inlineImages.removeAll { $0.rowSpan > 0 && $0.anchor + $0.rowSpan <= trimmed }
    }

    /// Kitty placements of the main screen from `top` down, with placeholder tiles kept apart, also while a program holds the alternate screen.
    func kittyPlacements(from top: Int) -> (images: [InlineImage], tiles: [InlineImage]) {
        var images: [InlineImage] = []
        var tiles: [InlineImage] = []
        for placement in engine.placements(visible: top..<Int.max, host: graphicsHost, buffer: .normal) {
            if placement.tile == nil {
                images.append(InlineImage(placement: placement))
            } else {
                tiles.append(InlineImage(placement: placement))
            }
        }
        return (images, tiles)
    }

    func origin(of image: InlineImage) -> (row: Int, column: Int)? {
        guard normalStore.images.contains(where: { $0.id == image.id }) else {
            return image.parent == nil ? (image.anchor, image.column) : nil
        }
        return engine.origin(of: image.id, host: graphicsHost, buffer: .normal).map { ($0.row, $0.column) }
    }
}
