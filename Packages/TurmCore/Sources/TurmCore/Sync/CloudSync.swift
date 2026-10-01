import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum CloudSyncStatus: Equatable, Sendable {
    case off
    case active
    case unavailable
    case resetElsewhere
    case deleting
}

@Observable
public final class CloudSync {
    public static let shared = CloudSync()
    public static let pullInterval: TimeInterval = 60

    public private(set) var isEnabled: Bool
    public private(set) var lastSync: Date?
    public private(set) var status: CloudSyncStatus

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: KeychainRecordStore
    @ObservationIgnored private let mirror: CloudMirror
    @ObservationIgnored private let secretServices: [KeychainItem]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?

    init(
        defaults: UserDefaults = .standard, store: KeychainRecordStore = KeychainRecordStore(),
        hosts: SSHHostStore = .shared, shortcuts: ShortcutStore = .shared, identities: SSHIdentityStore = .shared
    ) {
        self.defaults = defaults
        self.store = store
        mirror = CloudMirror(store: store, hosts: hosts, shortcuts: shortcuts, identities: identities, defaults: defaults)
        secretServices = [KeychainItem(service: SSHSecrets.service), KeychainItem(service: SSHIdentityStore.service)]
        let enabled = SyncPreference.isEnabled(defaults)
        let last = defaults.double(forKey: SyncPreference.lastSyncKey)
        isEnabled = enabled
        lastSync = last > 0 ? Date(timeIntervalSince1970: last) : nil
        status = enabled ? .active : .off
        mirror.onEvent = { [weak self] event in self?.handle(event) }
    }

    public func start() {
        observeActivity()
        guard isEnabled else { return }
        guard store.isAvailable else {
            status = .unavailable
            return
        }
        if defaults.double(forKey: SyncPreference.enabledAtKey) == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: SyncPreference.enabledAtKey)
        }
        run()
    }

    public func enable() {
        guard !isEnabled else { return }
        guard store.isAvailable else {
            status = .unavailable
            return
        }
        defaults.set(true, forKey: SyncPreference.enabledKey)
        defaults.set(Date().timeIntervalSince1970, forKey: SyncPreference.enabledAtKey)
        isEnabled = true
        secretServices.forEach { $0.promoteLocalToSynced() }
        run()
        startTimer()
    }

    public func disable() {
        mirror.stop()
        stopTimer()
        secretServices.forEach { $0.copySyncedToLocal() }
        defaults.set(false, forKey: SyncPreference.enabledKey)
        defaults.removeObject(forKey: SyncPreference.enabledAtKey)
        isEnabled = false
        status = .off
    }

    // keychain sync has no change notification, so this runs at launch, on activation and on a timer
    public func pull() {
        guard isEnabled else { return }
        mirror.pull()
    }

    public func deleteCloudData() async {
        status = .deleting
        disable()
        guard store.isAvailable else {
            status = .off
            return
        }
        CloudMirror.resetCloud(store, at: Date())
        let services = secretServices
        await Task.detached { services.forEach { $0.deleteSynchronized() } }.value
        defaults.removeObject(forKey: SyncPreference.lastSyncKey)
        lastSync = nil
        status = .off
    }

    private func run() {
        mirror.start()
        if isEnabled { status = .active }
    }

    private func handle(_ event: MirrorEvent) {
        switch event {
        case .synced(let date):
            lastSync = date
        case .reset:
            disable()
            status = .resetElsewhere
        }
    }

    private func observeActivity() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        #if canImport(AppKit)
        let active = NSApplication.didBecomeActiveNotification
        let inactive = NSApplication.didResignActiveNotification
        #elseif canImport(UIKit)
        let active = UIApplication.didBecomeActiveNotification
        let inactive = UIApplication.willResignActiveNotification
        #endif
        #if canImport(AppKit) || canImport(UIKit)
        observers.append(center.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.pull()
                self.startTimer()
            }
        })
        observers.append(center.addObserver(forName: inactive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopTimer() }
        })
        #endif
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pullInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
