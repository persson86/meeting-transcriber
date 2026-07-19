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

    func notifyWarning(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Aviso de gravação"
        content.body = message
        content.sound = .default

        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func notifyRecommendation(eventTitle: String, reason: String, leadMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Em \(leadMinutes) minutos: \"\(eventTitle)\""
        content.body = "Recomendo gravar: \(reason)"
        content.sound = .default

        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Parses `meetingtranscriber://recommend?title=...&reason=...&lead=10`.
    func handleRecommendationURL(_ url: URL) {
        guard url.scheme == "meetingtranscriber", url.host == "recommend" else { return }
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            params.first(where: { $0.name == name })?.value
        }
        guard let title = value("title"), let reason = value("reason") else { return }
        let lead = value("lead").flatMap(Int.init) ?? 10
        notifyRecommendation(eventTitle: title, reason: reason, leadMinutes: lead)
    }
}
