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
        XCTAssertEqual(longGap, ["Microfone sem áudio por 4 s no total: 2 interrupção(ões) no meio, maior 3 s."])

        // Muitas falhas curtas somadas também contam.
        let many = AppState.healthIssues(mic: captureHealth(dropouts: Array(repeating: 1.5, count: 7)), system: nil)
        XCTAssertEqual(many.count, 1)
        XCTAssertTrue(many[0].contains("11 s no total"))
        XCTAssertTrue(many[0].contains("7 interrupção(ões) no meio"))
    }

    func testMicLossIncludesStartAndEnd() {
        let issues = AppState.healthIssues(
            mic: captureHealth(initialAudioDelaySeconds: 74.8, trailingSilenceSeconds: 12),
            system: nil,
            sessionDuration: 120
        )
        XCTAssertEqual(issues, [
            "Microfone sem áudio por 1 min 27 s no total: 1 min 15 s no início (00:00–01:15); 12 s no fim (01:48–02:00)."
        ])
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
            "Áudio do sistema sem captura por 2 min 05 s no total: 1 interrupção(ões) no meio, maior 2 min 05 s.",
        ])
    }


    // MARK: - Integridade v2 (F1)

    func testStartDelayBelowTwoSecondsKeepsSessionComplete() throws {
        let mic = captureHealth(initialAudioDelaySeconds: 1.5)
        XCTAssertTrue(AppState.healthIssues(mic: mic, system: nil, sessionDuration: 575).isEmpty)
        let report = try XCTUnwrap(AppState.integrityReport(mic: mic, system: nil, sessionDuration: 575))
        let track = try XCTUnwrap(report.tracks["mic"])
        XCTAssertEqual(track.startDelayS, 1.5, accuracy: 0.001)
        XCTAssertEqual(track.lossS, 1.5, accuracy: 0.001)
        XCTAssertEqual(report.ruleVersion, 2)
    }

    func testMicStartOfTwoSecondsDegradesWithPosition() throws {
        let mic = captureHealth(initialAudioDelaySeconds: 2.0)
        let issues = AppState.healthIssues(mic: mic, system: nil, sessionDuration: 575)
        XCTAssertEqual(issues, ["Microfone sem áudio por 2 s no total: 2 s no início (00:00–00:02)."])
        let track = try XCTUnwrap(AppState.integrityReport(mic: mic, system: nil, sessionDuration: 575)?.tracks["mic"])
        XCTAssertEqual(track.intervals, [LossInterval(kind: .start, atS: 0, durS: 2.0)])
    }

    func testSeveralSubThresholdLossesBelowTenSecondsStayComplete() {
        let mic = captureHealth(
            initialAudioDelaySeconds: 1.9,
            trailingSilenceSeconds: 1.9,
            positionedGaps: [(at: 100, seconds: 1.9)]
        )
        XCTAssertTrue(AppState.healthIssues(mic: mic, system: nil, sessionDuration: 600).isEmpty)
    }

    func testSystemStartDelayDegradesLikeTheMicrophone() throws {
        let system = captureHealth(initialAudioDelaySeconds: 6.2)
        let issues = AppState.healthIssues(mic: nil, system: system, sessionDuration: 600)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].hasPrefix("Áudio do sistema"))
        XCTAssertTrue(issues[0].contains("no início (00:00–00:06)"))
        let track = try XCTUnwrap(AppState.integrityReport(mic: nil, system: system, sessionDuration: 600)?.tracks["system"])
        XCTAssertEqual(track.intervals.first?.kind, .start)
    }

    func testSystemGapInTheMiddleIsReportedWithItsPosition() throws {
        let system = captureHealth(positionedGaps: [(at: 750, seconds: 3)])
        let issues = AppState.healthIssues(mic: nil, system: system, sessionDuration: 1800)
        XCTAssertEqual(issues, ["Áudio do sistema sem captura por 3 s no total: 3 s no meio (12:30–12:33)."])
        let track = try XCTUnwrap(AppState.integrityReport(mic: nil, system: system, sessionDuration: 1800)?.tracks["system"])
        XCTAssertEqual(track.intervals.map(\.kind), [.gap])
    }

    func testSystemTrailingSilenceIsMeasured() {
        let system = captureHealth(trailingSilenceSeconds: 4)
        let issues = AppState.healthIssues(mic: nil, system: system, sessionDuration: 600)
        XCTAssertEqual(issues, ["Áudio do sistema sem captura por 4 s no total: 4 s no fim (09:56–10:00)."])
    }

    func testIntervalsKeepOnlyTheFiftyLargest() {
        var tally = AudioLossTally()
        for index in 0..<60 {
            tally.add(seconds: 0.5 + Double(index) * 0.01, atSeconds: Double(index) * 10)
        }
        XCTAssertEqual(tally.intervals.count, 50)
        XCTAssertEqual(tally.count, 60)
        XCTAssertEqual(tally.intervals.map(\.atS), tally.intervals.map(\.atS).sorted())
        XCTAssertFalse(tally.intervals.contains { $0.atS == 0 })
    }

    func testProportionalDurationToleranceIsGone() throws {
        // 15 s de diferença em 400 s passava com a tolerância de 5%.
        let mic = try writeWAV(name: "mic.wav", seconds: 400)
        let system = try writeWAV(name: "system.wav", seconds: 385)
        XCTAssertEqual(AppState.durationIntegrityIssues(
            micURL: mic, systemURL: system, sessionDuration: 400
        ).count, 1)
        let close = try writeWAV(name: "system2.wav", seconds: 399)
        XCTAssertTrue(AppState.durationIntegrityIssues(
            micURL: mic, systemURL: close, sessionDuration: 400
        ).isEmpty)
    }

    func testLateMicrophoneIsStillFlaggedByTheMeasuredStart() {
        // A comparação de durações aceita o mic atrasado (offset normaliza); a
        // perda aparece pela medição do início.
        let mic = captureHealth(initialAudioDelaySeconds: 30)
        XCTAssertFalse(AppState.healthIssues(mic: mic, system: nil, sessionDuration: 60).isEmpty)
    }

    func testIntegrityReportRoundTripsAndOldManifestHasNone() throws {
        let health = captureHealth(initialAudioDelaySeconds: 6.7)
        let report = AppState.integrityReport(mic: health, system: nil, sessionDuration: 575.2)
        let integrity = AppState.captureIntegrity(issues: ["x"], micEvents: [], measured: report)
        let encoded = try JSONEncoder().encode(integrity)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["integrity"])
        XCTAssertEqual(try JSONDecoder().decode(CaptureIntegrity.self, from: encoded), integrity)

        let old = #"{"status":"complete","details":[]}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(CaptureIntegrity.self, from: old).measured)
    }

    func testMicThatNeverHadSignalIsReportedAsStartLossNotEnd() throws {
        let mic = captureHealth(trailingSilenceSeconds: 600, firstSignalHostTime: nil)
        let track = try XCTUnwrap(AppState.integrityReport(mic: mic, system: nil, sessionDuration: 600)?.tracks["mic"])
        XCTAssertEqual(track.intervals, [LossInterval(kind: .start, atS: 0, durS: 600)])
    }

    func testDurationMismatchMessagesCountAsMeasuredLoss() {
        XCTAssertTrue(IntegrityRule.isLossMessage("A trilha do sistema terminou antes da outra (1s de microfone, 1s de sistema)."))
        XCTAssertTrue(IntegrityRule.isLossMessage("As duas trilhas terminaram antes do fim da sessão (1s)."))
        XCTAssertFalse(IntegrityRule.isLossMessage("Falha de escrita no microfone: disco cheio"))
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
        dropouts: [TimeInterval] = [],
        positionedGaps: [(at: TimeInterval, seconds: TimeInterval)] = []
    ) -> AudioCaptureHealth {
        var tally = AudioLossTally()
        dropouts.forEach { tally.add(seconds: $0) }
        positionedGaps.forEach { tally.add(seconds: $0.seconds, atSeconds: $0.at) }
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
