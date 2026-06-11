import SwiftUI
import UserNotifications
import CoreGraphics

@main
struct MeetingTranscriberApp: App {
    @StateObject private var appState = AppState()

    init() {
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
            Image(systemName: appState.status.isRecording ? "record.circle.fill" : "mic.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(appState.status.isRecording ? .red : .primary)
        }
        .menuBarExtraStyle(.window)
    }
}
