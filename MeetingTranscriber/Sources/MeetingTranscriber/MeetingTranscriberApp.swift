import SwiftUI
import UserNotifications
import CoreGraphics

@main
struct MeetingTranscriberApp: App {
    @StateObject private var appState: AppState
    @StateObject private var assistant: CallAssistant
    private let reviewWindow: AssistReviewWindowController
    @NSApplicationDelegateAdaptor(URLSchemeDelegate.self) private var urlSchemeDelegate

    init() {
        #if MT_HARDWARE_SELFTEST
        HardwareSelfTest.runIfRequested()
        #endif
        NotificationManager.shared.requestAuthorization()
        // Assistência Teams (2.0): observa e oferece; só gestos explícitos
        // chamam start/stop do AppState.
        let state = AppState()
        let assistant = CallAssistant(recorder: state, notifier: NotificationManager.shared)
        let reviewWindow = AssistReviewWindowController(state: state, assistant: assistant)
        state.onCaptureStarted = { [weak assistant] id, origin in assistant?.captureStarted(sessionID: id, origin: origin) }
        state.onCaptureEnded = { [weak assistant] id in assistant?.captureEnded(sessionID: id) }
        assistant.presentReview = { [weak reviewWindow] in reviewWindow?.present() }
        _appState = StateObject(wrappedValue: state)
        _assistant = StateObject(wrappedValue: assistant)
        self.reviewWindow = reviewWindow
        assistant.activate()
        state.attachDeferralMonitors(power: IOKitPowerSource(), call: CallActivityMonitor())
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
                .environmentObject(assistant)
        } label: {
            // Alerta visível mesmo em call/compartilhamento de tela, quando a
            // notificação costuma ficar suprimida: erro = logo com selo vermelho;
            // pergunta da assistência = selo azul com "?".
            MenuBarIcon(state: appState, assistant: assistant)
        }
        .menuBarExtraStyle(.window)
    }
}
