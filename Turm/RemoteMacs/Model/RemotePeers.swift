import Foundation
import TurmCore

enum RemotePeers {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let canControlThisMac: CompanionPeerRecord?
        let controlledByThisMac: RemoteMacConnection?
    }

    static func merge(devices: [CompanionPeerRecord], macs: [RemoteMacConnection]) -> [Row] {
        let connections = Dictionary(macs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return merge(devices: devices, macs: macs.map { (id: $0.id, name: $0.name) }).map {
            Row(id: $0.id, name: $0.name, canControlThisMac: $0.canControlThisMac, controlledByThisMac: connections[$0.id])
        }
    }

    static func merge(devices: [CompanionPeerRecord], macs: [(id: UUID, name: String)]) -> [Row] {
        var names: [UUID: String] = [:]
        var allowed: [UUID: CompanionPeerRecord] = [:]
        for device in devices where allowed[device.id] == nil {
            allowed[device.id] = device
            names[device.id] = device.name
        }
        var controlled: Set<UUID> = []
        for mac in macs {
            controlled.insert(mac.id)
            if !mac.name.isEmpty { names[mac.id] = mac.name }
        }
        let ids = Set(allowed.keys).union(controlled)
        return ids.map { Row(id: $0, name: names[$0] ?? "", canControlThisMac: allowed[$0], controlledByThisMac: nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
