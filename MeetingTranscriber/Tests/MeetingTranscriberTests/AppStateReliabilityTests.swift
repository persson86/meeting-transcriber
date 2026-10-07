import XCTest
@testable import MeetingTranscriber

@MainActor
final class AppStateReliabilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-reliability-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStartingStatePreventsReentrantRecording() {
        XCTAssertFalse(RecordingStatus.starting.canStartRecording)
        XCTAssertTrue(RecordingStatus.starting.isBusy)
    }

    func testDurationIntegrityFindsOneTruncatedTrack() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 1)
        let system = try writeWAV(name: "system.wav", seconds: 60)

        let issues = AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60
        )

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("microfone"))
    }

    func testDurationIntegrityFindsBothTracksStoppedEarly() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 1)
        let system = try writeWAV(name: "system.wav", seconds: 1)

        let issues = AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60
        )

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("duas trilhas"))
    }

    func testDurationIntegrityAllowsSmallFinalizeDifference() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 60)
        let system = try writeWAV(name: "system.wav", seconds: 59)

        XCTAssertTrue(AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60
        ).isEmpty)
    }

    func testDurationIntegrityAccountsForTrackStartOffset() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 60)
        let system = try writeWAV(name: "system.wav", seconds: 50)

        XCTAssertTrue(AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60,
            sysOffsetMs: 10_000
        ).isEmpty)
    }

    func testLateMicrophoneStartDoesNotLookLikeBothTracksStoppedEarly() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 30)
        let system = try writeWAV(name: "system.wav", seconds: 60)

        XCTAssertTrue(AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60,
            sysOffsetMs: -30_000
        ).isEmpty)
    }

    func testHealthIssuesExposeWriterAndStreamFailures() {
        let mic = AudioCaptureHealth(
            receivedBufferCount: 2,
            writtenByteCount: 10,
            firstBufferHostTime: 1,
            lastBufferHostTime: 2,
            firstErrorDescription: "disco cheio",
            recoveryAttemptCount: 1,
            recoveryErrorDescription: "rearm falhou",
            streamStopErrorDescription: nil,
            firstSignalHostTime: 1
        )
        let system = AudioCaptureHealth(
            receivedBufferCount: 2,
            writtenByteCount: 10,
            firstBufferHostTime: 1,
            lastBufferHostTime: 2,
            firstErrorDescription: nil,
            recoveryAttemptCount: 0,
            recoveryErrorDescription: nil,
            streamStopErrorDescription: "stream morreu"
        )

        let issues = AppState.healthIssues(mic: mic, system: system)

        // v1.7: erro de rearme e contagem de tentativas vão só para diagnostics.
        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues.contains { $0.contains("disco cheio") })
        XCTAssertTrue(issues.contains { $0.contains("stream morreu") })
    }

    func testAccumulatedMicroFillsAreNotAnIssue() {
        // 06/out: o contador cumulativo de silêncio inserido rebaixava sessões
        // íntegras. Sem interrupção medida, não há aviso.
        let mic = captureHealth(insertedSilenceSeconds: 40)
        XCTAssertTrue(AppState.healthIssues(mic: mic, system: nil).isEmpty)
    }

    func testMicDropoutsBecomeIssueOnlyWhenMaterial() {
        XCTAssertTrue(AppState.healthIssues(
            mic: captureHealth(dropouts: [0.6, 1.2, 1.5]), system: nil
        ).isEmpty)

        let longGap = AppState.healthIssues(mic: captureHealth(dropouts: [0.6, 3.2]), system: nil)
        XCTAssertEqual(longGap, ["O microfone ficou sem áudio por 4 s no total (2 interrupção(ões): 4 s, maior 3 s)."])

        // Muitas falhas curtas somadas também contam.
        let many = AppState.healthIssues(mic: captureHealth(dropouts: Array(repeating: 1.5, count: 7)), system: nil)
        XCTAssertEqual(many.count, 1)
        XCTAssertTrue(many[0].contains("11 s no total"))
    }

    func testMicLossIncludesStartAndEnd() {
        let issues = AppState.healthIssues(
            mic: captureHealth(initialAudioDelaySeconds: 74.8, trailingSilenceSeconds: 12),
            system: nil
        )
        XCTAssertEqual(issues, ["O microfone ficou sem áudio por 1 min 27 s no total (início: 1 min 15 s; fim: 12 s)."])
        // Abertura normal do engine e o stop não contam.
        XCTAssertTrue(AppState.healthIssues(
            mic: captureHealth(initialAudioDelaySeconds: 0.5, trailingSilenceSeconds: 0.8), system: nil
        ).isEmpty)
    }

    func testMicThatNeverDeliveredSignalIsAnIssue() {
        let mic = captureHealth(firstSignalHostTime: nil)
        XCTAssertEqual(AppState.healthIssues(mic: mic, system: nil), [
            "O microfone não entregou áudio em nenhum momento da gravação.",
        ])
    }

    func testPendingRecoveryAloneDoesNotDegradeCapture() {
        // A perda que importa aparece em segundos; o estado do rearme vai para diagnostics.
        let mic = captureHealth(recoveryPending: true)
        let issues = AppState.healthIssues(mic: mic, system: nil)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(AppState.captureIntegrity(issues: issues, micEvents: []).status, .complete)
    }

    func testSystemDropoutsAreMeasuredFromInsertedGaps() {
        XCTAssertTrue(AppState.healthIssues(mic: nil, system: captureHealth(dropouts: [1.0])).isEmpty)
        XCTAssertEqual(AppState.healthIssues(mic: nil, system: captureHealth(dropouts: [125])), [
            "O áudio do sistema ficou sem captura por 2 min 05 s no total (maior intervalo: 2 min 05 s).",
        ])
    }

    func testSecondsFormatterRoundsAcrossMinuteBoundary() {
        XCTAssertEqual(AppState.seconds(59.4), "59 s")
        XCTAssertEqual(AppState.seconds(59.6), "1 min 00 s")
        XCTAssertEqual(AppState.seconds(119.6), "2 min 00 s")
    }

    func testLossTallyIgnoresJitter() {
        var tally = AudioLossTally()
        tally.add(seconds: 0.2)
        tally.add(seconds: -1)
        tally.add(seconds: .nan)
        XCTAssertEqual(tally.count, 0)
        tally.add(seconds: 0.5)
        tally.add(seconds: 2)
        XCTAssertEqual(tally.count, 2)
        XCTAssertEqual(tally.totalSeconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(tally.largestSeconds, 2)
    }

    func testReleaseSessionAudioDeletesOnlyVerifiedCopiesInsideSessions() throws {
        let fm = FileManager.default
        let sessions = directory.appendingPathComponent("Sessions/abc", isDirectory: true)
        let archive = directory.appendingPathComponent("transcriptions/reuniao", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let mic = sessions.appendingPathComponent("mic.wav")
        let system = sessions.appendingPathComponent("system.wav")
        try Data(repeating: 1, count: 100).write(to: mic)
        try Data(repeating: 2, count: 100).write(to: system)
        try fm.copyItem(at: mic, to: archive.appendingPathComponent("mic.wav"))
        // Cópia incompleta: o original fica.
        try Data(repeating: 2, count: 50).write(to: archive.appendingPathComponent("system.wav"))

        let released = AppState.releaseSessionAudio(
            micURL: mic, systemURL: system, archiveURL: archive,
            sessionRoot: directory.appendingPathComponent("Sessions", isDirectory: true)
        )

        XCTAssertEqual(released.mic, archive.appendingPathComponent("mic.wav"))
        XCTAssertFalse(fm.fileExists(atPath: mic.path))
        XCTAssertEqual(released.system, system)
        XCTAssertTrue(fm.fileExists(atPath: system.path))
    }

    func testReleaseSessionAudioNeverDeletesImportedFilesOutsideSessions() throws {
        let fm = FileManager.default
        let imported = directory.appendingPathComponent("gravacao.wav")
        let archive = directory.appendingPathComponent("transcriptions/importada", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: imported)
        try fm.copyItem(at: imported, to: archive.appendingPathComponent("mic.wav"))

        let released = AppState.releaseSessionAudio(
            micURL: imported, systemURL: nil, archiveURL: archive,
            sessionRoot: directory.appendingPathComponent("Sessions", isDirectory: true)
        )

        XCTAssertEqual(released.mic, imported)
        XCTAssertNil(released.system)
        XCTAssertTrue(fm.fileExists(atPath: imported.path))
    }

    func testProcessingFailuresAndCappedGapsDegradeCapture() {
        let mic = captureHealth(processingErrorDescription: "formato inválido", cappedGapCount: 1)
        let issues = AppState.healthIssues(mic: mic, system: mic)
        XCTAssertEqual(issues.filter { $0.contains("Falha ao converter") }.count, 2)
        XCTAssertEqual(issues.filter { $0.contains("sincronização") }.count, 2)
    }

    func testFreshSilentCallbacksCannotHideSignalWatchdogFailure() {
        let mic = captureHealth(
            captureState: .recovering(attempts: 1),
            lastBufferHostTime: mach_absolute_time()
        )
        XCTAssertTrue(AppState.micIsStalled(health: mic, secondsSinceCaptureStart: 10))
    }

    private func captureHealth(
        recoveryPending: Bool = false,
        initialAudioDelaySeconds: TimeInterval? = 0.3,
        trailingSilenceSeconds: TimeInterval? = 0.2,
        processingErrorDescription: String? = nil,
        cappedGapCount: UInt64 = 0,
        captureState: MicCaptureState = .ok,
        lastBufferHostTime: UInt64 = 100,
        firstSignalHostTime: UInt64? = 1,
        insertedSilenceSeconds: Double = 0,
        dropouts: [TimeInterval] = []
    ) -> AudioCaptureHealth {
        var tally = AudioLossTally()
        dropouts.forEach { tally.add(seconds: $0) }
        return AudioCaptureHealth(
            receivedBufferCount: 100,
            writtenByteCount: 320_000,
            firstBufferHostTime: 1,
            lastBufferHostTime: lastBufferHostTime,
            firstErrorDescription: nil,
            recoveryAttemptCount: 2,
            recoveryErrorDescription: nil,
            streamStopErrorDescription: nil,
            processingErrorDescription: processingErrorDescription,
            insertedSilenceByteCount: UInt32(insertedSilenceSeconds * 32_000),
            cappedGapCount: cappedGapCount,
            recoverySuccessCount: 1,
            captureState: captureState,
            firstSignalHostTime: firstSignalHostTime,
            recoveryPending: recoveryPending,
            initialAudioDelaySeconds: firstSignalHostTime == nil ? nil : initialAudioDelaySeconds,
            dropouts: tally,
            trailingSilenceSeconds: trailingSilenceSeconds
        )
    }

    private func writeWAV(name: String, seconds: Int) throws -> URL {
        let output = directory.appendingPathComponent(name)
        let writer = WAVWriter()
        XCTAssertTrue(writer.append(Data(repeating: 0, count: seconds * 16_000 * 2)))
        try writer.save(to: output)
        return output
    }
}
