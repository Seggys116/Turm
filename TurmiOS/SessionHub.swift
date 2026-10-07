import SwiftUI
import TurmCore
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let turmSession = UTType(exportedAs: "com.zak-noble-clarke.TurmiOS.session")
}

@MainActor
final class SessionHub {
    static let shared = SessionHub()
    static let activityType = "com.zak-noble-clarke.TurmiOS.session"
    private static let activityKey = "session"

    private var ledger = SessionLedger<Workspace>()
    private var scenes: [ObjectIdentifier: Workspace] = [:]
    #if targetEnvironment(simulator)
    private var seededDemo = false
    #endif

    private init() {
        NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            MainActor.assumeIsolated { self?.disconnected(scene) }
        }
    }

    var supportsWindows: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && UIApplication.shared.supportsMultipleScenes
    }

    func makeWorkspace() -> Workspace {
        #if targetEnvironment(simulator)
        if !seededDemo {
            seededDemo = true
            if let demo = DemoContent.workspace() { return demo }
        }
        #endif
        return Workspace()
    }

    func assign(_ id: UUID, to workspace: Workspace) {
        ledger.assign(id, to: workspace)
    }

    func unassign(_ id: UUID, from workspace: Workspace) {
        ledger.unassign(id, from: workspace)
    }

    func bind(_ workspace: Workspace, to scene: UIWindowScene) {
        scenes[ObjectIdentifier(scene)] = workspace
    }

    func transfer(_ tab: any TerminalTab, to target: Workspace) -> any TerminalTab {
        guard let owner = ledger.owner(of: tab.id), owner !== target, let held = owner.release(tab.id) else { return tab }
        return held
    }

    func move(_ id: UUID, to target: Workspace) {
        guard let owner = ledger.owner(of: id), owner !== target,
              let tab = owner.sessions.first(where: { $0.id == id })
        else { return }
        target.open(tab)
    }

    func openWindow(moving tab: any TerminalTab) {
        guard supportsWindows else { return }
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity(for: tab.id), options: nil, errorHandler: nil)
    }

    func sessionID(in activity: NSUserActivity) -> UUID? {
        (activity.userInfo?[Self.activityKey] as? String).flatMap(UUID.init(uuidString:))
    }

    func dragItem(for tab: any TerminalTab) -> NSItemProvider {
        let id = tab.id
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .turmSession, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        provider.registerObject(activity(for: id), visibility: .all)
        return provider
    }

    func drop(_ providers: [NSItemProvider], into target: Workspace) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.turmSession.identifier) }) else { return false }
        _ = provider.loadDataRepresentation(for: .turmSession) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            Task { @MainActor in self.move(id, to: target) }
        }
        return true
    }

    private func activity(for id: UUID) -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.userInfo = [Self.activityKey: id.uuidString]
        return activity
    }

    // sessions in a window that goes away have no screen left, so they end with it; moved sessions already left
    private func disconnected(_ scene: UIScene) {
        scenes.removeValue(forKey: ObjectIdentifier(scene))?.closeAll()
    }
}

extension Workspace {
    func windowMenuItems(for tab: any TerminalTab) -> [ChromeMenuItem] {
        guard SessionHub.shared.supportsWindows else { return [] }
        return [ChromeMenuItem(title: "Move to New Window", systemImage: "macwindow.badge.plus") { SessionHub.shared.openWindow(moving: tab) }]
    }
}

private struct SessionDrag: ViewModifier {
    let tab: any TerminalTab

    func body(content: Content) -> some View {
        if SessionHub.shared.supportsWindows {
            content.onDrag { SessionHub.shared.dragItem(for: tab) }
        } else {
            content
        }
    }
}

private struct SessionDrop: ViewModifier {
    let workspace: Workspace

    func body(content: Content) -> some View {
        if SessionHub.shared.supportsWindows {
            content.onDrop(of: [.turmSession], isTargeted: nil) { SessionHub.shared.drop($0, into: workspace) }
        } else {
            content
        }
    }
}

extension View {
    func sessionDrag(_ tab: any TerminalTab) -> some View {
        modifier(SessionDrag(tab: tab))
    }

    func sessionDrop(into workspace: Workspace) -> some View {
        modifier(SessionDrop(workspace: workspace))
    }

    func sceneReader(_ onScene: @escaping (UIWindowScene) -> Void) -> some View {
        background(SceneReader(onScene: onScene).allowsHitTesting(false))
    }
}

private struct SceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneProbe {
        let probe = SceneProbe()
        probe.isUserInteractionEnabled = false
        probe.onScene = onScene
        return probe
    }

    func updateUIView(_ probe: SceneProbe, context: Context) {
        probe.onScene = onScene
    }
}

private final class SceneProbe: UIView {
    var onScene: ((UIWindowScene) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scene = window?.windowScene { onScene?(scene) }
    }
}
