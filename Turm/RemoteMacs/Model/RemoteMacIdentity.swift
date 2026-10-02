import Foundation

enum RemoteMacIdentity {
    static var id: UUID { CompanionServer.shared.macID }
    static var name: String { CompanionServer.shared.macName }
}
