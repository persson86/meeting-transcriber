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
        UserDefaults.standard.removeObject(forKey: ProcessingBackend.defaultsKey)
        state = AppState(sessionStore: SessionStore(rootDirectory: directory.appendingPathComponent("Sessions")))
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "outputDirectory")
        UserDefaults.standard.removeObject(forKey: AppState.deferDefaultsKey)
        UserDefaults.standard.removeObject(forKey: ProcessingBackend.defaultsKey)
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

    // MARK: Local × Groq (2.3)

    func testCloudOnlyQueueSkipsBatteryButNotCallOrRecording() {
        XCTAssertNil(reason(battery: true, cloudOnly: true))
        XCTAssertEqual(reason(call: true, battery: true, cloudOnly: true), .call)
        XCTAssertEqual(reason(capturing: true, cloudOnly: true), .recording)
    }

    func testGroqJobsRunOnBatteryAndALocalJobBringsThePauseBack() async {
        state.transcriptionJobs = [runningJob(backend: .groq)]
        state.onBattery = true
        await settle()
        XCTAssertFalse(state.transcriptionsPaused)
        state.transcriptionJobs.append(runningJob(backend: .local))
        await settle()
        XCTAssertEqual(state.transcriptionPauseReason, .battery)
    }

    func testBatteryHoldsOnlyLocalJobs() {
        state.onBattery = true
        XCTAssertNil(state.pauseReason(for: runningJob(backend: .groq)))
        XCTAssertEqual(state.pauseReason(for: runningJob(backend: .local)), .battery)
        state.callActive = true
        XCTAssertEqual(state.pauseReason(for: runningJob(backend: .groq)), .call)
    }

    func testReprocessQueuesASiblingAndLeavesTheOriginalIntact() throws {
        let output = directory.appendingPathComponent("out/2026-10-23_09-02_reuniao-AAAA.md")
        var source = runningJob(backend: .local)
        source.micURL = directory.appendingPathComponent("arquivo/mic.wav")
        source.status = .succeeded(output)
        source.completedAt = Date()
        state.transcriptionJobs = [source]
        // Gravando: o job novo entra na fila mas não roda (sem pipeline no teste).
        state.mic = MicRecorder()
        state.status = .recording

        state.groqKeyCheck = { false }
        state.reprocessJob(source.id, backend: .groq)
        XCTAssertEqual(state.transcriptionJobs.count, 1, "sem chave não enfileira")
        XCTAssertNotNil(state.lastWarning)

        state.groqKeyCheck = { true }
        state.reprocessJob(source.id, backend: .groq)
        XCTAssertEqual(state.transcriptionJobs.count, 2)
        let sibling = state.transcriptionJobs[1]
        XCTAssertNotEqual(sibling.id, source.id)
        XCTAssertTrue(sibling.status.isQueued)
        XCTAssertEqual(state.backend(of: sibling), .groq)
        XCTAssertEqual(sibling.record?.reprocessOf, source.id.uuidString)
        XCTAssertEqual(sibling.micURL, source.micURL)
        XCTAssertEqual(sibling.outputDir, output.deletingLastPathComponent())
        XCTAssertEqual(sibling.createdAt, source.createdAt)
        XCTAssertEqual(state.transcriptionJobs[0], source)

        // Um por backend enquanto está na fila; o mesmo vale a partir do irmão.
        XCTAssertFalse(state.canReprocess(source, with: .groq))
        state.reprocessJob(source.id, backend: .groq)
        XCTAssertEqual(state.transcriptionJobs.count, 2)

        var done = sibling
        done.status = .succeeded(output.deletingLastPathComponent().appendingPathComponent("x-groq.md"))
        state.transcriptionJobs[1] = done
        state.reprocessJob(done.id, backend: .local)
        XCTAssertEqual(state.transcriptionJobs.last?.record?.reprocessOf, source.id.uuidString)
    }

    func testReprocessNeedsPreservedAudio() {
        var job = runningJob(backend: .local)
        job.status = .succeeded(directory.appendingPathComponent("out/a.md"))
        XCTAssertFalse(state.canReprocess(job, with: .groq))
    }

    func testBackendDefaultsToLocalAndGroqNeedsAKey() {
        XCTAssertEqual(state.processingBackend, .local)
        state.groqKeyCheck = { false }
        XCTAssertFalse(state.setProcessingBackend(.groq))
        XCTAssertEqual(state.processingBackend, .local)
        XCTAssertNotNil(state.lastWarning)
        state.groqKeyCheck = { true }
        XCTAssertTrue(state.setProcessingBackend(.groq))
        XCTAssertEqual(UserDefaults.standard.string(forKey: ProcessingBackend.defaultsKey), "groq")
        XCTAssertEqual(ProcessingBackend.stored(), .groq)
    }

    func testRetryCanSwitchBackendAndKeepsItOtherwise() throws {
        var job = try finishedJob()
        job.micURL = directory.appendingPathComponent("mic.wav")
        job.record = SessionRecord(asrBackend: "groq")
        state.transcriptionJobs = [job]
        // Gravando: o job volta à fila mas não roda (sem pipeline no teste).
        state.mic = MicRecorder()
        state.status = .recording
        XCTAssertEqual(state.backend(of: job), .groq)
        state.groqKeyCheck = { false }
        state.retryJob(job.id, backend: .groq)
        XCTAssertTrue(state.transcriptionJobs[0].status.isFinished, "sem chave não volta à fila")
        state.retryJob(job.id, backend: .local)
        XCTAssertEqual(state.transcriptionJobs[0].record?.asrBackend, "local")
        XCTAssertTrue(state.transcriptionJobs[0].status.isQueued)
    }

    func testPipelineArguments() {
        XCTAssertEqual(ProcessingBackend.groq.pipelineArguments(localOverride: nil),
                       ["--backend", "groq", "--allow-cloud-asr", "--groq-model", "whisper-large-v3"])
        XCTAssertEqual(ProcessingBackend.local.pipelineArguments(localOverride: nil), [])
        XCTAssertEqual(ProcessingBackend.local.pipelineArguments(localOverride: "faster-whisper"), ["--backend", "faster-whisper"])
        // O valor "groq" na mesma chave nunca vira override local.
        XCTAssertEqual(ProcessingBackend.local.pipelineArguments(localOverride: "groq"), [])
        XCTAssertEqual(ProcessingBackend(jobValue: nil), .local)
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
        call: Bool = false, battery: Bool = false, cloudOnly: Bool = false
    ) -> TranscriptionPauseReason? {
        TranscriptionPausePolicy.reason(
            capturing: capturing, deferEnabled: enabled, overridden: overridden,
            callActive: call, onBattery: battery, cloudOnly: cloudOnly
        )
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func runningJob(backend: ProcessingBackend? = nil) -> TranscriptionJob {
        var job = TranscriptionJob(
            id: UUID(), title: "Reunião de teste", language: "pt",
            micURL: nil, systemURL: nil,
            outputDir: directory.appendingPathComponent("out", isDirectory: true),
            sysOffsetMs: 0, createdAt: Date(), startedAt: Date(), completedAt: nil,
            status: .running
        )
        if let backend { job.record = SessionRecord(asrBackend: backend.rawValue) }
        return job
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
