import UserNotifications
import Foundation
import OSLog

final class NotificationManager {
    static let shared = NotificationManager()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.meetingtranscriber.app",
        category: "notifications"
    )

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.info("Notification authorization completed granted=\(granted, privacy: .public)")
            }

            center.getNotificationSettings { settings in
                Self.logger.info("Notification settings authorizationStatus=\(settings.authorizationStatus.rawValue, privacy: .public)")
            }
        }
    }

    func notifyDone(fileURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Transcrição concluída"
        content.body = fileURL.lastPathComponent
        content.sound = .default
        content.userInfo = ["filePath": fileURL.path]

        deliver(content, kind: "transcription-complete")
    }

    func notifyWarning(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Aviso de gravação"
        content.body = message
        content.sound = .default

        deliver(content, kind: "recording-warning")
    }

    func notifyRecommendation(eventTitle: String, reason: String, leadMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Em \(leadMinutes) minutos: \"\(eventTitle)\""
        content.body = "Recomendo gravar: \(reason)"
        content.sound = .default

        deliver(content, kind: "meeting-recommendation")
    }

    /// Parses `meetingtranscriber://recommend?title=...&reason=...&lead=10`.
    func handleRecommendationURL(_ url: URL) {
        guard url.scheme == "meetingtranscriber", url.host == "recommend" else {
            Self.logger.error("Recommendation URL rejected: invalid route")
            return
        }
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            params.first(where: { $0.name == name })?.value
        }
        guard let title = value("title"), let reason = value("reason") else {
            Self.logger.error("Recommendation URL rejected: missing required parameters")
            return
        }
        let lead = value("lead").flatMap(Int.init) ?? 10
        Self.logger.info("Recommendation URL accepted lead=\(lead, privacy: .public)")
        notifyRecommendation(eventTitle: title, reason: reason, leadMinutes: lead)
    }

    private func deliver(_ content: UNNotificationContent, kind: String) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("Notification delivery failed kind=\(kind, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.info("Notification delivery accepted kind=\(kind, privacy: .public)")
            }
        }
    }
}
