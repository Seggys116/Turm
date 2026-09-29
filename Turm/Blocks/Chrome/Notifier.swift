import AppKit
import UserNotifications

enum Notifier {
    static func post(title: String, body: String) {
        guard !(NSApp?.isActive ?? true) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? "Turm" : title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
