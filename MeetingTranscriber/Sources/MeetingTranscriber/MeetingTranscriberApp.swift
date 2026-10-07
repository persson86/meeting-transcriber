import SwiftUI
import UserNotifications
import CoreGraphics

@main
struct MeetingTranscriberApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(URLSchemeDelegate.self) private var urlSchemeDelegate

    init() {
        #if MT_HARDWARE_SELFTEST
        HardwareSelfTest.runIfRequested()
        #endif
        NotificationManager.shared.requestAuthorization()
        let dir = UserDefaults.standard.url(forKey: "outputDirectory")
            ?? AppConfig.defaultOutputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Defer until after NSApplication is ready so TCC can register the app bundle
        DispatchQueue.main.async { CGRequestScreenCaptureAccess() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            // Alerta visível mesmo em call/compartilhamento de tela, quando a
            // notificação costuma ficar suprimida: erro = logo com selo vermelho.
            switch appState.appIndicator {
            case .error:
                Image(nsImage: AppIndicatorImage.logoWithErrorBadge())
            case .attention:
                Image(nsImage: AppIndicatorImage.logoWithErrorBadge(color: .systemOrange))
            case .recording:
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
            case .idle:
                Image(systemName: AppIndicatorImage.logoSymbol)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
