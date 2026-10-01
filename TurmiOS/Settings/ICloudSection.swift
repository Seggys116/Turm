import SwiftUI
import TurmCore

struct ICloudSection: View {
    private let sync = CloudSync.shared
    @State private var confirmingDelete = false

    private var enabled: Binding<Bool> {
        Binding(
            get: { sync.isEnabled },
            set: { on in
                if on { sync.enable() } else { sync.disable() }
            }
        )
    }

    private var statusText: String {
        switch sync.status {
        case .off: "Off"
        case .active: "On"
        case .unavailable: "iCloud Keychain is not available. Sign in to iCloud and turn on Keychain in the Settings app."
        case .resetElsewhere: "Sync was turned off because iCloud data was deleted from another device."
        case .deleting: "Deleting iCloud data"
        }
    }

    var body: some View {
        ChromeSection(
            "iCloud Sync",
            footer: "Syncs SSH hosts, shortcuts, passwords and keys between your devices through iCloud Keychain. Pairings with Macs never leave this device."
        ) {
            ChromeRow("iCloud Sync", detail: statusText) {
                Toggle("iCloud Sync", isOn: enabled)
                    .labelsHidden()
                    .tint(Chrome.accent)
                    .disabled(sync.status == .deleting)
            }
            if sync.isEnabled {
                ChromeRow("Last Sync") {
                    Group {
                        if let date = sync.lastSync {
                            Text(date, format: .relative(presentation: .named))
                        } else {
                            Text("Not yet")
                        }
                    }
                    .font(Chrome.Typeface.label)
                    .foregroundStyle(Chrome.secondaryText)
                }
                ChromeActionRow("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync.pull() }
            }
            ChromeActionRow("Delete iCloud Data", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                .disabled(sync.status == .deleting)
        }
        .chromeDialog(isPresented: $confirmingDelete) {
            .confirmation(
                title: "Delete iCloud Data?",
                message: "This removes synced hosts, shortcuts, passwords and keys from iCloud and from the synced copies on your other devices. This device keeps its own local copies, and sync turns off.",
                confirm: "Delete iCloud Data"
            ) {
                Task { await sync.deleteCloudData() }
            }
        }
    }
}
