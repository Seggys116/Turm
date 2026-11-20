import AppKit
import Foundation
import Testing
@testable import Turm

private func scratchDefaults() -> (UserDefaults, String) {
    let name = "turm.zoomtests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

struct ZoomTests {
    @Test func clampsToRange() {
        #expect(TerminalZoom.clamped(1) == 9)
        #expect(TerminalZoom.clamped(500) == 32)
        #expect(TerminalZoom.clamped(.nan) == 13)
        #expect(TerminalZoom.clamped(.infinity) == 13)
        #expect(TerminalZoom.clamped(13.4) == 13)
    }

    @Test func stepsByOnePointAndStopsAtTheEnds() {
        #expect(TerminalZoom.zoomedIn(13) == 14)
        #expect(TerminalZoom.zoomedOut(13) == 12)
        #expect(TerminalZoom.zoomedIn(32) == 32)
        #expect(TerminalZoom.zoomedOut(9) == 9)
    }

    @Test func startsAtTheDefaultSize() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let zoom = TerminalZoom(defaults: defaults)
        #expect(zoom.size == 13)
        #expect(zoom.isDefault)
    }

    @Test func zoomsAndResets() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let zoom = TerminalZoom(defaults: defaults)
        zoom.zoomIn()
        zoom.zoomIn()
        #expect(zoom.size == 15)
        zoom.zoomOut()
        #expect(zoom.size == 14)
        zoom.reset()
        #expect(zoom.size == 13)
    }

    @Test func limitsDisableFurtherZoom() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let zoom = TerminalZoom(defaults: defaults)
        for _ in 0..<100 { zoom.zoomIn() }
        #expect(zoom.size == 32)
        #expect(!zoom.canZoomIn)
        #expect(zoom.canZoomOut)
        for _ in 0..<100 { zoom.zoomOut() }
        #expect(zoom.size == 9)
        #expect(!zoom.canZoomOut)
    }

    @Test func persistsUnderItsKey() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let zoom = TerminalZoom(defaults: defaults)
        zoom.zoomIn()
        #expect(defaults.double(forKey: TerminalZoom.key) == 14)
        #expect(TerminalZoom(defaults: defaults).size == 14)
        zoom.reset()
        #expect(defaults.object(forKey: TerminalZoom.key) == nil)
        #expect(TerminalZoom(defaults: defaults).size == 13)
    }

    @Test func storedValueIsClamped() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(400.0, forKey: TerminalZoom.key)
        #expect(TerminalZoom.stored(in: defaults) == 32)
        defaults.set(2.0, forKey: TerminalZoom.key)
        #expect(TerminalZoom.stored(in: defaults) == 9)
        defaults.set("big", forKey: TerminalZoom.key)
        #expect(TerminalZoom.stored(in: defaults) == 13)
    }

    @Test func metricsGrowWithTheSize() {
        let small = TerminalMetrics.measure(size: 10)
        let normal = TerminalMetrics.measure(size: 13)
        let large = TerminalMetrics.measure(size: 26)
        #expect(small.cellWidth < normal.cellWidth)
        #expect(normal.cellWidth < large.cellWidth)
        #expect(small.lineHeight < normal.lineHeight)
        #expect(normal.lineHeight < large.lineHeight)
        #expect(abs(large.cellWidth / normal.cellWidth - 2) < 0.1)
        #expect(large.font.pointSize == 26)
    }

    @Test func fontsFollowTheRequestedSize() {
        let fonts = TerminalFonts.fonts(size: 20)
        #expect(fonts.count == 4)
        #expect(fonts.allSatisfy { $0.pointSize == 20 })
    }

    @Test func reportsTheSizeAsAShareOfTheDefault() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let zoom = TerminalZoom(defaults: defaults)
        #expect(zoom.percent == 100)
        zoom.zoomIn()
        zoom.zoomIn()
        #expect(zoom.percent == 115)
        zoom.reset()
        zoom.zoomOut()
        #expect(zoom.percent == 92)
    }

    @Test func everyCommandIsAnnouncedEvenWhenTheSizeStays() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let zoom = TerminalZoom(defaults: defaults)
        zoom.zoomIn()
        #expect(zoom.announcement == 1)
        zoom.reset()
        zoom.reset()
        #expect(zoom.announcement == 3)
        #expect(zoom.size == TerminalZoom.defaultSize)
    }
}
