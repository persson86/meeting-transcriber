import UserNotifications
import Foundation

final class NotificationManager {
    static let shared = NotificationManager()

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyDone(fileURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Transcrição concluída"
        content.body = fileURL.lastPathComponent
        content.sound = .default
        content.userInfo = ["filePath": fileURL.path]

        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
