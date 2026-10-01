import Observation
import SwiftUI
import UIKit

struct ChromeMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String?
    var role: ButtonRole?
    var isOn = false
    var isEnabled = true
    var isNote = false
    var separated = false
    var action: () -> Void = {}

    static func note(_ title: String) -> ChromeMenuItem {
        ChromeMenuItem(title: title, isNote: true)
    }

    func separatedFromPrevious() -> ChromeMenuItem {
        var copy = self
        copy.separated = true
        return copy
    }
}

struct ChromeDialogSpec {
    struct Field {
        var placeholder: String
        var text = ""
        var keyboard = UIKeyboardType.default
    }

    struct Action: Identifiable {
        let id = UUID()
        var title: String
        var role: ButtonRole?
        var handler: (String) -> Void = { _ in }
    }

    var title: String
    var message: String?
    var field: Field?
    var actions: [Action]

    static func confirmation(
        title: String, message: String?, confirm: String, destructive: Bool = true, handler: @escaping () -> Void
    ) -> ChromeDialogSpec {
        ChromeDialogSpec(
            title: title,
            message: message,
            actions: [
                Action(title: "Cancel", role: .cancel),
                Action(title: confirm, role: destructive ? .destructive : nil) { _ in handler() },
            ]
        )
    }

    static func notice(title: String, message: String?) -> ChromeDialogSpec {
        ChromeDialogSpec(title: title, message: message, actions: [Action(title: "OK")])
    }
}

@MainActor
final class ViewBox {
    weak var view: UIView?
}

struct ViewProbe: UIViewRepresentable {
    let box: ViewBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        box.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        box.view = view
    }
}

@Observable
final class ChromeOverlays {
    struct MenuState {
        let id = UUID()
        var items: [ChromeMenuItem]
        var anchor: CGRect
    }

    struct DialogState {
        let token: UUID
        var spec: ChromeDialogSpec
        var onDismiss: () -> Void
    }

    private(set) var menu: MenuState?
    private(set) var dialog: DialogState?
    @ObservationIgnored let hostBox = ViewBox()

    private static var spring: Animation { .spring(duration: 0.3, bounce: 0.12) }

    func present(menu items: [ChromeMenuItem], from view: UIView?) {
        guard let view, view.window != nil, let host = hostBox.view else { return }
        let anchor = view.convert(view.bounds, to: host)
        withAnimation(Self.spring) { menu = MenuState(items: items, anchor: anchor) }
    }

    func dismissMenu() {
        guard menu != nil else { return }
        withAnimation(Self.spring) { menu = nil }
    }

    func present(dialog spec: ChromeDialogSpec, token: UUID, onDismiss: @escaping () -> Void) {
        dismissMenu()
        withAnimation(Self.spring) { dialog = DialogState(token: token, spec: spec, onDismiss: onDismiss) }
    }

    func dismissDialog(token: UUID) {
        guard dialog?.token == token else { return }
        withAnimation(Self.spring) { dialog = nil }
    }

    func finish(_ action: ChromeDialogSpec.Action?, text: String) {
        guard let state = dialog else { return }
        withAnimation(Self.spring) { dialog = nil }
        action?.handler(text)
        state.onDismiss()
    }
}

extension EnvironmentValues {
    @Entry var chromeOverlays: ChromeOverlays?
}

extension View {
    /// Hosts the themed menu and dialog layers; presentation roots (the window and each sheet) install one.
    func chromeOverlayHost() -> some View {
        modifier(ChromeOverlayHost())
    }

    func chromeContextMenu(_ items: @escaping () -> [ChromeMenuItem]) -> some View {
        modifier(ChromeContextMenu(items: items))
    }

    func chromeDialog(isPresented: Binding<Bool>, _ spec: @escaping () -> ChromeDialogSpec) -> some View {
        modifier(ChromeDialogPresenter(isPresented: isPresented, spec: spec))
    }
}

private struct ChromeOverlayHost: ViewModifier {
    @State private var overlays = ChromeOverlays()
    @State private var area = ReservedArea()

    func body(content: Content) -> some View {
        content
            .environment(\.chromeOverlays, overlays)
            .overlay {
                ZStack {
                    Color.clear
                        .allowsHitTesting(false)
                        .background(ViewProbe(box: overlays.hostBox))
                    if let menu = overlays.menu {
                        MenuLayer(state: menu, area: area, dismiss: overlays.dismissMenu)
                            .id(menu.id)
                    }
                    if let dialog = overlays.dialog {
                        DialogLayer(state: dialog, area: area, finish: overlays.finish)
                            .id(dialog.token)
                    }
                }
                .measuringReservedRegions(into: $area)
            }
            .onChange(of: area.size) { overlays.dismissMenu() }
    }
}

private struct MenuLayer: View {
    let state: ChromeOverlays.MenuState
    let area: ReservedArea
    let dismiss: () -> Void
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 264

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityLabel("Dismiss menu")
                .accessibilityAddTraits(.isButton)
            MenuPlacement(
                anchor: state.anchor,
                free: area.freeRect(containing: CGPoint(x: state.anchor.midX, y: state.anchor.midY))
                    ?? CGRect(origin: .zero, size: area.size),
                width: width
            ) {
                ChromeMenuPanel(items: state.items, dismiss: dismiss)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: UnitPoint(x: state.anchor.midX / max(area.size.width, 1), y: state.anchor.midY / max(area.size.height, 1)))))
    }
}

private struct MenuPlacement: Layout {
    let anchor: CGRect
    let free: CGRect
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let limit = free.insetBy(dx: margin, dy: margin)
        guard limit.width > 0, limit.height > 0 else { return }
        let proposed = ProposedViewSize(width: min(width, limit.width), height: limit.height)
        let size = panel.sizeThatFits(proposed)
        let below = limit.maxY - anchor.maxY - gap
        let above = anchor.minY - gap - limit.minY
        let goUp = below < size.height && above > below
        let height = min(size.height, limit.height)
        let wide = anchor.width > limit.width * 0.6
        let x: CGFloat
        if wide {
            x = anchor.midX - size.width / 2
        } else if anchor.midX > free.midX {
            x = anchor.maxX - size.width
        } else {
            x = anchor.minX
        }
        let y = goUp ? anchor.minY - gap - height : anchor.maxY + gap
        let origin = CGPoint(
            x: min(max(x, limit.minX), max(limit.minX, limit.maxX - size.width)),
            y: min(max(y, limit.minY), max(limit.minY, limit.maxY - height))
        )
        panel.place(
            at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
            proposal: ProposedViewSize(width: size.width, height: height)
        )
    }
}

private struct ChromeMenuPanel: View {
    let items: [ChromeMenuItem]
    let dismiss: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(Chrome.inputBackground, in: Chrome.cardShape(minimum: Chrome.Radius.group))
        .overlay(Chrome.cardShape(minimum: Chrome.Radius.group).stroke(Chrome.chipStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                if item.separated {
                    Rectangle().fill(Chrome.subtleDivider).frame(height: 1).padding(.vertical, 3).padding(.horizontal, 6)
                }
                if item.isNote {
                    Text(item.title)
                        .font(Chrome.Typeface.caption)
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ChromeMenuRow(item: item, dismiss: dismiss)
                }
            }
        }
    }
}

private struct ChromeMenuRow: View {
    let item: ChromeMenuItem
    let dismiss: () -> Void

    private var tint: Color { item.role == .destructive ? Chrome.failure : Chrome.text }

    var body: some View {
        Button {
            dismiss()
            Haptics.select()
            item.action()
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let image = item.systemImage {
                        Image(systemName: image)
                    } else if item.isOn {
                        Image(systemName: "checkmark")
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.role == .destructive ? Chrome.failure : Chrome.secondaryText)
                .frame(width: 20)
                Text(item.title)
                    .font(Chrome.Typeface.body)
                    .foregroundStyle(tint)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if item.isOn, item.systemImage != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(item.isOn ? .isSelected : [])
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Chrome.Radius.chip)
                    .fill(configuration.isPressed ? Chrome.accent.opacity(0.22) : Color.clear)
            )
    }
}

private struct DialogLayer: View {
    let state: ChromeOverlays.DialogState
    let area: ReservedArea
    let finish: (ChromeDialogSpec.Action?, String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(state: ChromeOverlays.DialogState, area: ReservedArea, finish: @escaping (ChromeDialogSpec.Action?, String) -> Void) {
        self.state = state
        self.area = area
        self.finish = finish
        _text = State(initialValue: state.spec.field?.text ?? "")
    }

    private var spec: ChromeDialogSpec { state.spec }
    private var cancel: ChromeDialogSpec.Action? { spec.actions.first { $0.role == .cancel } }
    private var primary: ChromeDialogSpec.Action? { spec.actions.last { $0.role != .cancel } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if let cancel { finish(cancel, text) } }
                .accessibilityHidden(true)
            ScrollView {
                card
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
            .confined(to: area)
        }
        .transition(.opacity)
        .onAppear {
            if spec.field != nil { focused = true }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(spec.title)
                    .font(Chrome.Typeface.barTitle)
                    .foregroundStyle(Chrome.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message = spec.message {
                    Text(message)
                        .font(Chrome.Typeface.label)
                        .foregroundStyle(Chrome.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let field = spec.field {
                TextField(field.placeholder, text: $text)
                    .promptField()
                    .focused($focused)
                    .keyboardType(field.keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { if let primary { finish(primary, text) } }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(spacing: 8) { buttons }
            }
        }
        .padding(18)
        .frame(maxWidth: 380)
        .background(Chrome.topBar, in: Chrome.cardShape())
        .overlay(Chrome.cardShape().stroke(Chrome.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { if let cancel { finish(cancel, text) } }
    }

    private var buttons: some View {
        ForEach(spec.actions.sorted { ($0.role == .cancel ? 0 : 1) < ($1.role == .cancel ? 0 : 1) }) { action in
            Button {
                Haptics.tap()
                finish(action, text)
            } label: {
                Text(action.title).frame(maxWidth: .infinity)
            }
            .buttonStyle(ChromeButtonStyle(kind: kind(of: action)))
        }
    }

    private func kind(of action: ChromeDialogSpec.Action) -> ChromeButtonStyle.Kind {
        if action.role == .cancel { return .plain }
        return action.role == .destructive ? .destructive : .prominent
    }
}

private struct ChromeDialogPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let spec: () -> ChromeDialogSpec
    @Environment(\.chromeOverlays) private var overlays
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, shown in
            if shown {
                overlays?.present(dialog: spec(), token: token) { isPresented = false }
            } else {
                overlays?.dismissDialog(token: token)
            }
        }
    }
}

struct ChromeMenuTrigger<Label: View>: View {
    let items: () -> [ChromeMenuItem]
    let label: Label
    @Environment(\.chromeOverlays) private var overlays
    @State private var box = ViewBox()

    init(items: @escaping () -> [ChromeMenuItem], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    var body: some View {
        Button {
            Haptics.tap()
            overlays?.present(menu: items(), from: box.view)
        } label: {
            label
        }
        .buttonStyle(ChromePressStyle())
        .background(ViewProbe(box: box))
        .accessibilityHint("Opens a menu")
    }
}

struct ChromeMenuButton: View {
    let systemImage: String
    let label: String
    let items: () -> [ChromeMenuItem]

    var body: some View {
        ChromeMenuTrigger(items: items) {
            ChromeIconLabel(systemImage: systemImage)
        }
        .accessibilityLabel(label)
    }
}

private struct ChromeContextMenu: ViewModifier {
    let items: () -> [ChromeMenuItem]
    @Environment(\.chromeOverlays) private var overlays
    @State private var box = ViewBox()

    func body(content: Content) -> some View {
        content
            .background(ViewProbe(box: box))
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 12) { present() }
            .accessibilityAction(named: "More actions") { present() }
    }

    private func present() {
        Haptics.press()
        overlays?.present(menu: items(), from: box.view)
    }
}
