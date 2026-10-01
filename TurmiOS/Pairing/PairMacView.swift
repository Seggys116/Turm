import SwiftUI
import TurmCore

struct PairMacView: View {
    var manager = MacManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = MacPairing()
    @State private var mode = Mode.scan
    @State private var host = ""
    @State private var port = String(Companion.defaultPort)
    @State private var code = ""
    @State private var choice = Choice.address

    private enum Mode: Hashable {
        case scan
        case code
    }

    private enum Choice: Hashable {
        case address
        case nearby(String)
    }

    private var portValue: UInt16? {
        UInt16(port.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private var nearby: DiscoveredMac? {
        guard case .nearby(let id) = choice else { return nil }
        return unpaired.first { $0.id == id }
    }

    private var unpaired: [DiscoveredMac] {
        let known = Set(manager.connections.map(\.id))
        return manager.discovered.filter { $0.macID.map { !known.contains($0) } ?? true }
    }

    private var canPair: Bool {
        guard !pairing.isWorking, CompanionCrypto.isValidCode(code) else { return false }
        if nearby != nil { return true }
        return !host.trimmingCharacters(in: .whitespaces).isEmpty && portValue != nil
    }

    var body: some View {
        ChromeScroll {
            ChromeSegmented(options: [(Mode.scan, "Scan QR Code"), (Mode.code, "Enter Code")], selection: $mode)
            if mode == .scan {
                scanSection
            } else {
                codeSection
            }
            statusSection
        }
        .chromeBar(
            ChromeTopBar("Pair a Mac", trailing: {
                ChromeBarButton(title: "Cancel", systemImage: "xmark") {
                    pairing.cancel()
                    dismiss()
                }
            })
        )
        .onChange(of: pairing.state) { _, state in
            switch state {
            case .done:
                Haptics.confirm()
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    dismiss()
                }
            case .failed:
                Haptics.warn()
            case .checking:
                Haptics.tap()
            default:
                break
            }
        }
        .onChange(of: mode) { _, _ in pairing.reset() }
        .chromeSheet()
        .interactiveDismissDisabled(pairing.isWorking)
    }

    @ViewBuilder
    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if QRScannerView.isUsable {
                    ZStack {
                        QRScannerView(onCode: handleScan)
                        ScannerFrame()
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.metering.unknown")
                            .font(.system(size: 30))
                            .foregroundStyle(Chrome.secondaryText)
                        Text("The camera is not available to Turm. Allow camera access in Settings, or enter the code shown on the Mac.")
                            .font(Chrome.Typeface.caption)
                            .foregroundStyle(Chrome.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Enter Code Instead") { mode = .code }
                            .buttonStyle(ChromeButtonStyle())
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Chrome.chipFill)
                }
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: Chrome.Radius.group + 4))
            .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.group + 4).stroke(Chrome.chipStroke, lineWidth: 1))
            Text("On the Mac, open Turm Settings, choose Remote Access and click Pair a Device.")
                .font(Chrome.Typeface.caption)
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var codeSection: some View {
        ChromeSection("Mac") {
            ForEach(unpaired) { mac in
                choiceRow(mac.name, selected: choice == .nearby(mac.id)) { choice = .nearby(mac.id) }
            }
            choiceRow("Other Address", selected: nearby == nil) { choice = .address }
            if nearby == nil {
                ChromeFieldRow("Address") {
                    TextField("Name or Tailscale name", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                ChromeFieldRow("Port") {
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
            }
        }
        ChromeSection("Code", footer: "The code is shown on the Mac for two minutes while pairing is open.") {
            ChromeFieldRow("Code") {
                TextField("8 digits", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
            }
        }
        Button(action: pairWithCode) {
            Text("Pair").frame(maxWidth: .infinity)
        }
        .buttonStyle(ChromeButtonStyle(kind: .prominent))
        .disabled(!canPair)
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack {
                Text(title)
                    .font(Chrome.Typeface.body)
                    .foregroundStyle(Chrome.text)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }

    @ViewBuilder
    private var statusSection: some View {
        switch pairing.state {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 10) {
                ProgressView()
                Text(text)
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case .checking(let code, let name):
            VStack(spacing: 16) {
                Text("CHECK CODE")
                    .font(Chrome.Typeface.section)
                    .tracking(0.8)
                    .foregroundStyle(Chrome.secondaryText)
                Text(code)
                    .font(.system(size: 54, weight: .semibold, design: .monospaced))
                    .tracking(6)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(Chrome.text)
                    .textSelection(.enabled)
                Text("Check that \(name) shows this same code, then approve it there.")
                    .font(Chrome.Typeface.label)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Chrome.secondaryText)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the Mac")
                        .font(Chrome.Typeface.caption)
                        .foregroundStyle(Chrome.secondaryText)
                }
                Text("If the codes differ, cancel. Someone may be intercepting the connection.")
                    .font(Chrome.Typeface.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Chrome.warning)
                Button("Cancel Pairing") { pairing.cancel() }
                    .buttonStyle(ChromeButtonStyle(kind: .destructive))
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Chrome.inputBackground, in: RoundedRectangle(cornerRadius: Chrome.Radius.group + 4))
            .overlay(RoundedRectangle(cornerRadius: Chrome.Radius.group + 4).stroke(Chrome.chipStroke, lineWidth: 1))
        case .done(let name):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Chrome.success)
                    .symbolEffect(.bounce, value: name)
                Text("Paired with \(name)")
                    .font(Chrome.Typeface.title)
                    .foregroundStyle(Chrome.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(Chrome.Typeface.label)
                .foregroundStyle(Chrome.failure)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Chrome.failure.opacity(0.1), in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
        }
    }

    private func handleScan(_ text: String) {
        if pairing.isWorking { return }
        if case .done = pairing.state { return }
        guard let url = URL(string: text), url.scheme == PairingPayload.scheme, let payload = PairingPayload(url: url) else {
            pairing.reject("That QR code is not a Turm pairing code.")
            return
        }
        pairing.pair(payload: payload, manager: manager)
    }

    private func pairWithCode() {
        if let nearby {
            pairing.pair(discovered: nearby, code: code, manager: manager)
        } else if let portValue {
            pairing.pair(host: host, port: portValue, code: code, manager: manager)
        }
    }
}

private struct ScannerFrame: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.62
            CornerBrackets(length: 30)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

private struct CornerBrackets: Shape {
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, y, dx, dy) in [
            (rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
            (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: x + dx * length, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * length))
        }
        return path
    }
}
