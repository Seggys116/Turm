import Foundation

public nonisolated struct CompanionVersion: Codable, Sendable, Equatable {
    public var app: String
    public var kinds: Set<String>
    public var essential: Set<String>

    public init(app: String, kinds: Set<String>, essential: Set<String>) {
        self.app = app
        self.kinds = kinds
        self.essential = essential
    }

    public static let current = CompanionVersion(
        app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        kinds: Set(CompanionMessage.Kind.allCases.map(\.rawValue)),
        essential: Set(CompanionMessage.Kind.allCases.filter(\.isEssential).map(\.rawValue))
    )

    private enum CodingKeys: String, CodingKey {
        case app, kinds, essential
    }

    // every field must stay optional on decode so any two releases can read each other's hello
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            app: try container.decodeIfPresent(String.self, forKey: .app) ?? "",
            kinds: Set(try container.decodeIfPresent([String].self, forKey: .kinds) ?? []),
            essential: Set(try container.decodeIfPresent([String].self, forKey: .essential) ?? [])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encode(kinds.sorted(), forKey: .kinds)
        try container.encode(essential.sorted(), forKey: .essential)
    }

    public func supports(_ kind: CompanionMessage.Kind) -> Bool {
        kinds.contains(kind.rawValue)
    }
}

public nonisolated enum CompanionCompatibility: Sendable, Equatable {
    public enum Side: Sendable, Equatable {
        case local
        case remote
    }

    case compatible(outdated: Side?)
    case incompatible(outdated: Side?)

    public static func between(_ local: CompanionVersion, _ remote: CompanionVersion) -> CompanionCompatibility {
        let localBroken = !remote.essential.isSubset(of: local.kinds)
        let remoteBroken = !local.essential.isSubset(of: remote.kinds)
        let older = older(local, remote)
        switch (localBroken, remoteBroken) {
        case (false, false): return .compatible(outdated: older)
        case (true, false): return .incompatible(outdated: .local)
        case (false, true): return .incompatible(outdated: .remote)
        case (true, true): return .incompatible(outdated: older)
        }
    }

    // the side missing messages the other understands; a diverged pair falls back to the app versions
    private static func older(_ local: CompanionVersion, _ remote: CompanionVersion) -> Side? {
        let localLacks = !remote.kinds.isSubset(of: local.kinds)
        let remoteLacks = !local.kinds.isSubset(of: remote.kinds)
        switch (localLacks, remoteLacks) {
        case (true, false): return .local
        case (false, true): return .remote
        case (false, false): return nil
        case (true, true):
            switch local.app.compare(remote.app, options: .numeric) {
            case .orderedAscending: return .local
            case .orderedDescending: return .remote
            case .orderedSame: return nil
            }
        }
    }

    public var isCompatible: Bool {
        if case .compatible = self { true } else { false }
    }

    public var outdated: Side? {
        switch self {
        case .compatible(let side): side
        case .incompatible(let side): side
        }
    }

    public func advice(local: CompanionVersion, remote: CompanionVersion, here: String, there: String) -> String? {
        let mine = Self.label(here, local.app)
        let theirs = Self.label(there, remote.app)
        switch self {
        case .compatible(nil):
            return nil
        case .compatible(.local?):
            return "\(theirs) runs a newer Turm. Update Turm on \(here) to use everything it offers."
        case .compatible(.remote?):
            return "\(theirs) runs an older Turm than \(mine). Update Turm on \(there) to use everything this version offers."
        case .incompatible(.local?):
            return "\(mine) is too old to connect to \(theirs). Update Turm on \(here)."
        case .incompatible(.remote?):
            return "\(theirs) is too old to connect to \(mine). Update Turm on \(there)."
        case .incompatible(nil):
            return "\(mine) and \(theirs) run Turm versions that cannot connect. Update Turm on both."
        }
    }

    private static func label(_ name: String, _ app: String) -> String {
        app.isEmpty ? name : "\(name) (Turm \(app))"
    }
}

// one rule for both apps, so the Mac and the phone always agree on who must update
public nonisolated enum CompanionHandshake {
    public static func answer(
        hello remote: CompanionVersion, local: CompanionVersion = .current, macName: String
    ) -> (reply: CompanionMessage, compatibility: CompanionCompatibility) {
        let compatibility = CompanionCompatibility.between(local, remote)
        let reply: CompanionMessage = compatibility.isCompatible
            ? .welcome(version: local, macName: macName)
            : .incompatible(version: local)
        return (reply, compatibility)
    }

    public static func read(
        _ message: CompanionMessage, local: CompanionVersion = .current
    ) -> (remote: CompanionVersion, compatibility: CompanionCompatibility)? {
        switch message {
        case .welcome(let remote, _):
            return (remote, CompanionCompatibility.between(local, remote))
        case .incompatible(let remote):
            let own = CompanionCompatibility.between(local, remote)
            return (remote, own.isCompatible ? .incompatible(outdated: own.outdated) : own)
        default:
            return nil
        }
    }
}
