import AppKit
import SwiftUI
import TurmCore

@main
struct TurmApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var updater = Updater()

    var body: some Scene {
        WindowGroup(id: WindowTransfer.windowID) {
            ContentView(updater: updater)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(Self.hostsTests ? .suppressed : .automatic)
        .restorationBehavior(Self.hostsTests ? .disabled : .automatic)
        .commands {
            PaneCommands()
            UpdateCommands(updater: updater)
            RemoteMacCommands()
        }
        Window("Remote Macs", id: RemoteMacsWindow.id) {
            RemoteMacsWindow()
        }
        .defaultLaunchBehavior(Self.hostsTests ? .suppressed : .automatic)
        .restorationBehavior(Self.hostsTests ? .disabled : .automatic)
    }

    /// While the app hosts the test suite it opens no window and never comes to the front, so tests stay out of the user's way.
    static var hostsTests: Bool { WorkspacePersistence.isRunningTests }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if TurmApp.hostsTests { NSApp.setActivationPolicy(.prohibited) }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        #if DEBUG
        DemoMode.start()
        #endif
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        ContextMenuService.shared.handle(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DemoMode.isActive {
            AppearancePreference.stored.apply()
            AppIconPreference.stored.apply()
            return
        }
        #endif
        // keychain calls can block for a long time, so the one-off migration never runs on the main thread
        Task.detached(priority: .utility) { SecretsMigration.runIfNeeded() }
        CloudSync.shared.start()
        AppearancePreference.stored.apply()
        AppIconPreference.stored.apply()
        ContextMenuService.shared.install()
        CompanionServer.shared.startIfEnabled()
        RemoteMacManager.shared.start()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { AppIconPreference.stored.apply() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CloseCoordinator.shared.shouldQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        CompanionServer.shared.stop()
        CloseCoordinator.shared.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !TurmApp.hostsTests
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newWindow(_ sender: Any?) {
        NSApp.activate()
        NewWindowAction.open()
    }
}

enum NewWindowAction {
    static var open: () -> Void = {}
}
