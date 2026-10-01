#if targetEnvironment(simulator)
import Foundation
import TurmCore
import UIKit

enum DemoScreen: String {
    case sidebar
    case session
    case ssh
    case running
    case settings
    case pairing
    case keyboard
}

enum DemoContent {
    private struct Prepared {
        let hosts: SSHHostStore?
        let mac: MacSession
        let ssh: SSHTerminalSession
        let running: MacSession
    }

    private static let suiteName = "turm.demo"
    private static var prepared: Prepared?

    static let screen: DemoScreen? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("-TurmDemoOff") else { return nil }
        guard let index = arguments.firstIndex(of: "-TurmDemoScreen"), arguments.indices.contains(index + 1) else { return .session }
        return DemoScreen(rawValue: arguments[index + 1].lowercased()) ?? .session
    }()

    static var hosts: SSHHostStore? { prepared?.hosts }
    static var focusesCommandField: Bool { screen == nil || screen == .keyboard }
    static var opensPairingCode: Bool { screen == .pairing }

    // focusing while the scene is still connecting shows the keyboard before keyboard avoidance is in place
    static func focusWhenReady(_ field: UIView) {
        Task { @MainActor in
            while field.window == nil || UIApplication.shared.applicationState != .active {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(400))
            _ = field.becomeFirstResponder()
        }
    }

    static func prepare() {
        guard screen != nil, prepared == nil else { return }
        let connection = MacManager.shared.showDemo(
            name: DemoFixtures.macName, hosts: DemoFixtures.macAddresses, shells: DemoFixtures.shells
        )
        var sessions: [UUID: MacSession] = [:]
        for shell in DemoFixtures.shells {
            let id = shell.summary.id
            sessions[id] = connection.session(for: id)
            connection.deliverDemo(.snapshot(
                id: id, cols: DemoFixtures.columns, rows: DemoFixtures.rows, history: shell.history, running: shell.running
            ))
        }
        guard let mac = sessions[DemoFixtures.turm.summary.id], let running = sessions[DemoFixtures.api.summary.id] else { return }

        let ssh = SSHTerminalSession(host: DemoFixtures.prodWeb)
        ssh.showDemo(DemoFixtures.remoteHistory.map { MacBlock(summary: $0) }, home: DemoFixtures.remoteHome)

        prepared = Prepared(hosts: makeHosts([DemoFixtures.prodWeb, DemoFixtures.pi]), mac: mac, ssh: ssh, running: running)
    }

    static func workspace() -> Workspace? {
        guard let screen, let prepared else { return nil }
        let workspace = Workspace()
        let tabs: [any TerminalTab] = [prepared.mac, prepared.ssh, prepared.running]
        for tab in tabs { workspace.open(tab) }
        switch screen {
        case .ssh:
            workspace.select(prepared.ssh)
        case .running:
            workspace.select(prepared.running)
        case .sidebar:
            workspace.select(prepared.mac)
            workspace.compactColumn = .sidebar
        case .session, .settings, .pairing, .keyboard:
            workspace.select(prepared.mac)
        }
        return workspace
    }

    static func presentSheets(in workspace: Workspace) async {
        guard screen == .settings || screen == .pairing else { return }
        try? await Task.sleep(for: .milliseconds(500))
        if screen == .settings {
            workspace.showsSettings = true
        } else {
            workspace.showsPairing = true
        }
    }

    private static func makeHosts(_ list: [SSHHost]) -> SSHHostStore? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        defaults.removePersistentDomain(forName: suiteName)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: SSHHostStore.hostsKey)
        }
        return SSHHostStore(defaults: defaults)
    }
}
#endif
