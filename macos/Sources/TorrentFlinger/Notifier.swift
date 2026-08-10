#if os(macOS)
import Foundation
import UserNotifications

/// Desktop notifications — the macOS stand-in for `QSystemTrayIcon.showMessage`.
///
/// `UNUserNotificationCenter.current()` traps when the process isn't a real
/// `.app` bundle, which is exactly the `swift run` dev loop, so every entry
/// point is gated on `isAvailable`. When it's unavailable the messages go to
/// stderr instead of vanishing silently.
enum Notifier {
    private static let isAvailable: Bool = {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }()

    private static var authorized = false

    /// Ask once at launch. Denial is fine — `post` degrades to a stderr line.
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorized = granted
            }
    }

    static func post(title: String, body: String) {
        guard isAvailable else {
            FileHandle.standardError.write(Data("[TorrentFlinger] \(title): \(body)\n".utf8))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
#endif
