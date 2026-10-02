import SwiftUI
import TurmCore

struct RemotePairingSheet: View {
    private enum Method: String, CaseIterable, Identifiable {
        case nearby = "Nearby"
        case address = "Other Address"
        case link = "Pairing Link"

        var id: String { rawValue }
    }

    var manager = RemoteMacManager.shared
    @State private var pairing = RemoteMacPairing()
    @State private var method: Method
    @State private var nearbyID: String?
    @State private var host = ""
    @State private var portText = String(Companion.defaultPort)
    @State private var code = ""
    @State private var link = ""
    @Environment(\.dismiss) private var dismiss

    init(preselected: DiscoveredRemoteMac? = nil) {
        _nearbyID = State(initialValue: preselected?.id)
        let anyNearby = !RemoteMacManager.shared.discovered.isEmpty
        _method = State(initialValue: preselected != nil || anyNearby ? .nearby : .address)
    }

    private var candidates: [DiscoveredRemoteMac] {
        manager.discovered.filter { $0.macID != RemoteMacIdentity.id }
    }

    private var chosen: DiscoveredRemoteMac? {
        candidates.first { $0.id == nearbyID } ?? candidates.first
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with a Mac")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            content
            HStack {
                Spacer(minLength: 0)
                switch pairing.state {
                case .done:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                default:
                    Button("Cancel") {
                        pairing.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SettingsButtonStyle())
                    if !pairing.isWorking {
                        Button("Pair", action: start)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(SettingsButtonStyle(prominent: true))
                            .disabled(!canStart)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.inputBackground.color)
        .onAppear { manager.beginDiscovery() }
        .onDisappear {
            pairing.cancel()
            manager.endDiscovery()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pairing.state {
        case .working(let text):
            progress(text)
        case .checking(let code, let macName):
            checking(code: code, macName: macName)
        case .done(let name):
            note("Paired with \(name).")
        case .idle, .failed:
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Method", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch method {
            case .nearby: nearbyFields
            case .address: addressFields
            case .link: linkFields
            }
            if case .failed(let text) = pairing.state {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var nearbyFields: some View {
        if candidates.isEmpty {
            hint("No Macs found nearby. Make sure Allow remote control is on in Turm on the other Mac, or use Other Address.")
        } else {
            Picker("Mac", selection: Binding(get: { chosen?.id ?? "" }, set: { nearbyID = $0 })) {
                ForEach(candidates) { Text($0.name).tag($0.id) }
            }
            codeField
            hint("On the other Mac, choose Pair a Device in Settings, then enter the 8-digit code it shows here.")
        }
    }

    private var addressFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Host or IP address", text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            }
            codeField
            hint("On the other Mac, choose Pair a Device in Settings, then enter the 8-digit code it shows here.")
        }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("turm-pair://...", text: $link)
                .textFieldStyle(.roundedBorder)
            hint("On the other Mac, choose Copy Pairing Link in Pair a Device, then paste it here.")
        }
    }

    private var codeField: some View {
        TextField("8-digit code", text: $code)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, design: .monospaced))
    }

    private var canStart: Bool {
        switch method {
        case .nearby: chosen != nil && !code.isEmpty
        case .address: !host.trimmingCharacters(in: .whitespaces).isEmpty && !code.isEmpty
        case .link: !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func start() {
        switch method {
        case .nearby:
            guard let chosen else { return }
            pairing.pair(discovered: chosen, code: Self.digits(code), manager: manager)
        case .address:
            guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) else {
                pairing.reject("Enter a port number from 1 to 65535.")
                return
            }
            pairing.pair(host: host, port: port, code: Self.digits(code), manager: manager)
        case .link:
            pairing.pair(link: link.trimmingCharacters(in: .whitespacesAndNewlines), manager: manager)
        }
    }

    private static func digits(_ text: String) -> String {
        text.filter(\.isNumber)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text.color)
        }
        .padding(.vertical, 24)
    }

    private func checking(code: String, macName: String) -> some View {
        VStack(spacing: 12) {
            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text.color)
            Text("Compare this code with the one on \(macName), then approve there.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text.color)
            .padding(.vertical, 24)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
