import ObjectiveC
import SwiftUI
import UIKit

struct ChromePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .chromeHover()
    }
}

struct ChromeIconLabel: View {
    let systemImage: String
    var tint = Chrome.text
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(prominent ? Chrome.onAccent : tint)
            .frame(width: 34, height: 34)
            .background(prominent ? Chrome.accent : Chrome.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip).stroke(prominent ? Color.clear : Chrome.chipStroke, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .frame(minWidth: Chrome.Metrics.target, minHeight: Chrome.Metrics.target)
            .contentShape(Rectangle())
    }
}

struct ChromeIconButton: View {
    let systemImage: String
    let label: String
    var tint = Chrome.text
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ChromeIconLabel(systemImage: systemImage, tint: tint, prominent: prominent)
        }
        .buttonStyle(ChromePressStyle())
        .accessibilityLabel(label)
    }
}

struct ChromeBackButton: View {
    var label = "Back"
    let action: () -> Void

    var body: some View {
        ChromeIconButton(systemImage: "chevron.left", label: label, action: action)
    }
}

/// A text button in a horizontal bar that becomes an icon button when the bar runs vertically.
struct ChromeBarButton: View {
    let title: String
    let systemImage: String
    var kind = ChromeButtonStyle.Kind.plain
    let action: () -> Void
    @Environment(\.chromeBarStyle) private var style

    var body: some View {
        if style.isVertical {
            ChromeIconButton(
                systemImage: systemImage, label: title, tint: kind == .destructive ? Chrome.failure : Chrome.text,
                prominent: kind == .prominent, action: action
            )
        } else {
            Button(title) {
                Haptics.tap()
                action()
            }
            .buttonStyle(ChromeButtonStyle(kind: kind, compact: true))
        }
    }
}

nonisolated enum ChromeBarStyle: Equatable, Sendable {
    case horizontal
    case vertical(HorizontalEdge)
    case header

    var isVertical: Bool {
        if case .vertical = self { true } else { false }
    }
}

extension EnvironmentValues {
    @Entry var chromeBarStyle = ChromeBarStyle.horizontal
    @Entry var chromeBarShowsMark = false
    /// Set where an enclosing view already shows the window's vertical bar, so nested bars show only their title.
    @Entry var chromeBarSuppressed = false
    @Entry var chromeBarHorizontalOnly = false
    @Entry var chromeBarBand: ChromeBarBand?
}

nonisolated struct ChromeBarBand: Equatable, Sendable {
    var height: CGFloat
    var leading: CGFloat
    var trailing: CGFloat
}

nonisolated struct CornerOffset: Equatable, Sendable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    init() {}

    init(_ proxy: GeometryProxy) {
        guard #available(iOS 26.0, *) else { return }
        let corners = proxy.containerCornerInsets
        leading = corners.topLeading.width
        trailing = corners.topTrailing.width
    }
}

/// The app's one bar: horizontal at the top, vertical beside the system's vertical bar, or a title header.
struct ChromeTopBar<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var fill = Chrome.topBar
    let leading: Leading
    let trailing: Trailing
    @Environment(\.chromeBarStyle) private var style
    @Environment(\.chromeBarShowsMark) private var showsMark
    @Environment(\.chromeBarBand) private var band
    @State private var reserved = ReservedArea()
    @State private var system = SystemBars()
    @State private var cornerOffset = CornerOffset()
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 52
    @ScaledMetric(relativeTo: .headline) private var headerHeight: CGFloat = 40

    @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 21

    private static var edge: CGFloat { 8 }
    private static var minimumSide: CGFloat { 96 }

    init(
        _ title: String, subtitle: String? = nil, fill: Color = Chrome.topBar,
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.fill = fill
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        switch style {
        case .horizontal:
            horizontalBar
        case .vertical(let side):
            verticalBar(on: side)
        case .header:
            headerBar
        }
    }

    private var horizontalBar: some View {
        // the system's corner offset already clears the corners, so the band adds only what it leaves uncovered
        horizontalItems
            .padding(.leading, max(0, (band?.leading ?? 0) - cornerOffset.leading))
            .padding(.trailing, max(0, (band?.trailing ?? 0) - cornerOffset.trailing))
            .padding(.horizontal, Self.edge)
            .windowControlsOffset()
            .frame(minHeight: band?.height ?? height)
            .frame(maxWidth: .infinity)
            .measuringReservedRegions(into: $reserved)
            .onGeometryChange(for: CornerOffset.self) { CornerOffset($0) } action: { cornerOffset = $0 }
            .background(fill.ignoresSafeArea(edges: [.top, .horizontal]))
            .overlay(alignment: .bottom) { Chrome.divider.frame(height: 1) }
            .accessibilityElement(children: .contain)
    }

    private var split: (left: CGFloat, gap: CGFloat)? {
        guard let seam = reserved.seam else { return nil }
        let left = seam.lowerBound - Self.edge
        let right = reserved.size.width - seam.upperBound - Self.edge
        guard left >= Self.minimumSide, right >= Self.minimumSide else { return nil }
        return (left, seam.upperBound - seam.lowerBound)
    }

    @ViewBuilder
    private var horizontalItems: some View {
        if let split {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    leading
                    titleView.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
                }
                .frame(width: split.left, alignment: .leading)
                Color.clear.frame(width: split.gap, height: 1)
                HStack(spacing: 6) { trailing }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: 6) {
                leading
                titleView.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
                trailing
            }
        }
    }

    private func verticalBar(on side: HorizontalEdge) -> some View {
        let outer: Edge.Set = side == .leading ? [.leading, .vertical] : [.trailing, .vertical]
        return ScrollView(.vertical, showsIndicators: false) {
            verticalItems
                .padding(.vertical, Self.edge)
                .frame(maxWidth: .infinity)
                .offset(x: columnOffset(on: side))
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .measuringReservedRegions(into: $reserved)
        .background(SystemBarReader { system = $0 })
        .background(fill.ignoresSafeArea(edges: outer))
        .overlay(alignment: side == .leading ? .trailing : .leading) {
            Chrome.divider.frame(width: 1).ignoresSafeArea(edges: .vertical)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var column: ReservedArea { reserved.adding(status: system.status, along: .vertical) }

    private func columnOffset(on side: HorizontalEdge) -> CGFloat {
        let width = reserved.size.width
        guard width > 0 else { return 0 }
        let bounds = CGRect(origin: .zero, size: reserved.size)
        if let bar = side == .leading ? system.leadingBar : system.trailingBar, bar.intersects(bounds) {
            return bar.midX - width / 2
        }
        let rail = min(Chrome.Metrics.railWidth, width)
        return side == .trailing ? (rail - width) / 2 : (width - rail) / 2
    }

    /// Where the vertical bar must skip a reserved row: either a gap between its two groups, or a lead-in above both.
    private var verticalGap: (above: CGFloat?, skip: CGFloat)? {
        let column = column
        guard let band = column.band else { return nil }
        let above = band.lowerBound - Self.edge
        let below = column.size.height - band.upperBound - Self.edge
        if above >= Self.minimumSide, below >= Self.minimumSide { return (above, band.upperBound - band.lowerBound) }
        if band.lowerBound < column.size.height / 2 { return (nil, max(0, band.upperBound - Self.edge)) }
        return nil
    }

    @ViewBuilder
    private var verticalItems: some View {
        if let gap = verticalGap, let above = gap.above {
            VStack(spacing: 0) {
                VStack(spacing: 6) { leading }
                    .frame(height: above, alignment: .top)
                Color.clear.frame(width: 1, height: gap.skip)
                VStack(spacing: 6) { trailing }
            }
        } else {
            VStack(spacing: 6) {
                leading.padding(.bottom, 10)
                trailing
            }
            .padding(.top, verticalGap?.skip ?? 0)
        }
    }

    private var headerBar: some View {
        titleView
            .padding(.horizontal, Self.edge)
            .frame(maxWidth: .infinity, minHeight: headerHeight, alignment: .leading)
            .background(fill.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) { Chrome.divider.frame(height: 1) }
    }

    private var titleView: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if showsMark {
                    Image("TurmMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: markSize, height: markSize)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Chrome.Typeface.barTitle)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(title.isEmpty && subtitle?.isEmpty != false)
    }
}

extension ChromeTopBar where Leading == EmptyView {
    init(_ title: String, subtitle: String? = nil, fill: Color = Chrome.topBar, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, subtitle: subtitle, fill: fill, leading: { EmptyView() }, trailing: trailing)
    }
}

extension ChromeTopBar where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, fill: Color = Chrome.topBar, @ViewBuilder leading: () -> Leading) {
        self.init(title, subtitle: subtitle, fill: fill, leading: leading, trailing: { EmptyView() })
    }
}

extension ChromeTopBar where Leading == EmptyView, Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, fill: Color = Chrome.topBar) {
        self.init(title, subtitle: subtitle, fill: fill, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// Reads the edge the system reserves for a vertical bar (iPhone Duo), nil where bars run horizontally.
struct ToolbarVerticalEdgeReader<Content: View>: View {
    let content: (HorizontalEdge?) -> Content

    init(@ViewBuilder content: @escaping (HorizontalEdge?) -> Content) {
        self.content = content
    }

    var body: some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            SystemVerticalEdge(content: content)
        } else {
            content(nil)
        }
        #else
        content(nil)
        #endif
    }
}

// the vertical bar API only exists in the iOS 27.1 SDK (SwiftUI 8.0.85); Xcode 27.0 has the same compiler but not the API
#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct SystemVerticalEdge<Content: View>: View {
    let content: (HorizontalEdge?) -> Content
    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View {
        content(edge)
    }
}
#endif

/// Places a bar in fixed slots so the content keeps its identity when the bar moves between edges.
struct ChromeBarPlacement<Bar: View>: ViewModifier {
    let bar: Bar
    let top: ChromeBarStyle?
    let side: HorizontalEdge?
    @State private var system = SystemBars()
    @State private var column = ViewBox()
    @State private var frame = CGRect.zero
    @State private var topInset: CGFloat = 0
    @ScaledMetric(relativeTo: .headline) private var barHeight: CGFloat = 52

    // a foldable's tall top inset has room beside the status bar, so the bar moves up into it
    private var band: ChromeBarBand? {
        guard top == .horizontal, topInset >= barHeight, let status = system.statusSpan(inTopInset: topInset) else { return nil }
        let width = frame.width
        let corner = Chrome.Metrics.cornerClearance
        let gap: CGFloat = 8
        let atLeft = frame.minX <= system.window.minX + 1
        let atRight = frame.maxX >= system.window.maxX - 1
        var leading = atLeft ? corner : 0
        var trailing = atRight ? corner : 0
        if status.lowerBound < width, status.upperBound > 0 {
            if status.lowerBound > width / 2 {
                trailing = max(trailing, width - status.lowerBound + gap)
            } else {
                leading = max(leading, status.upperBound + gap)
            }
        }
        guard width - leading - trailing >= Self.minimumWidth else { return nil }
        return ChromeBarBand(height: topInset, leading: leading, trailing: trailing)
    }

    private static var minimumWidth: CGFloat { 160 }

    func body(content: Content) -> some View {
        let band = band
        return content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let top, band == nil { bar.environment(\.chromeBarStyle, top) }
            }
            .safeAreaInset(edge: .leading, spacing: 0) {
                if side == .leading {
                    bar.environment(\.chromeBarStyle, .vertical(.leading)).frame(width: Chrome.Metrics.railWidth)
                }
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if side == .trailing {
                    bar.environment(\.chromeBarStyle, .vertical(.trailing)).frame(width: Chrome.Metrics.railWidth)
                }
            }
            .overlay(alignment: .top) {
                if let top, let band {
                    bar.environment(\.chromeBarStyle, top)
                        .environment(\.chromeBarBand, band)
                        .frame(height: band.height)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .background {
                if top == .horizontal { SystemBarReader { system = $0 }.ignoresSafeArea(edges: .top) }
            }
            .background(ViewProbe(box: column))
            .environment(\.chromeMenuColumn, top == nil ? nil : column)
            .onGeometryChange(for: CGRect.self) { CGRect(origin: .zero, size: $0.size) } action: { frame = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
    }
}

private struct ChromeBarHost<Bar: View>: ViewModifier {
    let bar: Bar
    let clearsCorners: Bool
    @Environment(\.chromeBarSuppressed) private var suppressed
    @Environment(\.chromeBarHorizontalOnly) private var horizontalOnly

    func body(content: Content) -> some View {
        ToolbarVerticalEdgeReader { edge in
            if suppressed {
                if clearsCorners { content.modifier(CornerClearance()) } else { content }
            } else if horizontalOnly {
                content.modifier(ChromeBarPlacement(bar: bar, top: .horizontal, side: nil))
            } else {
                content.modifier(ChromeBarPlacement(bar: bar, top: edge == nil ? .horizontal : .header, side: edge))
            }
        }
    }
}

extension View {
    @ViewBuilder
    func windowControlsOffset() -> some View {
        if #available(iOS 26.0, *) {
            containerCornerOffset(.horizontal, sizeToFit: true)
        } else {
            self
        }
    }
}

extension View {
    /// Replaces the system navigation bar with a solid bar and keeps swipe-back working beneath it.
    func chromeBar<Bar: View>(_ bar: Bar, clearsCorners: Bool = true) -> some View {
        modifier(ChromeBarHost(bar: bar, clearsCorners: clearsCorners))
            .toolbarVisibility(.hidden, for: .navigationBar)
            .background(PopGestureEnabler())
    }
}

private let popDelegateKey = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navigation: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigation?.viewControllers.count ?? 0) > 1
    }
}

private struct PopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Resolver {
        Resolver()
    }

    func updateUIViewController(_ controller: Resolver, context: Context) {}

    final class Resolver: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        private func install() {
            guard let navigation = navigationController, let recognizer = navigation.interactivePopGestureRecognizer else { return }
            if let existing = objc_getAssociatedObject(navigation, popDelegateKey) as? PopGestureDelegate {
                recognizer.delegate = existing
            } else {
                let delegate = PopGestureDelegate()
                delegate.navigation = navigation
                objc_setAssociatedObject(navigation, popDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                recognizer.delegate = delegate
            }
            recognizer.isEnabled = true
        }
    }
}

// with the status bar moved to the side the top inset is zero, so keep content clear of the display's rounded corners
private struct CornerClearance: ViewModifier {
    @State private var top: CGFloat = 0
    private static let minimum = Chrome.Metrics.cornerClearance

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: max(0, Self.minimum - top))
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top = $0 }
    }
}
