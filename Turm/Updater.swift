import Sparkle
import SwiftUI

@Observable
final class Updater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    init() {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            self?.canCheck = updater.canCheckForUpdates
        }
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}

struct UpdateCommands: Commands {
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") { updater.check() }
                .disabled(!updater.canCheck)
        }
    }
}
