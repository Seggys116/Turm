import Foundation

public nonisolated enum RecordChange<Record: Sendable>: Sendable {
    case saved(Record)
    case removed(UUID)
}

nonisolated enum SyncPreference {
    static let enabledKey = "turm.sync.enabled"
    static let enabledAtKey = "turm.sync.enabledAt"
    static let lastSyncKey = "turm.sync.lastSync"
    static let migratedKey = "turm.secrets.migrated"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}
