import ObjectiveC
import SwiftUI
import UIKit

struct ChromePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
    @State private var reserved = ReservedArea()
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
        horizontalItems
            .padding(.horizontal, Self.edge)
            .windowControlsOffset()
            .frame(minHeight: height)
            .frame(maxWidth: .infinity)
            .measuringReservedRegions(into: $reserved)
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
                    titleView.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: split.left, alignment: .leading)
                Color.clear.frame(width: split.gap, height: 1)
                HStack(spacing: 6) { trailing }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: 6) {
                leading
                titleView.frame(maxWidth: .infinity, alignment: .leading)
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
                .offset(x: reserved.columnOffset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .measuringReservedRegions(into: $reserved)
        .background(fill.ignoresSafeArea(edges: outer))
        .overlay(alignment: side == .leading ? .trailing : .leading) {
            Chrome.divider.frame(width: 1).ignoresSafeArea(edges: .vertical)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// Where the vertical bar must skip a reserved row: either a gap between its two groups, or a lead-in above both.
    private var verticalGap: (above: CGFloat?, skip: CGFloat)? {
        guard let band = reserved.band else { return nil }
        let above = band.lowerBound - Self.edge
        let below = reserved.size.height - band.upperBound - Self.edge
        if above >= Self.minimumSide, below >= Self.minimumSide { return (above, band.upperBound - band.lowerBound) }
        if band.lowerBound < reserved.size.height / 2 { return (nil, max(0, band.upperBound - Self.edge)) }
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
                leading
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
        #if compiler(>=6.4)
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

// the vertical bar API only exists in the iOS 27.1 SDK, which ships with the Swift 6.4 compiler
#if compiler(>=6.4)
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

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let top { bar.environment(\.chromeBarStyle, top) }
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
    }
}

private struct ChromeBarHost<Bar: View>: ViewModifier {
    let bar: Bar
    @Environment(\.chromeBarSuppressed) private var suppressed

    func body(content: Content) -> some View {
        ToolbarVerticalEdgeReader { edge in
            if suppressed {
                content.modifier(CornerClearance())
            } else {
                content.modifier(ChromeBarPlacement(bar: bar, top: edge == nil ? .horizontal : .header, side: edge))
            }
        }
    }
}

private extension View {
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
    func chromeBar<Bar: View>(_ bar: Bar) -> some View {
        modifier(ChromeBarHost(bar: bar))
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
    private static let minimum: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: max(0, Self.minimum - top))
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top = $0 }
    }
}
