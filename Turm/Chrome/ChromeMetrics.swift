import SwiftUI

enum ChromeMetrics {
    static let sidebarDefaultWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 560
    static let sidebarResizeHandleWidth: CGFloat = 4
    static let sidebarHoverEdgeWidth: CGFloat = 8
    static let sidebarAutoHideDelay: Double = 0.12
    static let sidebarHide = Animation.easeOut(duration: 0.16)

    static let topRowHeight: CGFloat = 36
    static let trafficLightDiameter: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8
    static let trafficLightLeadingInset: CGFloat = 10
    static var trafficLightTopInset: CGFloat { (topRowHeight - trafficLightDiameter) / 2 }
    static var trafficLightClusterWidth: CGFloat { trafficLightDiameter * 3 + trafficLightSpacing * 2 }

    static let cardCornerRadius: CGFloat = 10
    static let cardInset: CGFloat = 9
    /// Spotlight grows from the search button, so the button row and the field share this inset on the left and the bottom.
    static let spotlightInset: CGFloat = cardInset
    static let paneGap: CGFloat = 8

    /// Inner corner when a card sits `inset` points inside another card, so the curves stay concentric.
    static func concentric(inset: CGFloat, outer: CGFloat = cardCornerRadius) -> CGFloat {
        max(0, outer - inset)
    }
    static var contentCardLeadingSeam: CGFloat { cardInset - sidebarResizeHandleWidth }

    static let rowHeight: CGFloat = 32
    static let rowCornerRadius: CGFloat = 8
    static let sidebarHorizontalPadding: CGFloat = 10

    static let motion = Animation.spring(response: 0.35, dampingFraction: 0.82)
}

struct PaneCorners: Equatable {
    var topLeading: CGFloat
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat
    var topTrailing: CGFloat

    /// Corners flush with the window card keep its radius. Corners that meet another pane use the seam radius, so the focus stroke is not clipped by the card.
    static func resolve(_ frame: CGRect, in bounds: CGRect) -> PaneCorners {
        let outer = ChromeMetrics.cardCornerRadius
        let inner = ChromeMetrics.concentric(inset: ChromeMetrics.paneGap / 2)
        let flushLeft = frame.minX <= bounds.minX + 0.5
        let flushRight = frame.maxX >= bounds.maxX - 0.5
        let flushTop = frame.minY <= bounds.minY + 0.5
        let flushBottom = frame.maxY >= bounds.maxY - 0.5
        func radius(flushX: Bool, flushY: Bool) -> CGFloat {
            flushX && flushY ? outer : inner
        }
        return PaneCorners(
            topLeading: radius(flushX: flushLeft, flushY: flushTop),
            bottomLeading: radius(flushX: flushLeft, flushY: flushBottom),
            bottomTrailing: radius(flushX: flushRight, flushY: flushBottom),
            topTrailing: radius(flushX: flushRight, flushY: flushTop)
        )
    }

    func inset(by amount: CGFloat) -> PaneCorners {
        PaneCorners(
            topLeading: max(0, topLeading - amount),
            bottomLeading: max(0, bottomLeading - amount),
            bottomTrailing: max(0, bottomTrailing - amount),
            topTrailing: max(0, topTrailing - amount)
        )
    }

    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topLeading,
            bottomLeadingRadius: bottomLeading,
            bottomTrailingRadius: bottomTrailing,
            topTrailingRadius: topTrailing,
            style: .continuous
        )
    }
}

enum SidebarHoverPhase: Equatable {
    case hidden
    case peeking
    case revealed
    case hiding

    var showsPanel: Bool { self != .hidden }

    func hoverChanged(_ hovering: Bool) -> SidebarHoverPhase {
        if hovering {
            return self == .hidden ? .peeking : .revealed
        }
        return self == .hidden ? .hidden : .hiding
    }

    func revealAnimationCompleted() -> SidebarHoverPhase {
        self == .peeking ? .revealed : self
    }

    func hideDelayElapsed() -> SidebarHoverPhase {
        self == .hiding ? .hidden : self
    }
}

enum SidebarWidthPreference {
    static let key = "turm.sidebarWidth"

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, ChromeMetrics.sidebarMinWidth), ChromeMetrics.sidebarMaxWidth)
    }
}
