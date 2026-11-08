import Foundation

public struct KittyEviction: Equatable, Sendable {
    public let imageID: UInt32
    public let engineID: UInt32?

    public init(imageID: UInt32, engineID: UInt32?) {
        self.imageID = imageID
        self.engineID = engineID
    }
}

public final class KittyImageStore {
    public var images: [GraphicsPlacement] = []
    public var virtualPlacements: [GraphicsPlacement] = []
    public var sources: [UInt32: KittyAnimation] = [:]
    public var imageNumbers: [UInt32: UInt32] = [:]
    public var nextImageID: UInt32 = 1
    public var nextInternalID: UInt32 = 4_290_000_000
    public var unloaded: Set<UInt32> = []
    public var accessClock: UInt64 = 0
    public var engineIDs: [UInt32: UInt32] = [:]
    public var storageLimit = 320 * 1024 * 1024

    public init() {}

    public var usedStorage: Int {
        sources.values.reduce(0) { $0 + $1.rootBytes }
    }

    public var cacheSize: Int {
        sources.values.reduce(0) { $0 + $1.totalBytes }
    }

    public var virtualKeys: Set<KittyKey> {
        Set(virtualPlacements.map { KittyKey(imageID: $0.kittyID ?? 0, placementID: $0.placementID ?? 0) })
    }

    public func placedIDs() -> Set<UInt32> {
        Set(images.compactMap { $0.fromKitty ? $0.kittyID : nil }).union(virtualPlacements.compactMap(\.kittyID))
    }

    public func allocateInternalID() -> UInt32 {
        let id = nextInternalID
        nextInternalID += 1
        return id
    }

    public func touch(_ id: UInt32) {
        accessClock += 1
        sources[id]?.touched = accessClock
    }

    public func resolve(imageID: UInt32?, imageNumber: UInt32?) -> UInt32? {
        imageID ?? imageNumber.flatMap { imageNumbers[$0] }
    }

    @discardableResult
    public func evict(_ id: UInt32) -> KittyEviction {
        images.removeAll { $0.fromKitty && $0.kittyID == id }
        virtualPlacements.removeAll { $0.kittyID == id }
        images.removeOrphans(keeping: virtualKeys)
        sources[id] = nil
        unloaded.remove(id)
        imageNumbers = imageNumbers.filter { $0.value != id }
        return KittyEviction(imageID: id, engineID: engineIDs.removeValue(forKey: id))
    }

    public func applyQuota(keeping id: UInt32?) -> [KittyEviction] {
        var evicted: [KittyEviction] = []
        let placed = placedIDs()
        for candidate in Array(sources.keys) where candidate != id && !placed.contains(candidate) {
            evicted.append(evict(candidate))
        }
        guard usedStorage >= storageLimit else { return evicted }
        let order = sources.sorted { first, second in
            first.value.transient != second.value.transient ? first.value.transient : first.value.touched < second.value.touched
        }
        for entry in order {
            guard usedStorage > storageLimit else { break }
            evicted.append(evict(entry.key))
        }
        return evicted
    }

    public func makeRoom(forFrameBytes need: Int, keeping id: UInt32) -> (fits: Bool, evicted: [KittyEviction]) {
        guard cacheSize + need > storageLimit * 5 else { return (true, []) }
        var evicted: [KittyEviction] = []
        let placed = placedIDs()
        for candidate in Array(sources.keys) where candidate != id && !placed.contains(candidate) {
            evicted.append(evict(candidate))
        }
        return (cacheSize + need <= storageLimit * 5, evicted)
    }

    public func deleteContext(cursor: GridPoint, screen: GraphicsScreen) -> KittyDeleteContext {
        KittyDeleteContext(cursor: cursor, screen: screen, numbers: imageNumbers, virtualKeys: virtualKeys)
    }

    // Applies every delete mode except frame deletion, which needs the animation target.
    public func deletePlacements(_ command: KittyCommand, cursor: GridPoint, screen: GraphicsScreen) -> [KittyEviction] {
        let mode = String(command.deleteTarget ?? "a").lowercased()
        let before = placedIDs()
        virtualPlacements.applyVirtualDelete(command, context: deleteContext(cursor: cursor, screen: screen))
        images.applyKittyDelete(command, context: deleteContext(cursor: cursor, screen: screen))
        guard let target = command.deleteTarget, target.isUppercase else { return [] }
        var candidates = before.subtracting(placedIDs())
        switch mode {
        case "i": if let id = command.imageID { candidates.insert(id) }
        case "n": if let number = command.imageNumber, let id = imageNumbers[number] { candidates.insert(id) }
        case "r": candidates.formUnion(sources.keys.filter { Int($0) >= (command.x ?? 0) && Int($0) <= (command.y ?? 0) })
        default: break
        }
        let placed = placedIDs()
        var evicted: [KittyEviction] = []
        for id in candidates where !placed.contains(id) && sources[id] != nil { evicted.append(evict(id)) }
        return evicted
    }
}
