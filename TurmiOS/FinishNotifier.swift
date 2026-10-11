import TurmCore
import UIKit
import UserNotifications

enum FinishNotifier {
    static let enabledKey = "turm.finishNotice.enabled"
    static let minimumKey = "turm.finishNotice.minimum"
    static let onlyFailuresKey = "turm.finishNotice.onlyFailures"

    static func settings() -> FinishNoticeSettings {
        let defaults = UserDefaults.standard
        let enabled: Bool = defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
        let minimumSeconds: TimeInterval = defaults.object(forKey: minimumKey) == nil ? 0 : defaults.double(forKey: minimumKey)
        let onlyOnFailure: Bool = defaults.object(forKey: onlyFailuresKey) == nil ? false : defaults.bool(forKey: onlyFailuresKey)
        return FinishNoticeSettings(
            enabled: enabled,
            minimumDuration: .seconds(minimumSeconds),
            onlyOnFailure: onlyOnFailure
        )
    }

    @MainActor
    static func deliver(command: String, exitCode: Int32?, duration: Duration, shellEnabled: Bool) {
        let appIsFrontmost = UIApplication.shared.applicationState == .active
        guard let notice = FinishNoticePolicy.notice(
            command: command,
            exitCode: exitCode,
            duration: duration,
            shellEnabled: shellEnabled,
            isWatching: shellEnabled,
            appIsFrontmost: appIsFrontmost,
            settings: settings()
        ) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
