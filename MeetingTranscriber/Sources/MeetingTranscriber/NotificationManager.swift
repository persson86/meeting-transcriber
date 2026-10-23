import AppKit
import UserNotifications
import Foundation
import OSLog

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() { super.init() }
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.meetingtranscriber.app",
        category: "notifications"
    )

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.assistanceCategories)
        // Ofertas não sobrevivem a um relançamento: avisos da execução anterior
        // sairiam da Central apontando para nada.
        center.getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { $0.hasPrefix("assistance-") }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
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

    func notifyDone(fileURL: URL, title: String = "Transcrição concluída", caveat: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = caveat.map { "\($0)\n\(fileURL.lastPathComponent)" } ?? fileURL.lastPathComponent
        content.sound = .default
        content.userInfo = ["filePath": fileURL.path]

        deliver(content, kind: "transcription-complete")
    }

    func notifyFailure(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcrição falhou"
        content.subtitle = title
        content.body = message
        content.sound = .default

        deliver(content, kind: "transcription-failed")
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Com o app em primeiro plano o sistema não apresenta a notificação por conta
    /// própria; sem isto o aviso de job falho sumia quando o popover estava aberto.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clique abre o `.md` do job concluído. Ofertas da assistência Teams vão
    /// para o `CallAssistant`, que revalida a oferta antes de qualquer ação.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if let action = Self.assistanceAction(
            category: content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier
        ) {
            let offerID = (content.userInfo[Self.offerIDKey] as? String).flatMap(UUID.init(uuidString:))
            Self.logger.info("Assistance response action=\(action.rawValue, privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = CallAssistant.current?.perform(action, offerID: offerID)
                }
                completionHandler()
            }
            return
        }
        if let path = response.notification.request.content.userInfo["filePath"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
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

    private func deliver(_ content: UNNotificationContent, kind: String, identifier: String = UUID().uuidString) {
        let request = UNNotificationRequest(
            identifier: identifier,
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

// MARK: - Assistência Teams (2.0)

extension NotificationManager: AssistanceNotifying {
    static let startCategory = "MT_ASSISTED_START"
    static let endCategory = "MT_ASSISTED_END"
    static let offerIDKey = "offerID"

    /// Ações sem `.foreground`: responder não abre o menu nem tira o foco do
    /// Teams. `.customDismissAction` só registra que o aviso foi fechado.
    static var assistanceCategories: Set<UNNotificationCategory> {
        let start = UNNotificationCategory(
            identifier: startCategory,
            actions: [
                UNNotificationAction(identifier: CallAssistant.Action.startNow.rawValue, title: "Gravar agora", options: []),
                UNNotificationAction(identifier: CallAssistant.Action.decline.rawValue, title: "Não gravar nesta chamada", options: [])
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let end = UNNotificationCategory(
            identifier: endCategory,
            actions: [
                UNNotificationAction(identifier: CallAssistant.Action.stopAndTranscribe.rawValue, title: "Encerrar e transcrever", options: []),
                UNNotificationAction(identifier: CallAssistant.Action.continueRecording.rawValue, title: "Continuar gravando", options: [])
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        return [start, end]
    }

    /// Corpo da notificação só navega (abre a revisão); nunca grava nem para.
    static func assistanceAction(category: String, actionIdentifier: String) -> CallAssistant.Action? {
        guard category == startCategory || category == endCategory else { return nil }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: return .openReview
        case UNNotificationDismissActionIdentifier: return .dismissed
        default:
            guard let action = CallAssistant.Action(rawValue: actionIdentifier) else { return nil }
            switch (category, action) {
            case (startCategory, .startNow), (startCategory, .decline),
                 (endCategory, .stopAndTranscribe), (endCategory, .continueRecording):
                return action
            default:
                return nil
            }
        }
    }

    /// Texto genérico: banner aparece em compartilhamento de tela, então o
    /// título da reunião só aparece no menu ou na janela aberta pela pessoa.
    static func assistanceContent(for offer: CallAssistant.Offer) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch offer.kind {
        case .start:
            content.title = "O Teams está usando áudio. Deseja gravar?"
            content.body = "Clique no aviso para definir um título."
            content.categoryIdentifier = startCategory
        case .end:
            content.title = "A chamada parece ter terminado."
            content.body = "A gravação continua até sua confirmação."
            content.categoryIdentifier = endCategory
        }
        // Sem som: a pergunta não compete com o áudio da reunião.
        content.sound = nil
        content.userInfo = [offerIDKey: offer.id.uuidString, "kind": offer.kind.rawValue]
        return content
    }

    @MainActor
    func postOffer(_ offer: CallAssistant.Offer) {
        deliver(
            Self.assistanceContent(for: offer),
            kind: "assistance-\(offer.kind.rawValue)",
            identifier: Self.requestIdentifier(offer.id)
        )
    }

    @MainActor
    func removeOffer(id: UUID) {
        let identifier = Self.requestIdentifier(id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    static func requestIdentifier(_ offerID: UUID) -> String { "assistance-\(offerID.uuidString)" }
}
