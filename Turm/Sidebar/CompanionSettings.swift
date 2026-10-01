import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TurmCore

struct CompanionSettings: View {
    let updater: Updater
    var server = CompanionServer.shared
    var devices = PairedDevices.shared
    @AppStorage(CompanionServer.enabledKey) private var enabled = false
    @AppStorage(CompanionServer.portKey) private var storedPort = Int(Companion.defaultPort)
    @State private var portText = ""
    @State private var addresses: [CompanionAddresses.Entry] = []
    @State private var pairing = false

    private var portValue: Int? {
        Int(portText).flatMap { (1024...65535).contains($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            accessSection
            if enabled { addressSection }
            devicesSection
            Text("Phones talk to this Mac over an encrypted connection that only paired devices can open. A paired phone can run commands in your shells, so only pair devices you control, and revoke any you stop using.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
        .onAppear {
            portText = String(server.port)
            addresses = CompanionAddresses.local()
        }
        .sheet(isPresented: $pairing) { CompanionPairingSheet() }
    }

    private var accessSection: some View {
        SettingsSection("Remote Access") {
            SettingsFormRow("Allow remote control", detail: statusText) {
                Toggle("Allow remote control", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(SquareToggleStyle())
                    .onChange(of: enabled) { _, _ in server.settingsChanged() }
            }
            SettingsFormRow("Port", detail: portValue == nil ? "Use a number from 1024 to 65535." : "Press Return to apply.") {
                TextField("\(Companion.defaultPort)", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit(applyPort)
            }
        }
    }

    private var addressSection: some View {
        SettingsSection("Reachable at") {
            ForEach(addresses, id: \.address) { entry in
                SettingsFormRow("\(entry.address):\(server.port)", detail: entry.isTailscale ? "Tailscale" : "Local network, \(entry.interface)") {
                    copyButton("\(entry.address):\(server.port)")
                }
            }
            SettingsFormRow("\(CompanionAddresses.hostname):\(server.port)", detail: "Hostname") {
                copyButton("\(CompanionAddresses.hostname):\(server.port)")
            }
        }
    }

    private var devicesSection: some View {
        SettingsSection("Paired devices") {
            if devices.devices.isEmpty {
                SettingsFormRow("None yet", detail: "Pair a phone to control this Mac's shells.") { EmptyView() }
            }
            ForEach(devices.devices) { device in
                SettingsFormRow(device.name, detail: detail(of: device)) {
                    HStack(spacing: 8) {
                        if server.updateNotices[device.id]?.macIsOutdated == true {
                            Button("Check for Updates...") { updater.check() }
                                .buttonStyle(SettingsButtonStyle(prominent: true))
                                .disabled(!updater.canCheck)
                        }
                        Button("Revoke") { devices.revoke(device.id) }
                            .buttonStyle(SettingsButtonStyle())
                    }
                }
            }
            SettingsFormRow("Pair a device", detail: enabled ? "Shows a QR code and a code that work for two minutes." : "Turn on remote control first.") {
                Button("Pair a Device...") { pairing = true }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!enabled || server.status == .off)
            }
        }
    }

    private var statusText: String {
        switch server.status {
        case .off: "Off"
        case .starting: "Starting..."
        case .listening(let port): "Listening on port \(port)"
        case .failed(let message): message
        }
    }

    private func detail(of device: CompanionPeerRecord) -> String {
        let paired = "Paired " + device.created.formatted(date: .abbreviated, time: .omitted)
        let state = server.liveDevices.contains(device.id) ? paired + "  ·  Connected" : paired
        return server.updateNotices[device.id].map { state + "\n" + $0.text } ?? state
    }

    private func copyButton(_ text: String) -> some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .buttonStyle(SettingsButtonStyle())
    }

    private func applyPort() {
        guard let value = portValue else { return }
        storedPort = value
        if enabled { server.settingsChanged() }
    }
}

private struct CompanionPairingSheet: View {
    var server = CompanionServer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.color)
            if let window = server.pairing {
                active(window)
            } else {
                finished
            }
            HStack {
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(SettingsButtonStyle(prominent: true))
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.inputBackground.color)
        .onAppear { server.beginPairing() }
        .onDisappear { server.endPairing() }
    }

    @ViewBuilder
    private func active(_ window: CompanionServer.PairingWindow) -> some View {
        if let pending = window.pending {
            approval(pending)
        } else {
            waiting(window)
        }
    }

    private func approval(_ pending: CompanionServer.PendingApproval) -> some View {
        VStack(spacing: 14) {
            Text("\(pending.deviceName) wants to pair")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text.color)
            Text(pending.code)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text.color)
            Text("Approve only if your phone shows this same number. If it differs, or you did not start pairing, reject.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Reject") { server.rejectPairing() }
                    .buttonStyle(SettingsButtonStyle())
                Button("Approve") { server.approvePairing() }
                    .buttonStyle(SettingsButtonStyle(prominent: true))
            }
        }
    }

    private func waiting(_ window: CompanionServer.PairingWindow) -> some View {
        VStack(spacing: 14) {
            if let url = window.payload.url?.absoluteString {
                PairingQR(text: url)
            }
            Text("Scan this in Turm on your phone, or choose Enter Code there.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .multilineTextAlignment(.center)
            Text(Self.grouped(window.code))
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .textSelection(.enabled)
            Text(window.payload.hosts.prefix(2).map { "\($0):\(window.payload.port)" }.joined(separator: "   "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText.color)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(window.payload.expires.timeIntervalSince(context.date).rounded(.up)))
                Text(window.inUse ? "Pairing..." : String(format: "Expires in %d:%02d", remaining / 60, remaining % 60))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.color)
            }
            if window.failures > 0 {
                Text("\(window.failures) of \(CompanionServer.maxFailures) attempts used.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure.color)
            }
        }
    }

    @ViewBuilder
    private var finished: some View {
        switch server.outcome {
        case .paired(let name):
            note("Paired with \(name).")
        case .expired:
            retry("The code expired.")
        case .tooManyAttempts:
            retry("Too many wrong attempts.")
        case nil:
            note("Remote control is not running.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text.color)
            .padding(.vertical, 24)
    }

    private func retry(_ text: String) -> some View {
        VStack(spacing: 12) {
            note(text)
            Button("New Code") { server.beginPairing() }
                .buttonStyle(SettingsButtonStyle())
        }
    }

    private static func grouped(_ code: String) -> String {
        code.count == 8 ? String(code.prefix(4)) + " " + String(code.suffix(4)) : code
    }
}

private struct PairingQR: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 190, height: 190)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Pairing QR code")
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
