import Foundation
import TurmCore
import UIKit

enum CompanionDevice {
    private static let keychain = CompanionKeychain(role: .phone, service: "app.turm.companion.self")

    static var name: String {
        UIDevice.current.name
    }

    static let id: UUID = {
        if let existing = keychain.all().first { return existing.id }
        let record = CompanionPeerRecord(id: UUID(), name: "this device", key: Data())
        try? keychain.save(record)
        return record.id
    }()
}
