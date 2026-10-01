import SwiftUI

/// The size of a view and the parts of it the system has reserved, in the view's own coordinates.
nonisolated struct ReservedArea: Equatable, Sendable {
    var size = CGSize.zero
    var rects: [CGRect] = []

    /// The widest reserved column crossing the view, where a bar should split in two.
    var seam: ClosedRange<CGFloat>? {
        guard let widest = rects.max(by: { $0.width < $1.width }) else { return nil }
        return widest.minX...widest.maxX
    }

    /// The tallest reserved row crossing the view, which a vertical bar should step around.
    var band: ClosedRange<CGFloat>? {
        guard let tallest = rects.max(by: { $0.height < $1.height }) else { return nil }
        return tallest.minY...tallest.maxY
    }

    /// How far the centre of the tallest reserved column sits from the view's centre, so a vertical bar lines up with it.
    var columnOffset: CGFloat {
        guard let tallest = rects.max(by: { $0.height < $1.height }), size.width > 0 else { return 0 }
        return tallest.midX - size.width / 2
    }

    /// The largest rectangle outside every reserved region, preferring one that holds the point.
    func freeRect(containing point: CGPoint? = nil) -> CGRect? {
        guard !rects.isEmpty, size.width > 0, size.height > 0 else { return nil }
        var free = [CGRect(origin: .zero, size: size)]
        for hole in rects {
            free = free.flatMap { rect -> [CGRect] in
                guard rect.intersects(hole) else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: hole.minX - rect.minX, height: rect.height),
                    CGRect(x: hole.maxX, y: rect.minY, width: rect.maxX - hole.maxX, height: rect.height),
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: hole.minY - rect.minY),
                    CGRect(x: rect.minX, y: hole.maxY, width: rect.width, height: rect.maxY - hole.maxY),
                ].filter { $0.width > 1 && $0.height > 1 }
            }
        }
        let area: (CGRect) -> CGFloat = { $0.width * $0.height }
        if let point, let hit = free.filter({ $0.contains(point) }).max(by: { area($0) < area($1) }) { return hit }
        return free.max { area($0) < area($1) }
    }

    static func measure(_ proxy: GeometryProxy) -> ReservedArea {
        let size = proxy.size
        #if compiler(>=6.4)
        guard #available(iOS 27.1, *) else { return ReservedArea(size: size) }
        let bounds = CGRect(origin: .zero, size: size)
        let regions = proxy.reservedRegions(kind: .occlusion) + proxy.reservedRegions(kind: .division)
        let rects = regions
            .filter(\.isActive)
            .map { $0.frame.intersection(bounds) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        return ReservedArea(size: size, rects: rects)
        #else
        return ReservedArea(size: size)
        #endif
    }

    /// The x range of an active fold running top to bottom through the view, if there is one.
    static func verticalFold(in proxy: GeometryProxy) -> ClosedRange<CGFloat>? {
        #if compiler(>=6.4)
        guard #available(iOS 27.1, *) else { return nil }
        let size = proxy.size
        let fold = proxy.reservedRegions(kind: .division)
            .filter { $0.isActive && $0.frame.height >= size.height * 0.5 && $0.frame.height > $0.frame.width }
            .map(\.frame)
            .first { $0.minX > 0 && $0.maxX < size.width }
        return fold.map { $0.minX...$0.maxX }
        #else
        return nil
        #endif
    }
}

extension View {
    func measuringReservedRegions(into area: Binding<ReservedArea>) -> some View {
        onGeometryChange(for: ReservedArea.self) { ReservedArea.measure($0) } action: { area.wrappedValue = $0 }
    }

    @ViewBuilder
    func confined(to area: ReservedArea, preferring point: CGPoint? = nil) -> some View {
        if let free = area.freeRect(containing: point) {
            frame(width: free.width, height: free.height).position(x: free.midX, y: free.midY)
        } else {
            self
        }
    }
}
