import AppKit
import SwiftUI
import XCTest
@testable import MeetingTranscriber

/// Fotografa o menu real em cenas fixas, claro e escuro, para revisão visual.
/// Só roda com MT_SNAPSHOT_DIR definido; sem hardware, sem áudio, sem Teams.
@MainActor
final class MenuSnapshotTests: XCTestCase {
    private var directory: URL!
    private var outputDirectory: URL!
    private var state: AppState!
    private var assistant: CallAssistant!
    private var defaults: UserDefaults!
    private let suiteName = "menu-snapshots-\(UUID().uuidString)"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MT_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("MT_SNAPSHOT_DIR não definido")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.set(directory.appendingPathComponent("Transcrições"), forKey: "outputDirectory")
        state = AppState(sessionStore: SessionStore(rootDirectory: directory.appendingPathComponent("Sessions")))
        defaults = UserDefaults(suiteName: suiteName)
        assistant = CallAssistant(
            recorder: state, notifier: SilentNotifier(), provider: NoProcesses(),
            calendarMatch: { _ in nil }, defaults: defaults, pollInterval: nil
        )
        assistant.setEnabled(true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "outputDirectory")
        defaults?.removePersistentDomain(forName: suiteName)
        state = nil
        assistant = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testManualIdle() {
        snap("01-manual")
    }

    func testIdleWithJobs() throws {
        state.transcriptionJobs = [job("Planejamento do trimestre", .running, progress: 42), try finishedJob("Revisão semanal"), job("Alinhamento com o time", .failed("O pipeline encerrou com erro."))]
        state.callActive = true
        snap("02-fila")
    }

    func testStartOffer() {
        assistant._previewOffer(.start, suggestion: CalendarMeeting(title: "Revisão semanal", startDate: Date()))
        snap("03-oferta-inicio")
    }

    func testRecordingAssisted() {
        recording(.assisted, assistedSession: UUID())
        snap("04-gravando")
    }

    func testRecordingWithEndOffer() {
        let session = UUID()
        recording(.assisted, assistedSession: session)
        assistant._previewOffer(.end, assistedSession: session)
        snap("05-possivel-fim")
    }

    func testRecordingManualAssistanceOff() {
        assistant.setEnabled(false)
        recording(.manual, assistedSession: nil)
        snap("06-gravando-manual")
    }

    func testSettings() {
        snap("07-configuracoes", settings: true)
    }

    func testPausedWithQueue() {
        assistant.setPaused(true)
        state.transcriptionJobs = [job("Planejamento do trimestre", .running, progress: 18)]
        state.onBattery = true
        snap("08-pausada-bateria")
    }

    func testErrorIdle() {
        state.status = .error("Sem permissão de gravação de tela. Conceda em Ajustes do Sistema.")
        snap("09-erro")
    }

    // MARK: Apoio

    private func recording(_ origin: RecordingOrigin, assistedSession: UUID?) {
        state.meetingTitle = "Revisão semanal"
        state.mic = MicRecorder()
        state.status = .recording
        state.micCaptureState = .ok
        if let assistedSession { assistant.captureStarted(sessionID: assistedSession, origin: origin) }
        state._previewCapture(origin: origin, proof: CaptureProof(
            elapsed: 754,
            mic: TrackProof(title: "Microfone", device: "Microfone do MacBook Air", secondsWritten: 754, level: .green, detail: "sinal agora"),
            system: TrackProof(title: "Sistema", device: "Áudio do sistema", secondsWritten: 753, level: .green, detail: "sinal agora")
        ))
    }

    private func job(_ title: String, _ status: TranscriptionJobStatus, progress: Int = 0) -> TranscriptionJob {
        var job = TranscriptionJob(
            id: UUID(), title: title, language: "pt", micURL: nil, systemURL: nil,
            outputDir: directory, sysOffsetMs: 0, createdAt: Date(timeIntervalSince1970: 1_792_754_400),
            startedAt: nil, completedAt: nil, status: status, captureIntegrity: .complete
        )
        job.progress = progress
        return job
    }

    private func finishedJob(_ title: String) throws -> TranscriptionJob {
        let output = directory.appendingPathComponent("revisao-semanal.md")
        try "# teste".write(to: output, atomically: true, encoding: .utf8)
        var finished = job(title, .succeeded(output))
        finished.completedAt = Date()
        return finished
    }

    private func snap(_ name: String, settings: Bool = false) {
        for dark in [true, false] {
            let root = MenuBarView(showingSettings: settings)
                .environmentObject(state)
                .environmentObject(assistant)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.appearance = appearance
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return XCTFail("sem bitmap para \(name)")
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = outputDirectory.appendingPathComponent("\(name)-\(dark ? "escuro" : "claro").png")
            XCTAssertNoThrow(try rep.representation(using: .png, properties: [:])?.write(to: url))
        }
    }
}

private final class SilentNotifier: AssistanceNotifying {
    func postOffer(_ offer: CallAssistant.Offer) {}
    func removeOffer(id: UUID) {}
}

private struct NoProcesses: AudioProcessActivityProviding {
    func snapshot() -> [AudioProcessActivity]? { [] }
}
