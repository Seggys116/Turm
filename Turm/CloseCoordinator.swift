import AppKit

enum CloseRequest: Equatable {
    case shell
    case window(shellCount: Int)
    case application(shellCount: Int)

    var title: String {
        switch self {
        case .shell: "Close this shell?"
        case .window: "Close this window?"
        case .application: "Quit Turm?"
        }
    }

    var message: String {
        switch self {
        case .shell:
            "This shell has an active or suspended job. Closing it will terminate the shell and may interrupt the job."
        case .window(let count), .application(let count):
            "You have \(count) open \(count == 1 ? "shell" : "shells"). Closing will terminate \(count == 1 ? "it" : "them") and may interrupt any running jobs."
        }
    }

    var action: String {
        switch self {
        case .shell: "Close Shell"
        case .window: "Close Window"
        case .application: "Quit Turm"
        }
    }
}

final class CloseCoordinator {
    static let shared = CloseCoordinator()

    private let workspaces = NSHashTable<Workspace>.weakObjects()
    private let present: (CloseRequest) -> Bool
    private var isConfirming = false

    init(present: ((CloseRequest) -> Bool)? = nil) {
        self.present = present ?? { Self.presentAlert($0) }
    }

    func register(_ workspace: Workspace) {
        workspaces.add(workspace)
    }

    func confirm(_ request: CloseRequest) -> Bool {
        guard !isConfirming else { return false }
        isConfirming = true
        defer { isConfirming = false }
        return present(request)
    }

    func shouldQuit() -> Bool {
        let count = workspaces.allObjects.reduce(0) { $0 + $1.shellsRequiringConfirmationCount }
        return count == 0 || confirm(.application(shellCount: count))
    }

    func terminateAll() {
        workspaces.allObjects.forEach { $0.terminateAll() }
    }

    private static func presentAlert(_ request: CloseRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let close = alert.addButton(withTitle: request.action)
        close.keyEquivalent = ""
        close.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
