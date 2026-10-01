import SwiftUI
import TurmCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChromeScroll {
                AppearanceSection()
                KeyBarSection()
                SSHKeysSection()
                TrustedHostsSection()
                RemoteAccessSection()
                ICloudSection()
                AboutSection()
            }
            .chromeBar(ChromeTopBar("Settings", trailing: { ChromeBarButton(title: "Done", systemImage: "checkmark", kind: .prominent) { dismiss() } }))
        }
        .chromeSheet()
    }
}

private struct AppearanceSection: View {
    @Bindable private var preferences = TerminalPreferences.shared

    var body: some View {
        ChromeSection("Appearance") {
            ChromeRow("Font Size", detail: "Pinch the terminal to change it too.") {
                SizeStepper(value: $preferences.fontSize, range: TerminalPreferences.sizes)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("user@host:~$ ls -la")
                Text("drwxr-xr-x  turm  src")
                    .foregroundStyle(Chrome.secondaryText)
            }
            .font(.system(size: preferences.fontSize, design: .monospaced))
            .foregroundStyle(Chrome.text)
            .lineLimit(1)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Chrome.terminalBackground)
            ChromeRow("Theme") {
                Text("Matches system")
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
    }
}

private struct AboutSection: View {
    @Environment(\.openURL) private var openURL

    private static let privacyURL = URL(string: "https://turm.sh/privacy")!
    private static let supportURL = URL(string: "https://turm.sh/support")!

    var body: some View {
        ChromeSection("About") {
            ChromeActionRow("Privacy Policy", systemImage: "hand.raised") { openURL(Self.privacyURL) }
            ChromeActionRow("Support", systemImage: "questionmark.circle") { openURL(Self.supportURL) }
            AcknowledgementsRow()
        }
    }
}

private struct SizeStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", delta: -1, enabled: value > range.lowerBound)
            Text("\(Int(value)) pt")
                .font(Chrome.Typeface.mono)
                .foregroundStyle(Chrome.text)
                .monospacedDigit()
                .frame(minWidth: 52)
            stepButton("plus", delta: 1, enabled: value < range.upperBound)
        }
        .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.chip).stroke(Chrome.chipStroke, lineWidth: 1))
    }

    private func stepButton(_ symbol: String, delta: Double, enabled: Bool) -> some View {
        Button {
            Haptics.select()
            value += delta
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Chrome.text)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }
}

private struct TrustedHostsSection: View {
    private let known = SSHKnownHosts.shared

    var body: some View {
        if !known.entries.isEmpty {
            ChromeSection("Trusted Hosts", footer: "Turm warns and refuses to connect if a host presents a different key.") {
                ForEach(known.entries.keys.sorted(), id: \.self) { name in
                    ChromeSwipeRow(actions: [
                        ChromeSwipeAction(title: "Forget", systemImage: "trash", role: .destructive) { forget(name) },
                    ]) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name)
                                    .font(Chrome.Typeface.monoBody)
                                    .foregroundStyle(Chrome.text)
                                    .lineLimit(1)
                                Text(known.entries[name].flatMap(SSHKnownHosts.fingerprint(ofKeyLine:)) ?? "")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Chrome.secondaryText)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Button {
                                Haptics.tap()
                                forget(name)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Chrome.failure)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(ChromePressStyle())
                            .accessibilityLabel("Forget \(name)")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(minHeight: 56)
                    }
                }
            }
        }
    }

    private func forget(_ name: String) {
        guard let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { return }
        known.forget(host: String(name[..<colon]), port: port)
    }
}
