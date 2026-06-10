import SwiftUI
import UserNotifications

@main
struct MeetingTranscriberApp: App {
    @StateObject private var appState = AppState()

    init() {
        NotificationManager.shared.requestAuthorization()
        // Ensure output directory exists
        let dir = UserDefaults.standard.url(forKey: "outputDirectory")
            ?? AppConfig.defaultOutputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
