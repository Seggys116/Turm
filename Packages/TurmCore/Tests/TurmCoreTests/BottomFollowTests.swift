import Testing
@testable import TurmCore

struct BottomFollowTests {
    private let pinned = ScrollExtent(top: 600, height: 400, content: 1000)

    @Test func bottomUsesTheVisibleRectIncludingInsets() {
        #expect(ScrollExtent(top: 1312, height: 736, content: 2048).isAtBottom)
        #expect(ScrollExtent(top: 1542, height: 506, content: 2048).isAtBottom)
        #expect(!ScrollExtent(top: 1312, height: 506, content: 2048).isAtBottom)
    }

    @Test func shortBottomAlignedContentCountsAsBottom() {
        #expect(ScrollExtent(top: -386, height: 744, content: 0).isAtBottom)
        #expect(ScrollExtent(top: -678, height: 1378, content: 54).isAtBottom)
    }

    @Test func growthWhileFollowingScrollsDown() {
        var follow = BottomFollow()
        let grown = ScrollExtent(top: 600, height: 400, content: 1005)
        let scrolls = follow.layoutChanged(from: pinned, to: grown)
        #expect(scrolls)
        #expect(follow.following)
    }

    @Test func layoutMovingTheViewUpNeverStopsFollowing() {
        var follow = BottomFollow()
        let glitch = ScrollExtent(top: 400, height: 400, content: 1000)
        let scrolls = follow.layoutChanged(from: pinned, to: glitch)
        #expect(scrolls)
        #expect(follow.following)
        #expect(!follow.unseen)
    }

    @Test func viewportShrinkWhileFollowingScrolls() {
        var follow = BottomFollow()
        let shorter = ScrollExtent(top: 600, height: 170, content: 1000)
        let scrolls = follow.layoutChanged(from: pinned, to: shorter)
        #expect(scrolls)
    }

    @Test func resizedViewportReportedAtBottomIsStillRepinned() {
        var follow = BottomFollow()
        let shrunk = ScrollExtent(top: 750, height: 250, content: 1000)
        let scrolls = follow.layoutChanged(from: pinned, to: shrunk)
        #expect(scrolls)
    }

    @Test func growthReportedAtBottomIsStillRepinned() {
        var follow = BottomFollow()
        let grown = ScrollExtent(top: 632, height: 400, content: 1032)
        let scrolls = follow.layoutChanged(from: pinned, to: grown)
        #expect(scrolls)
    }

    @Test func steadyBottomNeedsNoScroll() {
        var follow = BottomFollow()
        let scrolls = follow.layoutChanged(from: pinned, to: pinned)
        #expect(!scrolls)
    }

    @Test func userScrollingUpStopsFollowingAndGrowthMarksUnseen() {
        var follow = BottomFollow()
        let up = ScrollExtent(top: 590, height: 400, content: 1000)
        follow.userScrolled(to: up)
        #expect(!follow.following)
        let grown = ScrollExtent(top: 590, height: 400, content: 1200)
        let scrolls = follow.layoutChanged(from: up, to: grown)
        #expect(!scrolls)
        #expect(follow.unseen)
        #expect(!follow.following)
    }

    @Test func userScrollThatStaysWithinToleranceKeepsFollowing() {
        var follow = BottomFollow()
        follow.userScrolled(to: ScrollExtent(top: 597, height: 400, content: 1000))
        #expect(follow.following)
    }

    @Test func userReturningToBottomResumesAndClearsUnseen() {
        var follow = BottomFollow()
        let up = ScrollExtent(top: 100, height: 400, content: 1000)
        follow.userScrolled(to: up)
        _ = follow.layoutChanged(from: up, to: ScrollExtent(top: 100, height: 400, content: 1200))
        follow.userScrolled(to: ScrollExtent(top: 800, height: 400, content: 1200))
        #expect(follow.following)
        #expect(!follow.unseen)
    }

    @Test func layoutThatRevealsTheBottomResumesFollowing() {
        var follow = BottomFollow()
        let up = ScrollExtent(top: 100, height: 400, content: 1000)
        follow.userScrolled(to: up)
        _ = follow.layoutChanged(from: up, to: ScrollExtent(top: 0, height: 400, content: 60))
        #expect(follow.following)
        #expect(!follow.unseen)
    }

    @Test func layoutWhileScrolledUpWithoutGrowthLeavesPosition() {
        var follow = BottomFollow()
        let up = ScrollExtent(top: 200, height: 400, content: 1000)
        follow.userScrolled(to: up)
        let shorter = ScrollExtent(top: 200, height: 300, content: 1000)
        let scrolls = follow.layoutChanged(from: up, to: shorter)
        #expect(!scrolls)
        #expect(!follow.unseen)
        #expect(!follow.following)
    }

    @Test func newBlockWhileScrolledUpOnlyMarksUnseen() {
        var follow = BottomFollow()
        let up = ScrollExtent(top: 100, height: 400, content: 1000)
        follow.userScrolled(to: up)
        let shorter = ScrollExtent(top: 100, height: 170, content: 1000)
        _ = follow.layoutChanged(from: up, to: shorter)
        let submitted = ScrollExtent(top: 100, height: 400, content: 1054)
        let scrolls = follow.layoutChanged(from: shorter, to: submitted)
        #expect(!scrolls)
        #expect(follow.unseen)
        #expect(!follow.following)
    }
}
