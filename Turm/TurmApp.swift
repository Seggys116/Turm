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
        .commands {
            PaneCommands()
            UpdateCommands(updater: updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        true
    }
}
