import Foundation

public struct ScrollExtent: Equatable, Sendable {
    public var top: Double
    public var height: Double
    public var content: Double

    public init(top: Double = 0, height: Double = 0, content: Double = 0) {
        self.top = top
        self.height = height
        self.content = content
    }

    public var isAtBottom: Bool { top + height >= content - BottomFollow.tolerance }
}

public struct BottomFollow: Equatable, Sendable {
    public static let tolerance: Double = 4

    public private(set) var following = true
    public private(set) var unseen = false

    public init() {}

    public mutating func userScrolled(to extent: ScrollExtent) {
        following = extent.isAtBottom
        if following { unseen = false }
    }

    public mutating func layoutChanged(from old: ScrollExtent, to new: ScrollExtent) -> Bool {
        if following { return !new.isAtBottom || new.height != old.height || new.content != old.content }
        if new.isAtBottom {
            jump()
        } else if new.content > old.content {
            unseen = true
        }
        return false
    }

    public mutating func jump() {
        following = true
        unseen = false
    }
}
