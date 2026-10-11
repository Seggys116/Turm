import Foundation

public nonisolated struct FinishNoticeSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var minimumDuration: Duration
    public var onlyOnFailure: Bool

    public init(
        enabled: Bool = true,
        minimumDuration: Duration = .seconds(0),
        onlyOnFailure: Bool = false
    ) {
        self.enabled = enabled
        self.minimumDuration = minimumDuration
        self.onlyOnFailure = onlyOnFailure
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case minimumDuration
        case onlyOnFailure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        let ti = try container.decode(TimeInterval.self, forKey: .minimumDuration)
        minimumDuration = .seconds(ti)
        onlyOnFailure = try container.decode(Bool.self, forKey: .onlyOnFailure)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        let components = minimumDuration.components
        let ti: TimeInterval = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
        try container.encode(ti, forKey: .minimumDuration)
        try container.encode(onlyOnFailure, forKey: .onlyOnFailure)
    }
}

public nonisolated struct FinishNotice: Sendable, Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public nonisolated enum FinishNoticePolicy {
    /// A suspended app never calls this. iOS does not deliver a notification after it suspends the process, and this release does not use push.
    public static func notice(
        command: String,
        exitCode: Int32?,
        duration: Duration,
        shellEnabled: Bool,
        isWatching: Bool,
        appIsFrontmost: Bool,
        settings: FinishNoticeSettings
    ) -> FinishNotice? {
        guard settings.enabled else { return nil }
        guard shellEnabled else { return nil }
        guard isWatching else { return nil }
        guard !appIsFrontmost else { return nil }
        guard duration >= settings.minimumDuration else { return nil }
        if settings.onlyOnFailure {
            guard let code = exitCode, code != 0 else { return nil }
        }

        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let title: String
        if trimmed.isEmpty {
            title = "Turm"
        } else if trimmed.count > 80 {
            title = String(trimmed.prefix(79)) + "\u{2026}"
        } else {
            title = trimmed
        }

        let separator = " \u{00B7} "
        let formattedDuration = format(duration: duration)
        let body: String
        switch exitCode {
        case nil:
            body = "Finished" + separator + formattedDuration
        case 0:
            body = "Exited 0" + separator + formattedDuration
        case let code?:
            body = "Failed (\(code))" + separator + formattedDuration
        }

        return FinishNotice(title: title, body: body)
    }

    public static func format(duration: Duration) -> String {
        let components = duration.components
        let rawSeconds = Double(components.seconds) + Double(components.attoseconds) * 1e-18
        let totalSeconds = max(0, Int(rawSeconds.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        } else {
            let minutes = totalSeconds / 60
            let secs = totalSeconds % 60
            return "\(minutes)m \(secs)s"
        }
    }
}
