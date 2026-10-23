import XCTest
@testable import MeetingTranscriber

/// Local otimizado: o ASR só roda na tomada e fora de chamada, e retoma de onde
/// parou. Sem hardware: jobs `.running` sem runner, para nada iniciar Python.
@MainActor
final class TranscriptionDeferralTests: XCTestCase {
    private var directory: URL!
    private var state: AppState!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deferral-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.set(directory.appendingPathComponent("out"), forKey: "outputDirectory")
        UserDefaults.standard.removeObject(forKey: AppState.deferDefaultsKey)
        state = AppState(sessionStore: SessionStore(rootDirectory: directory.appendingPathComponent("Sessions")))
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "outputDirectory")
        UserDefaults.standard.removeObject(forKey: AppState.deferDefaultsKey)
        state = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Política

    func testRecordingBeatsOverride() {
        XCTAssertEqual(reason(capturing: true, overridden: true), .recording)
        XCTAssertEqual(reason(capturing: true, enabled: false), .recording)
    }

    func testCallBeforeBattery() {
        XCTAssertEqual(reason(call: true, battery: true), .call)
        XCTAssertEqual(reason(battery: true), .battery)
        XCTAssertNil(reason())
    }

    func testDisabledOrOverriddenIgnoresCallAndBattery() {
        XCTAssertNil(reason(enabled: false, call: true, battery: true))
        XCTAssertNil(reason(overridden: true, call: true, battery: true))
        XCTAssertFalse(TranscriptionPauseReason.recording.canOverride)
    }

    // MARK: AppState

    func testDefaultIsOn() {
        XCTAssertTrue(state.deferTranscriptionWhenBusy)
    }

    func testBatteryPausesAndPowerResumes() {
        state.transcriptionJobs = [runningJob()]
        state.onBattery = true
        XCTAssertTrue(state.transcriptionsPaused)
        XCTAssertEqual(state.transcriptionPauseReason, .battery)
        state.onBattery = false
        XCTAssertFalse(state.transcriptionsPaused)
        XCTAssertNil(state.transcriptionPauseReason)
    }

    func testCallPausesAndEndResumes() {
        state.transcriptionJobs = [runningJob()]
        state.callActive = true
        XCTAssertEqual(state.transcriptionPauseReason, .call)
        state.callActive = false
        XCTAssertFalse(state.transcriptionsPaused)
    }

    func testResumeNowLastsUntilQueueEmpties() throws {
        state.transcriptionJobs = [runningJob()]
        state.onBattery = true
        state.resumeTranscriptionsNow()
        XCTAssertFalse(state.transcriptionsPaused)
        XCTAssertNil(state.transcriptionPauseReason)
        // Uma chamada no meio não volta a pausar o que a pessoa liberou.
        state.callActive = true
        XCTAssertFalse(state.transcriptionsPaused)

        state.transcriptionJobs = [try finishedJob()]
        XCTAssertFalse(state.transcriptionDeferralOverridden)
        XCTAssertEqual(state.transcriptionPauseReason, .call)
    }

    func testResumeNowDoesNothingDuringRecording() {
        state.transcriptionJobs = [runningJob()]
        state.mic = MicRecorder()
        state.status = .recording
        state.resumeTranscriptionsNow()
        XCTAssertFalse(state.transcriptionDeferralOverridden)
        XCTAssertEqual(state.transcriptionPauseReason, .recording)
    }

    func testTurningOffDeferralResumesAndPersists() {
        state.transcriptionJobs = [runningJob()]
        state.onBattery = true
        state.setDeferTranscriptionWhenBusy(false)
        XCTAssertFalse(state.transcriptionsPaused)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppState.deferDefaultsKey) as? Bool, false)
        state.setDeferTranscriptionWhenBusy(true)
        XCTAssertEqual(state.transcriptionPauseReason, .battery)
    }

    // MARK: Monitor de chamada

    func testCallMonitorUsesEpisodeStability() {
        let monitor = CallActivityMonitor(provider: EmptyProvider(), pollInterval: 1)
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        // Primeira leitura já ativa (app aberto no meio da chamada) também conta.
        monitor.ingest(active: true, at: 0)
        XCTAssertFalse(monitor.callActive)
        monitor.ingest(active: true, at: 2)
        XCTAssertTrue(monitor.callActive)
        // Queda curta (troca de fone) não retoma o ASR.
        monitor.ingest(active: false, at: 3)
        monitor.ingest(active: nil, at: 8)
        monitor.ingest(active: true, at: 9)
        XCTAssertTrue(monitor.callActive)
        monitor.ingest(active: false, at: 10)
        monitor.ingest(active: false, at: 22)
        XCTAssertFalse(monitor.callActive)
        XCTAssertEqual(changes, [true, false])
    }

    // MARK: Apoio

    private func reason(
        capturing: Bool = false, enabled: Bool = true, overridden: Bool = false,
        call: Bool = false, battery: Bool = false
    ) -> TranscriptionPauseReason? {
        TranscriptionPausePolicy.reason(
            capturing: capturing, deferEnabled: enabled, overridden: overridden,
            callActive: call, onBattery: battery
        )
    }

    private func runningJob() -> TranscriptionJob {
        TranscriptionJob(
            id: UUID(), title: "Reunião de teste", language: "pt",
            micURL: nil, systemURL: nil,
            outputDir: directory.appendingPathComponent("out", isDirectory: true),
            sysOffsetMs: 0, createdAt: Date(), startedAt: Date(), completedAt: nil,
            status: .running
        )
    }

    private func finishedJob() throws -> TranscriptionJob {
        var job = runningJob()
        job.status = .failed("teste")
        job.completedAt = Date()
        return job
    }
}

private struct EmptyProvider: AudioProcessActivityProviding {
    func snapshot() -> [AudioProcessActivity]? { [] }
}
