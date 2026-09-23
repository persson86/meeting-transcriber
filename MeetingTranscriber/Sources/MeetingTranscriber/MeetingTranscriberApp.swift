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
            // notificação costuma ficar suprimida.
            Image(systemName: menuBarSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarColor)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        guard appState.status.isRecording else { return "mic.circle" }
        return appState.captureAlert == nil ? "record.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var menuBarColor: Color {
        guard appState.status.isRecording else { return .primary }
        return appState.captureAlert == nil ? .red : .orange
    }
}
