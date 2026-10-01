import Foundation
import Observation
import SwiftUI
import TurmCore

@Observable
final class KeyBarLayout {
    static let shared = KeyBarLayout()
    static let keysKey = "turm.ios.keyBar.keys"
    static let hapticsKey = "turm.ios.keyBar.haptics"
    static let didChange = Notification.Name("turm.ios.keyBar.didChange")

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var keys: [TerminalKey]

    var haptics: Bool {
        didSet {
            defaults.set(haptics, forKey: Self.hapticsKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        haptics = defaults.object(forKey: Self.hapticsKey) as? Bool ?? true
        if let stored = defaults.stringArray(forKey: Self.keysKey) {
            var seen = Set<String>()
            keys = stored.compactMap { id in
                seen.insert(id).inserted ? TerminalKey.key(withID: id) : nil
            }
        } else {
            keys = TerminalKey.defaultIDs.compactMap { TerminalKey.key(withID: $0) }
        }
    }

    var available: [TerminalKey] {
        TerminalKey.catalog.filter { key in !keys.contains(key) }
    }

    var isDefault: Bool {
        keys.map(\.id) == TerminalKey.defaultIDs
    }

    func add(_ key: TerminalKey) {
        guard !keys.contains(key) else { return }
        keys.append(key)
        commit()
    }

    func remove(at offsets: IndexSet) {
        keys.remove(atOffsets: offsets)
        commit()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        keys.move(fromOffsets: offsets, toOffset: destination)
        commit()
    }

    func reset() {
        keys = TerminalKey.defaultIDs.compactMap { TerminalKey.key(withID: $0) }
        commit()
    }

    private func commit() {
        defaults.set(keys.map(\.id), forKey: Self.keysKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
