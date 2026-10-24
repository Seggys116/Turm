import CoreGraphics
import Testing
@testable import Turm

struct SidebarHoverTests {
    @Test func theEdgePeekBecomesARevealedPanelAndHidesAfterTheDelay() {
        var phase = SidebarHoverPhase.hidden
        phase = phase.hoverChanged(true)
        #expect(phase == .peeking)
        #expect(phase.showsPanel)
        phase = phase.revealAnimationCompleted()
        #expect(phase == .revealed)
        phase = phase.hoverChanged(false)
        #expect(phase == .hiding)
        #expect(phase.showsPanel)
        phase = phase.hoverChanged(true)
        #expect(phase == .revealed)
        phase = phase.hoverChanged(false).hideDelayElapsed()
        #expect(phase == .hidden)
        #expect(!phase.showsPanel)
    }

    @Test func splitCornersFollowTheWindowOnTheOutsideAndTheSeamOnTheInside() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let left = CGRect(x: 0, y: 0, width: 390, height: 600)
        let corners = PaneCorners.resolve(left, in: bounds)
        let seam = ChromeMetrics.concentric(inset: ChromeMetrics.paneGap / 2)
        #expect(corners.topLeading == ChromeMetrics.cardCornerRadius)
        #expect(corners.bottomLeading == ChromeMetrics.cardCornerRadius)
        #expect(corners.topTrailing == seam)
        #expect(corners.bottomTrailing == seam)

        let inner = PaneCorners.resolve(CGRect(x: 20, y: 20, width: 100, height: 100), in: bounds)
        #expect(inner.topLeading == seam)
        #expect(inner.bottomTrailing == seam)
    }

    @Test func sidebarWidthStaysInsideTheChromeLimits() {
        #expect(SidebarWidthPreference.clamped(ChromeMetrics.sidebarMinWidth / 2) == ChromeMetrics.sidebarMinWidth)
        #expect(SidebarWidthPreference.clamped(ChromeMetrics.sidebarMaxWidth * 2) == ChromeMetrics.sidebarMaxWidth)
        #expect(SidebarWidthPreference.clamped(ChromeMetrics.sidebarDefaultWidth) == ChromeMetrics.sidebarDefaultWidth)
    }
}
