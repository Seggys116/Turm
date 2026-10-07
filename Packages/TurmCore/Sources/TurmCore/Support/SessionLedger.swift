import Foundation

public struct SessionLedger<Owner: AnyObject> {
    private struct Claim {
        weak var owner: Owner?
    }

    private var claims: [UUID: Claim] = [:]

    public init() {}

    public func owner(of id: UUID) -> Owner? {
        claims[id]?.owner
    }

    public mutating func assign(_ id: UUID, to owner: Owner) {
        claims = claims.filter { $0.value.owner != nil }
        claims[id] = Claim(owner: owner)
    }

    public mutating func unassign(_ id: UUID, from owner: Owner) {
        guard claims[id]?.owner === owner else { return }
        claims[id] = nil
    }

    public mutating func retire(_ owner: Owner) -> [UUID] {
        let held = claims.filter { $0.value.owner === owner }.map(\.key)
        for id in held { claims[id] = nil }
        return held
    }
}
