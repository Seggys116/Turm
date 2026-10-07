import SwiftUI

struct ChromeSectionAction {
    let systemImage: String
    let label: String
    let handler: () -> Void
}

struct ChromeSectionHeader: View {
    let title: String
    var action: ChromeSectionAction?

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(Chrome.Typeface.section)
                .tracking(0.6)
                .foregroundStyle(Chrome.secondaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let action {
                Button {
                    Haptics.tap()
                    action.handler()
                } label: {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChromePressStyle())
                .accessibilityLabel(action.label)
            }
        }
        .padding(.leading, 6)
    }
}

struct ChromeSection<Content: View>: View {
    let title: String
    var footer: String?
    var action: ChromeSectionAction?
    let content: Content

    init(_ title: String, footer: String? = nil, action: ChromeSectionAction? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSectionHeader(title: title, action: action)
            ChromeGroup { content }
            if let footer {
                Text(footer)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ChromeGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(DividedLayout()) { content }
        }
        .frame(maxWidth: .infinity)
        .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.group))
        .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.group).stroke(Chrome.chipStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Chrome.Radius.group))
    }
}

private struct DividedLayout: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                if index > 0 {
                    Rectangle().fill(Chrome.subtleDivider).frame(height: 1)
                }
                child
            }
        }
    }
}

struct ChromeRow<Control: View>: View {
    let title: String
    var detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                text.frame(minWidth: 0, idealWidth: 150, maxWidth: .infinity, alignment: .leading)
                control
            }
            VStack(alignment: .leading, spacing: 10) {
                text
                control
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 52)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Chrome.Typeface.body)
                .foregroundStyle(Chrome.text)
            if let detail {
                Text(detail)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ChromeFieldRow<Field: View>: View {
    let title: String
    let field: Field

    init(_ title: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Chrome.Typeface.body)
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 88, alignment: .leading)
            field
                .font(Chrome.Typeface.monoBody)
                .foregroundStyle(Chrome.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }
}

struct ChromeSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    guard selection != option.value else { return }
                    Haptics.select()
                    withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(Chrome.Typeface.label)
                        .foregroundStyle(selection == option.value ? Chrome.text : Chrome.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if selection == option.value {
                                RoundedRectangle(cornerRadius: Chrome.Radius.chip - 2)
                                    .fill(Chrome.topBar)
                                    .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip - 2).stroke(Chrome.chipStroke, lineWidth: 1))
                                    .matchedGeometryEffect(id: "segment", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                        .chromeHover(cornerRadius: Chrome.Radius.chip - 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip).stroke(Chrome.chipStroke, lineWidth: 1))
    }
}

struct ChromeMenuField: View {
    let value: String
    let label: String
    let items: () -> [ChromeMenuItem]

    var body: some View {
        ChromeMenuTrigger(items: items) {
            HStack(spacing: 8) {
                Text(value)
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip).stroke(Chrome.chipStroke, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct ChromeActionRow: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role) {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title).font(Chrome.Typeface.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(role == .destructive ? Chrome.failure : Chrome.text)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Chrome.chipFill : Color.clear)
            .chromeHover()
    }
}

struct ChromeButtonStyle: ButtonStyle {
    enum Kind {
        case plain
        case prominent
        case destructive
    }

    var kind = Kind.plain
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind, compact: compact)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var enabled

        private var foreground: Color {
            switch kind {
            case .plain: Chrome.text
            case .prominent: Chrome.onAccent
            case .destructive: Chrome.failure
            }
        }

        private var fill: Color {
            switch kind {
            case .prominent: Chrome.accent.opacity(configuration.isPressed ? 0.8 : 1)
            default: configuration.isPressed ? Color(uiColor: Chrome.UI.chipFillPressed) : Chrome.chipFill
            }
        }

        var body: some View {
            configuration.label
                .font(Chrome.Typeface.label)
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 12 : 14)
                .frame(minHeight: compact ? 34 : Chrome.Metrics.target)
                .background(fill, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Chrome.Radius.chip)
                        .stroke(kind == .prominent ? Color.clear : Chrome.chipStroke, lineWidth: 1)
                )
                .padding(.vertical, compact ? 5 : 0)
                .contentShape(Rectangle())
                .chromeHover()
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

struct StatusDot: View {
    let color: Color
    var filled = true
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(filled ? color : Color.clear)
            .overlay(Circle().stroke(color, lineWidth: filled ? 0 : 1.5))
            .frame(width: size, height: size)
    }
}

struct ChromeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Chrome.chipStroke, lineWidth: 1))
    }
}

struct ChromeScroll<Content: View>: View {
    let spacing: CGFloat
    let maxWidth: CGFloat
    let content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(spacing: CGFloat = 24, maxWidth: CGFloat = Chrome.Metrics.readableWidth, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        let margin = Chrome.Metrics.margin(for: sizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, margin)
                .padding(.vertical, margin)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .closesSwipeRowsOnScroll()
        .background(Chrome.sidebar.ignoresSafeArea())
    }
}

private struct ChromeHover: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius))
            .hoverEffect(.highlight)
            .hoverEffectDisabled(!enabled)
    }
}

private extension View {
    // sheets keep their bar on top, so the system keeps it clear of the camera and status bar
    @ViewBuilder
    func sheetVerticalBarDisabled() -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    func chromeHover(cornerRadius: CGFloat = Chrome.Radius.chip) -> some View {
        modifier(ChromeHover(cornerRadius: cornerRadius))
    }

    func promptField(mono: Bool = true) -> some View {
        self
            .font(mono ? Chrome.Typeface.monoBody : Chrome.Typeface.body)
            .foregroundStyle(Chrome.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Chrome.inputBackground, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip).stroke(Chrome.chipStroke, lineWidth: 1))
    }

    func chromeTap(action: @escaping () -> Void) -> some View {
        self
            .contentShape(Rectangle())
            .chromeHover()
            .onTapGesture {
                Haptics.select()
                action()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }

    func chromeSheet() -> some View {
        self
            .environment(\.chromeBarSuppressed, false)
            .environment(\.chromeBarHorizontalOnly, true)
            .sheetVerticalBarDisabled()
            .chromeOverlayHost()
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(Chrome.sidebar)
            .presentationCornerRadius(22)
            .tint(Chrome.accent)
            .toggleStyle(ChromeToggleStyle())
    }
}

struct ChromeToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsVisibility) private var labels

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        HStack {
            if labels != .hidden {
                configuration.label
                Spacer(minLength: 12)
            }
            RoundedRectangle(cornerRadius: 9)
                .fill(isOn ? Chrome.accent : Chrome.chipStroke)
                .frame(width: 48, height: 30)
                .chromeHover(cornerRadius: 9)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 6.5)
                        .fill(isOn ? Chrome.onAccent : Color.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .frame(width: 24, height: 24)
                        .padding(3)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            Haptics.tap()
            withAnimation(.spring(duration: 0.25)) { configuration.isOn.toggle() }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
