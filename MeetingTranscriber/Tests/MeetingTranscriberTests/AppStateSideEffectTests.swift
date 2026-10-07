import XCTest
@testable import MeetingTranscriber

/// F2 e F4: ações laterais não tocam o estado de captura, e sair do app não
/// deixa gravação nem transcrição para trás. Sem hardware: o recorder é um
/// `MicRecorder` nunca iniciado, o suficiente para o invariante de estado.
@MainActor
final class AppStateSideEffectTests: XCTestCase {
    private var directory: URL!
    private var state: AppState!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-side-effects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // O processo de teste tem seus próprios defaults; isso não toca os do app.
        UserDefaults.standard.set(directory.appendingPathComponent("out"), forKey: "outputDirectory")
        state = AppState(sessionStore: SessionStore(rootDirectory: directory.appendingPathComponent("Sessions")))
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "outputDirectory")
        UserDefaults.standard.removeObject(forKey: "secondBrainPath")
        state = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: F2

    func testFailedSendNeverTouchesCaptureStatus() throws {
        let job = try succeededJob()
        // `queue` é um arquivo: criar queue/transcricoes/ falha.
        let brain = directory.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try Data().write(to: brain.appendingPathComponent("queue"))
        UserDefaults.standard.set(brain.path, forKey: "secondBrainPath")
        state.transcriptionJobs = [job]
        state.mic = MicRecorder()
        state.status = .recording

        state.sendToSecondBrain(job)

        XCTAssertTrue(state.status.isRecording)
        XCTAssertTrue(state.transcriptionsPaused)
        XCTAssertNil(state.transcriptionJobs.first?.sideError)  // recusado: gravando
    }

    func testSendErrorLivesOnTheJobNotOnStatus() throws {
        let job = try succeededJob()
        let brain = directory.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try Data().write(to: brain.appendingPathComponent("queue"))
        UserDefaults.standard.set(brain.path, forKey: "secondBrainPath")
        state.transcriptionJobs = [job]

        state.sendToSecondBrain(job)

        XCTAssertTrue(state.status.canStartRecording)
        XCTAssertFalse(state.status.isError)
        XCTAssertNotNil(state.transcriptionJobs.first?.sideError)
        XCTAssertNotNil(state.lastWarning)
        XCTAssertFalse(state.transcriptionJobs[0].exportedToSecondBrain)
    }

    func testSendIsRefusedWhileCapturing() throws {
        let job = try succeededJob()
        let brain = directory.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        UserDefaults.standard.set(brain.path, forKey: "secondBrainPath")
        state.transcriptionJobs = [job]
        state.mic = MicRecorder()
        state.status = .recording

        state.sendToSecondBrain(job)

        XCTAssertFalse(state.transcriptionJobs[0].exportedToSecondBrain)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: brain.appendingPathComponent("queue").path))
    }

    func testResetErrorIgnoredWhileARecorderIsActive() {
        state.mic = MicRecorder()
        state.status = .error("falha lateral")
        state.resetError()
        XCTAssertTrue(state.status.isError)
        XCTAssertTrue(state.hasActiveRecorder)

        state.mic = nil
        state.resetError()
        XCTAssertTrue(state.status.canStartRecording)
        XCTAssertFalse(state.status.isError)
    }

    func testStartRecordingRefusedWhileARecorderIsStillActive() {
        state.mic = MicRecorder()
        state.status = .error("falha")
        state.startRecording()
        XCTAssertTrue(state.status.isError)
    }

    func testStatusInvariantHoldsAfterEveryPublicSideAction() throws {
        let job = try succeededJob()
        state.transcriptionJobs = [job]
        state.mic = MicRecorder()
        state.status = .recording
        let actions: [() -> Void] = [
            { self.state.resetError() },
            { self.state.clearWarning() },
            { self.state.sendToSecondBrain(job) },
            { self.state.retryJob(job.id) },
            { self.state.cancelJob(job.id) },
            { self.state.dismissJob(job.id) },
            { self.state.syncMeetingTitleFromCalendar() },
        ]
        for action in actions {
            action()
            XCTAssertEqual(state.status.isCapturing, state.hasActiveRecorder)
        }
    }

    // MARK: F4

    func testQuitWithoutCaptureCancelsRunningTranscription() throws {
        var job = try succeededJob()
        job.status = .running
        state.transcriptionJobs = [job]

        XCTAssertEqual(state.handleTerminationRequest(), .terminateNow)

        guard case .failed(let message) = state.transcriptionJobs[0].status else {
            return XCTFail("o job em andamento deveria virar failed")
        }
        XCTAssertTrue(message.contains("Cancelado ao sair"))
        XCTAssertNotNil(state.transcriptionJobs[0].completedAt)
    }

    func testQuitDuringCaptureAsksFirstAndCancelKeepsRecording() {
        state.mic = MicRecorder()
        state.status = .recording
        var asked = 0
        state.confirmQuitWhileCapturing = { asked += 1; return false }

        XCTAssertEqual(state.handleTerminationRequest(), .terminateCancel)

        XCTAssertEqual(asked, 1)
        XCTAssertTrue(state.status.isRecording)
    }

    func testQuitWhileStartingWaitsInsteadOfDroppingTheSession() {
        state.status = .starting
        XCTAssertEqual(state.handleTerminationRequest(), .terminateCancel)
        XCTAssertNotNil(state.lastWarning)
    }

    func testConfirmedQuitReleasesTerminationOnlyAfterTheStopFinishes() async throws {
        state.mic = MicRecorder()
        state.status = .recording
        state.confirmQuitWhileCapturing = { true }
        let released = expectation(description: "terminate liberado")
        var reply: Bool?
        state.replyToTermination = { reply = $0; released.fulfill() }

        XCTAssertEqual(state.handleTerminationRequest(), .terminateLater)
        XCTAssertNil(reply, "não pode liberar antes de salvar o áudio")

        await fulfillment(of: [released], timeout: 10)
        XCTAssertEqual(reply, true)
        XCTAssertFalse(state.status.isCapturing)
    }

    // MARK: Fixtures

    private func succeededJob() throws -> TranscriptionJob {
        let outDir = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let output = outDir.appendingPathComponent("reuniao.md")
        try "# teste".write(to: output, atomically: true, encoding: .utf8)
        return TranscriptionJob(
            id: UUID(),
            title: "Reunião de teste",
            language: "pt",
            micURL: nil,
            systemURL: nil,
            outputDir: outDir,
            sysOffsetMs: 0,
            createdAt: Date(),
            startedAt: Date(),
            completedAt: Date(),
            status: .succeeded(output),
            captureIntegrity: .complete
        )
    }
}
