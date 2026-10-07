import XCTest
@testable import MeetingTranscriber

@MainActor
final class JobPresentationTests: XCTestCase {
    // MARK: F3 — resultado quantificado

    func testSmallMeasuredLossStaysCompletedWithoutFailureIcon() {
        let job = job(integrity: degraded(micLoss: 6.7, duration: 575, kind: .start))
        let result = JobPresentation.result(for: job)
        XCTAssertEqual(result.level, .minorLoss)
        XCTAssertEqual(result.listText, "Concluída · mic sem áudio 7 s no início")
        XCTAssertEqual(result.symbol, "checkmark.circle.fill")
        XCTAssertFalse(result.needsAttention)
        XCTAssertEqual(result.notificationTitle, "Transcrição concluída")
        XCTAssertEqual(result.notificationCaveat, "Concluída com perda pequena: mic 7 s no início")
    }

    func testLargeLossIsPartialWithAmountAndPercentage() {
        let job = job(integrity: degraded(micLoss: 8 * 60, duration: 42 * 60, kind: .gap, at: 600))
        let result = JobPresentation.result(for: job)
        XCTAssertEqual(result.level, .partial)
        XCTAssertEqual(result.listText, "Captura parcial · mic 8 min de 42 min (19%)")
        XCTAssertEqual(result.notificationCaveat, "Atenção: captura parcial, mic 8 min de 42 min (19%)")
        XCTAssertTrue(result.needsAttention)
    }

    func testThirtySecondsOrTwoPercentIsNotSmall() {
        // 12 s em 575 s passa de 2% (11,5 s).
        XCTAssertEqual(JobPresentation.result(for: job(integrity: degraded(micLoss: 12, duration: 575, kind: .start))).level, .partial)
        // 29 s em 3600 s é < 2%, mas e quando passa de 30 s absolutos:
        XCTAssertEqual(JobPresentation.result(for: job(integrity: degraded(micLoss: 31, duration: 7200, kind: .gap, at: 5))).level, .partial)
    }

    func testDegradedWithoutMeasurementsOrWithNonLossIssueIsPartial() {
        XCTAssertEqual(JobPresentation.result(for: job(integrity: .degraded(["Falha de escrita no microfone: disco cheio"]))).level, .partial)
        var mixed = degraded(micLoss: 2, duration: 600, kind: .start)
        mixed.details.append("Falha de escrita no microfone: disco cheio")
        XCTAssertEqual(JobPresentation.result(for: job(integrity: mixed)).level, .partial)
    }

    func testFailedJobHasItsOwnIconAndKeepsTheFullMessage() {
        var failed = job(integrity: .complete)
        failed.status = .failed("exit 1: o pipeline terminou com erro")
        let result = JobPresentation.result(for: failed)
        XCTAssertEqual(result.level, .failed)
        XCTAssertEqual(result.symbol, "xmark.octagon.fill")
        XCTAssertEqual(result.notificationTitle, "Transcrição falhou")
        XCTAssertTrue(result.listText.contains("exit 1: o pipeline terminou com erro"))
        XCTAssertTrue(result.needsAttention)
    }

    func testCompleteJobHasNoCaveat() {
        let result = JobPresentation.result(for: job(integrity: .complete))
        XCTAssertEqual(result.listText, "Concluída")
        XCTAssertNil(result.notificationCaveat)
    }

    // MARK: Indicador

    func testIndicatorShowsUnseenJobProblemUntilAcknowledged() {
        XCTAssertEqual(AppIndicator.make(status: .idle, micState: .ok, unseenJobProblem: true), .attention)
        XCTAssertEqual(AppIndicator.make(status: .idle, micState: .ok, unseenJobProblem: false), .idle)
    }

    func testIndicatorTurnsAmberWhenTheSystemTrackStalls() {
        XCTAssertEqual(AppIndicator.make(status: .recording, micState: .ok, systemNeedsAttention: true), .attention)
        XCTAssertEqual(AppIndicator.make(status: .recording, micState: .ok, systemNeedsAttention: false), .recording)
    }

    // MARK: F5 — prova de vida

    func testMicWithoutFirstSignalIsAmberWithCounterThenRed() {
        let early = CaptureProof.micProof(health(firstSignal: false), elapsed: 12)
        XCTAssertEqual(early.level, .amber)
        XCTAssertEqual(early.detail, "mic pendente · 12 s · tentando")
        XCTAssertEqual(CaptureProof.micProof(health(firstSignal: false), elapsed: 30).level, .red)
    }

    // MARK: F8c — abertura

    func testOpeningShowsStartingUntilBothTracksWroteOrTenSeconds() {
        func proof(elapsed: Double, micWritten: UInt32, sysWritten: UInt32) -> CaptureProof {
            CaptureProof.make(
                mic: health(firstSignal: micWritten > 0, written: micWritten),
                system: health(receivedAgo: 1, written: sysWritten),
                elapsed: elapsed
            )
        }
        // mic com 1º write em +6,2 s: "Iniciando…" e nenhum vermelho até lá.
        let early = proof(elapsed: 6, micWritten: 0, sysWritten: 640_000)
        XCTAssertTrue(early.isOpening)
        XCTAssertEqual(early.mic.detail, "iniciando…")
        XCTAssertNotEqual(early.mic.level, .red)
        XCTAssertFalse(proof(elapsed: 6.5, micWritten: 640_000, sysWritten: 640_000).isOpening)
        // 10 s sem write: sai da abertura com "mic pendente" em âmbar.
        let late = proof(elapsed: 10, micWritten: 0, sysWritten: 640_000)
        XCTAssertFalse(late.isOpening)
        XCTAssertEqual(late.mic.level, .amber)
        XCTAssertTrue(late.mic.detail.hasPrefix("mic pendente"))
    }

    func testMicRedAlertWaitsThirtySecondsWithoutFirstSignal() {
        let recovering = MicCaptureState.recovering(attempts: 1)
        XCTAssertEqual(CaptureProof.alertState(recovering, hasFirstSignal: false, elapsed: 12), .waitingForAudio)
        XCTAssertEqual(CaptureProof.alertState(recovering, hasFirstSignal: false, elapsed: 30), recovering)
        XCTAssertEqual(CaptureProof.alertState(recovering, hasFirstSignal: true, elapsed: 12), recovering)
        XCTAssertEqual(CaptureProof.alertState(.failed(attempts: 6), hasFirstSignal: false, elapsed: 12), .failed(attempts: 6))
    }

    func testMicSilenceAfterFirstSignalTurnsRedAtFiveSeconds() {
        XCTAssertEqual(CaptureProof.micProof(health(signalAgo: 1), elapsed: 60).level, .green)
        XCTAssertEqual(CaptureProof.micProof(health(signalAgo: 6), elapsed: 60).level, .red)
    }

    func testSystemSilenceWithCallbacksIsNeverRed() {
        let proof = CaptureProof.systemProof(health(signalAgo: 120, receivedAgo: 1), elapsed: 600)
        XCTAssertEqual(proof.level, .green)
    }

    func testSystemCallbacksStoppedIsAmberAndStreamErrorIsRed() {
        XCTAssertEqual(CaptureProof.systemProof(health(receivedAgo: 6), elapsed: 600).level, .amber)
        XCTAssertEqual(CaptureProof.systemProof(health(receivedAgo: 1, streamError: "morreu"), elapsed: 600).level, .red)
        XCTAssertTrue(AppState.systemIsStalled(health: health(receivedAgo: 6), secondsSinceCaptureStart: 600))
        XCTAssertFalse(AppState.systemIsStalled(health: health(receivedAgo: 1), secondsSinceCaptureStart: 600))
    }

    func testSystemWithoutSyncClockDoesNotRaiseAFalseAlarm() {
        let health = AudioCaptureHealth(
            receivedBufferCount: 50, writtenByteCount: 100_000,
            firstBufferHostTime: nil, lastBufferHostTime: nil,
            firstErrorDescription: nil, recoveryAttemptCount: 0,
            recoveryErrorDescription: nil, streamStopErrorDescription: nil
        )
        XCTAssertFalse(AppState.systemIsStalled(health: health, secondsSinceCaptureStart: 600))
    }

    func testSlowOpeningIsNotAWarningBeforeTheGraceWindow() {
        let silent = health(firstSignal: false, received: 0)
        XCTAssertFalse(AppState.micIsStalled(health: silent, secondsSinceCaptureStart: 10))
        XCTAssertFalse(AppState.micIsStalled(health: silent, secondsSinceCaptureStart: 29))
        XCTAssertTrue(AppState.micIsStalled(health: silent, secondsSinceCaptureStart: 31))
    }

    // MARK: Fixtures

    private func degraded(micLoss: TimeInterval, duration: TimeInterval, kind: LossInterval.Kind, at: Double = 0) -> CaptureIntegrity {
        let track = TrackIntegrity(
            startDelayS: kind == .start ? micLoss : 0, trailingS: 0,
            gapsS: kind == .gap ? micLoss : 0, lossS: micLoss,
            intervals: [LossInterval(kind: kind, atS: at, durS: micLoss)]
        )
        var integrity = CaptureIntegrity.degraded([IntegrityRule.micLabel + " por \(Int(micLoss)) s no total."])
        integrity.measured = IntegrityReport(ruleVersion: 2, tracks: ["mic": track], sessionDurationS: duration)
        return integrity
    }

    private func job(integrity: CaptureIntegrity) -> TranscriptionJob {
        TranscriptionJob(
            id: UUID(), title: "Reunião de teste", language: "pt",
            micURL: nil, systemURL: nil,
            outputDir: URL(fileURLWithPath: "/tmp"), sysOffsetMs: 0,
            createdAt: Date(), startedAt: Date(), completedAt: Date(),
            status: .succeeded(URL(fileURLWithPath: "/tmp/r.md")),
            captureIntegrity: integrity
        )
    }

    private func ago(_ seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = UInt64(seconds * 1_000_000_000 * Double(info.denom) / Double(info.numer))
        return mach_absolute_time() - ticks
    }

    private func health(
        firstSignal: Bool = true,
        signalAgo: Double? = nil,
        receivedAgo: Double? = nil,
        received: UInt64 = 10,
        written: UInt32 = 640_000,
        streamError: String? = nil
    ) -> AudioCaptureHealth {
        AudioCaptureHealth(
            receivedBufferCount: received,
            writtenByteCount: written,
            firstBufferHostTime: 1,
            lastBufferHostTime: receivedAgo.map(ago),
            firstErrorDescription: nil,
            recoveryAttemptCount: 0,
            recoveryErrorDescription: nil,
            streamStopErrorDescription: streamError,
            lastReceivedBufferHostTime: receivedAgo.map(ago),
            currentDeviceLabel: "Microfone de teste",
            firstSignalHostTime: firstSignal ? 1 : nil,
            lastSignalHostTime: firstSignal ? signalAgo.map(ago) : nil
        )
    }
}
