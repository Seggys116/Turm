import AppKit
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "turm.appearance"

    static var stored: AppearancePreference {
        UserDefaults.standard.string(forKey: key).flatMap(AppearancePreference.init) ?? .system
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    func apply(animated: Bool = false) {
        let overlays = animated ? Self.snapshotOverlays() : []
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        guard !overlays.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlays.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            overlays.forEach { $0.removeFromSuperview() }
        }
    }

    private static func snapshotOverlays() -> [NSView] {
        NSApp.windows.compactMap { window in
            guard window.isVisible, let content = window.contentView,
                  let host = content.superview,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { return nil }
            content.cacheDisplay(in: content.bounds, to: rep)
            let image = NSImage(size: content.bounds.size)
            image.addRepresentation(rep)
            let overlay = NSImageView(frame: content.frame)
            overlay.image = image
            overlay.imageScaling = .scaleAxesIndependently
            overlay.autoresizingMask = [.width, .height]
            host.addSubview(overlay, positioned: .above, relativeTo: content)
            return overlay
        }
    }
}

enum AppIconPreference: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark
    case clear

    static let key = "turm.appIcon"

    static var stored: AppIconPreference {
        UserDefaults.standard.string(forKey: key).flatMap(AppIconPreference.init) ?? .automatic
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        case .clear: "Clear"
        }
    }

    func assetName(isDark: Bool) -> String {
        switch self {
        case .automatic: isDark ? "AppIconDark" : "AppIconLight"
        case .light: "AppIconLight"
        case .dark: "AppIconDark"
        case .clear: isDark ? "AppIconClearDark" : "AppIconClearLight"
        }
    }

    func apply() {
        guard self != .automatic else {
            NSApp.applicationIconImage = nil
            return
        }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let art = NSImage(named: assetName(isDark: isDark)) else { return }
        NSApp.applicationIconImage = Self.dockIcon(from: art)
    }

    /// Exported renditions fill their canvas, so inset them to the 824pt macOS icon grid and add the system drop shadow.
    private static func dockIcon(from art: NSImage) -> NSImage {
        let side = 1024
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return art }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        art.draw(in: NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 100, dy: 100))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case about = "About"

    var id: Self { self }
}

struct SettingsView: View {
    let updater: Updater
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system
    @AppStorage(AppIconPreference.key) private var appIcon = AppIconPreference.automatic
    @AppStorage(SidebarPreference.key) private var isSidebarVisible = true
    @AppStorage(SidebarPlacement.key) private var sidebarPlacement = SidebarPlacement.left
    @AppStorage(ProjectActionsPreference.key) private var showsProjectActions = true
    @State private var tab = SettingsTab.appearance
    @Environment(\.openURL) private var openURL

    private static let repositoryURL = URL(string: "https://github.com/Seggys116/Turm")!
    private static let coffeeURL = URL(string: "https://www.buymeacoffee.com/seggy116")!
    private static let licensePreamble = """
        MIT License

        Copyright (c) 2026 Zak Noble-Clarke

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
        """

    private static let columnWidth: CGFloat = 680

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case .appearance: appearanceTab
                    case .about: aboutTab
                    }
                }
                .frame(maxWidth: Self.columnWidth, alignment: .topLeading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.terminalBackground.color)
        .onChange(of: appearance) { _, new in new.apply(animated: true) }
        .onChange(of: appIcon) { _, new in new.apply() }
    }

    @ViewBuilder
    private var appearanceTab: some View {
        section("Colour") {
            row("Theme", detail: "Follow the system or force a light or dark look.") {
                SlidingPicker(selection: $appearance, options: AppearancePreference.allCases, title: \.title)
                    .frame(width: 240)
            }
            row("App icon", detail: "Choose the Dock icon, or let it follow the system.") {
                AppIconPicker(selection: $appIcon)
            }
        }
        section("Layout") {
            row("Show sidebar", detail: "List your shells beside or above the terminal.") {
                Toggle("Show sidebar", isOn: $isSidebarVisible)
                    .labelsHidden()
                    .toggleStyle(SquareToggleStyle())
            }
            row("Sidebar position", detail: "Keep shells on the left, or as a tab bar under the title bar.") {
                SlidingPicker(selection: $sidebarPlacement, options: SidebarPlacement.allCases, title: \.title)
                    .frame(width: 240)
            }
            row("Project actions", detail: "Show build, run and test actions in a bar under a shell when it sits in a project. Add a Turm.json to customize them.") {
                Toggle("Project actions", isOn: $showsProjectActions)
                    .labelsHidden()
                    .toggleStyle(SquareToggleStyle())
            }
        }
    }

    @ViewBuilder
    private var aboutTab: some View {
        group {
            row("Turm", detail: versionDescription) { EmptyView() }
            row("Source code", detail: "github.com/Seggys116/Turm") {
                Button("View on GitHub") { openURL(Self.repositoryURL) }
                    .buttonStyle(SettingsButtonStyle())
            }
        }
        group {
            row("Turm is completely free", detail: "No ads, no accounts, no paywall. If it earns a place in your day, you can buy me a coffee.") {
                Button {
                    openURL(Self.coffeeURL)
                } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
            }
        }
        group {
            row("Check for updates automatically", detail: "Look for a new version in the background.") {
                Toggle("Check for updates automatically", isOn: Bindable(updater).automaticallyChecks)
                    .labelsHidden()
                    .toggleStyle(SquareToggleStyle())
            }
            row("Download updates automatically", detail: "Fetch new versions as soon as they are found.") {
                Toggle("Download updates automatically", isOn: Bindable(updater).automaticallyDownloads)
                    .labelsHidden()
                    .toggleStyle(SquareToggleStyle())
                    .disabled(!updater.automaticallyChecks)
            }
            row("Check now", detail: nil) {
                Button("Check for Updates...") { updater.check() }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!updater.canCheck)
            }
        }
        Text(Self.licensePreamble)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.chipStroke.color, lineWidth: 1))
            .textSelection(.enabled)
    }

    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText.color)
                .padding(.leading, 4)
            group(content: content)
        }
    }

    private func group(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(DividedLayout()) { content() }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.chipStroke.color, lineWidth: 1))
    }

    private func row(_ title: String, detail: String?, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text.color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText.color)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
    }
}

private struct DividedLayout: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                if index > 0 {
                    Rectangle().fill(Theme.subtleDivider.color).frame(height: 1)
                }
                child
            }
        }
    }
}

private enum SettingsMotion {
    static let slide = Animation.spring(duration: 0.32, bounce: 0.12)
    static let thumbFill = ThemeColor(light: 0xFFFFFF, dark: 0x303036)
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(SettingsMotion.slide) { selection = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == tab ? Theme.text.color : Theme.secondaryText.color)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.chipFill.color)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.chipStroke.color, lineWidth: 1))
                                    .matchedGeometryEffect(id: "tab", in: indicator)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider.color).frame(height: 1)
        }
    }
}

private struct SlidingPicker<Value: Hashable & Identifiable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: KeyPath<Value, String>
    @Namespace private var thumb

    private static var inset: CGFloat { 3 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(SettingsMotion.slide) { selection = option }
                } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.text.color : Theme.secondaryText.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(SettingsMotion.thumbFill.color)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chipStroke.color, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(Self.inset)
        .background(Theme.chipFill.color, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.chipStroke.color, lineWidth: 1))
    }
}

private struct AppIconPicker: View {
    @Binding var selection: AppIconPreference
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppIconPreference.allCases) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(SettingsMotion.slide) { selection = option }
                } label: {
                    VStack(spacing: 4) {
                        Image(option.assetName(isDark: colorScheme == .dark))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 44, height: 44)
                            .padding(3)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .opacity(isSelected ? 1 : 0)
                            )
                        Text(option.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSelected ? Theme.text.color : Theme.secondaryText.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.title) icon")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

private struct SquareToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        Button {
            withAnimation(SettingsMotion.slide) { configuration.isOn.toggle() }
        } label: {
            RoundedRectangle(cornerRadius: 8)
                .fill(isOn ? Color.accentColor : Theme.chipStroke.color)
                .frame(width: 42, height: 26)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 5.5)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .frame(width: 20, height: 20)
                        .padding(3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation { configuration.label.hidden(); Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Theme.text.color)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent
                        ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)
                        : (configuration.isPressed ? Theme.chipStroke.color : SettingsMotion.thumbFill.color))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.chipStroke.color, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
