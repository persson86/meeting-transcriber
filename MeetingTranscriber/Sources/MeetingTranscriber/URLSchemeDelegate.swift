import AppKit

/// Handles `meetingtranscriber://` URLs (e.g. sent via `open` by the JARVIS
/// meeting-radar automation). MenuBarExtra scenes don't support SwiftUI's
/// `.onOpenURL`, so this registers the classic Apple Event handler instead.
final class URLSchemeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Sair durante a gravação pede confirmação e só termina depois de salvar o
    /// áudio; o ASR em andamento é cancelado para não sobreviver ao app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            AppState.current?.handleTerminationRequest() ?? .terminateNow
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        NotificationManager.shared.handleRecommendationURL(url)
    }
}
