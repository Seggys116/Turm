import SwiftUI

@main
struct TurmApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var updater = Updater()

    var body: some Scene {
        WindowGroup {
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearancePreference.stored.apply()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CloseCoordinator.shared.shouldQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        CloseCoordinator.shared.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
