import AppKit
import SwiftTerm
import Testing
import TurmCore
@testable import Turm

private let rgbaPixel = "/wAA/w=="

private func apc(_ keys: String, _ payload: String = "") -> [UInt8] {
    let body = payload.isEmpty ? keys : "\(keys);\(payload)"
    return Array("\u{1B}_G\(body)\u{1B}\\".utf8)
}

private func makeHost() -> AltScreenHost {
    let host = AltScreenHost(cols: 40, rows: 12)
    host.apply(dark: true)
    host.feed(Array("\u{1B}[?1049h".utf8))
    return host
}

private func screenText(_ host: AltScreenHost) -> String {
    let terminal = host.view.getTerminal()
    return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
}

struct AltScreenGraphicsTests {
    @Test func graphicsCommandsGoToTheEngineAndNeverToTheTextGrid() {
        let host = makeHost()
        let kept = host.feed(Array("a".utf8) + apc("a=T,f=32,s=1,v=1,i=7,c=2,r=1", rgbaPixel) + Array("b".utf8))
        #expect(kept == Array("ab".utf8))
        #expect(host.engine.activeStore.images.map(\.kittyID) == [7])
        #expect(!screenText(host).contains("f=32"))
        #expect(host.painter.overlay.sublayers?.count == 1)
        #expect(host.painter.underlay.sublayers?.isEmpty ?? true)
    }

    @Test func negativeZIndexDrawsBeneathTheText() {
        let host = makeHost()
        host.feed(apc("a=T,f=32,s=1,v=1,i=3,z=-1,C=1", rgbaPixel))
        #expect(host.painter.underlay.sublayers?.count == 1)
        #expect(host.painter.overlay.sublayers?.isEmpty ?? true)
        #expect(host.view.graphicsBackdrop.layer?.sublayers?.contains { $0 === host.painter.underlay } == true)
    }

    @Test func defaultBackgroundIsPaintedBehindTheTextLayer() {
        let host = makeHost()
        let expected = Theme.terminalBackground.resolved(dark: true).cgColor
        #expect(host.view.layer?.backgroundColor == nil)
        #expect(host.view.graphicsBackdrop.fill == expected)
        host.apply(dark: false)
        #expect(host.view.layer?.backgroundColor == nil)
        #expect(host.view.graphicsBackdrop.fill == Theme.terminalBackground.resolved(dark: false).cgColor)
    }

    @Test func backdropSitsBelowAndOverlayAboveTheTerminal() throws {
        let host = makeHost()
        let container = AltContainer(host: host)
        container.setFrameSize(NSSize(width: 400, height: 300))
        let order = container.subviews
        let backdrop = try #require(order.firstIndex { $0 === host.view.graphicsBackdrop })
        let text = try #require(order.firstIndex { $0 === host.view })
        let overlay = try #require(order.firstIndex { $0 === host.graphicsOverlay })
        #expect(backdrop < text)
        #expect(overlay > text)
        #expect(host.view.graphicsBackdrop.frame == host.view.frame)
        #expect(host.graphicsOverlay.frame == host.view.frame)
    }

    @Test func placeholderTilesOfTheAlternateScreenAreDrawn() {
        let host = makeHost()
        host.feed(apc("a=T,U=1,f=32,s=1,v=1,i=42,c=1,r=1,q=2", rgbaPixel))
        host.feed(Array("\u{1B}[38;5;42m\u{10EEEE}\u{0305}\u{0305}\u{1B}[39m".utf8))
        host.refreshGraphics()
        #expect(host.painter.overlay.sublayers?.count == 1)
    }

    @Test func mainScreenCellsStayReadableBehindTheProgram() {
        let host = AltScreenHost(cols: 40, rows: 12)
        host.feed(Array("\u{1B}[38;5;7m\u{10EEEE}\u{0305}\u{0305}\u{1B}[39m".utf8))
        host.feed(Array("\u{1B}[?1049h\u{1B}[38;5;9m\u{10EEEE}\u{0305}\u{0305}\u{1B}[39m".utf8))
        #expect(host.graphicsHost.placeholderCells(rows: 0..<12, buffer: .normal).map(\.foreground) == [.indexed(7)])
        #expect(host.graphicsHost.placeholderCells(rows: 0..<12, buffer: .alternate).map(\.foreground) == [.indexed(9)])
    }

    @Test func splitCommandIsHeldUntilItEnds() {
        let host = makeHost()
        let command = apc("a=T,f=32,s=1,v=1,i=9", rgbaPixel)
        let cut = command.count / 2
        #expect(host.feed(Array(command[..<cut])).isEmpty)
        #expect(host.engine.activeStore.images.isEmpty)
        #expect(host.feed(Array(command[cut...]) + Array("x".utf8)) == Array("x".utf8))
        #expect(host.engine.activeStore.images.map(\.kittyID) == [9])
    }

    @Test func queriesAreAnsweredLiveButNotOnReplay() {
        let host = makeHost()
        var replies: [[UInt8]] = []
        host.onInput = { replies.append($0) }
        host.feed(apc("a=q,i=31,s=1,v=1,f=32", rgbaPixel))
        #expect(replies.count == 1)
        #expect(String(decoding: replies.first ?? [], as: UTF8.self).contains("i=31;OK"))
        replies = []
        let replayed = AltScreenHost(cols: 40, rows: 12)
        replayed.onInput = { replies.append($0) }
        replayed.replay(Array("\u{1B}[?1049h".utf8) + apc("a=q,i=31,s=1,v=1,f=32", rgbaPixel))
        #expect(replies.isEmpty)
    }

    @Test func replayRebuildsOnlyTheFullScreenImages() {
        let host = AltScreenHost(cols: 40, rows: 12)
        host.replay(apc("a=T,f=32,s=1,v=1,i=1", rgbaPixel) + Array("\u{1B}[?1049h".utf8) + apc("a=T,f=32,s=1,v=1,i=2", rgbaPixel))
        #expect(host.engine.store.images.isEmpty)
        #expect(host.engine.alternateStore.images.map(\.kittyID) == [2])
    }

    @Test func clearingTheScreenDropsVisibleImages() {
        let host = makeHost()
        host.feed(apc("a=T,f=32,s=1,v=1,i=4", rgbaPixel))
        #expect(host.painter.overlay.sublayers?.count == 1)
        let kept = host.feed(Array("\u{1B}[2J".utf8))
        #expect(kept == Array("\u{1B}[2J".utf8))
        #expect(host.engine.activeStore.images.isEmpty)
        #expect(host.painter.overlay.sublayers?.isEmpty ?? true)
    }

    @Test func scrollbackClearIsKeptForTheBlock() {
        let host = AltScreenHost(cols: 40, rows: 12)
        let kept = host.feed(Array("one\u{1B}[22J".utf8))
        #expect(kept == Array("one\u{1B}[22J".utf8))
    }

    @Test func leavingTheAlternateScreenHidesItsImages() {
        let host = makeHost()
        host.feed(apc("a=T,f=32,s=1,v=1,i=6", rgbaPixel))
        #expect(host.painter.overlay.sublayers?.count == 1)
        host.feed(Array("\u{1B}[?1049l".utf8))
        #expect(!host.engine.isAlternate)
        #expect(host.painter.overlay.sublayers?.isEmpty ?? true)
    }

    @Test func pixelMouseReportsUseThePanePixels() {
        let host = makeHost()
        host.view.setFrameSize(NSSize(width: 400, height: 300))
        let pixels = host.panePixels
        #expect(pixels.width == 400 * host.screenScale)
        #expect(pixels.height == 300 * host.screenScale)
    }
}
