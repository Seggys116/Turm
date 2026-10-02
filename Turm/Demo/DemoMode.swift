#if DEBUG
import Foundation

enum DemoMode {
    enum Screen: String {
        case hero
    }

    static let screen = UserDefaults.standard.string(forKey: "TurmDemoScreen").flatMap(Screen.init)

    static var isActive: Bool { screen != nil }

    static func start() {
        guard isActive else { return }
        do {
            try DemoHome.build()
        } catch {
            fputs("Demo home could not be built: \(error)\n", stderr)
            exit(1)
        }
        for name in ["HOME", "CFFIXED_USER_HOME", "ZDOTDIR"] {
            setenv(name, DemoHome.root, 1)
        }
        ShellIntegration.forcedShell = "/bin/zsh"
        DemoLayout.start()
    }
}
#endif
