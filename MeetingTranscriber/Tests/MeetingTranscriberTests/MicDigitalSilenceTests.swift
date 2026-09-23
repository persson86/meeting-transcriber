import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import MeetingTranscriber

/// Silêncio digital (buffers só com zeros exatos) conta como "sem áudio": dispara o
/// mesmo rebuild do watchdog, não zera backoff nem a contagem de fallback, e a
/// recuperação só é confirmada com PCM não-zero. Fakes em MicRecoveryTests.swift.
final class MicDigitalSilenceTests: XCTestCase {
    private var scheduler: FakeMicScheduler!
    private var controlQueue: DispatchQueue!
    private var primaries: [FakeCaptureEngine] = []
    private var fallbacks: [FakeCaptureEngine] = []

    override func setUp() {
        super.setUp()
        scheduler = FakeMicScheduler()
        controlQueue = DispatchQueue(label: "MicDigitalSilenceTests.control")
        primaries = []
        fallbacks = []
    }

    private func makeRecorder(withFallback: Bool = false) -> MicRecorder {
        let fallbackFactory: (() -> MicCaptureEngine)? = withFallback
            ? { [unowned self] in
                let engine = FakeCaptureEngine()
                engine.backendName = "captureSession"
                self.fallbacks.append(engine)
                return engine
            }
            : nil
        return MicRecorder(
            writer: WAVWriter(),
            engineFactory: { [unowned self] in
                let engine = FakeCaptureEngine()
                self.primaries.append(engine)
                return engine
            },
            fallbackEngineFactory: fallbackFactory,
            scheduler: scheduler,
            controlQueue: controlQueue
        )
    }

    func testDetectorSeparatesExactZerosFromLowNoise() {
        XCTAssertTrue(pcmBufferIsDigitalSilence(FakeCaptureEngine.makeBuffer(value: 0)))
        XCTAssertFalse(pcmBufferIsDigitalSilence(FakeCaptureEngine.makeBuffer(value: 1e-6)))
        XCTAssertFalse(pcmBufferIsDigitalSilence(FakeCaptureEngine.makeBuffer(sampleRate: 48_000, frames: 481, value: 0.01)))
        // Um único sample não-zero no fim do buffer já é áudio.
        let buffer = FakeCaptureEngine.makeBuffer(frames: 163, value: 0)
        buffer.floatChannelData?[0][162] = -1e-7
        XCTAssertFalse(pcmBufferIsDigitalSilence(buffer))
    }

    func testContinuousDigitalSilenceTriggersRebuildAfterThreeSeconds() throws {
        let recorder = makeRecorder()
        try recorder.start()

        for step in 1...6 {
            scheduler.advance(to: Double(step) * 0.5)
            primaries[0].emitBuffer(hostTimeSeconds: Double(step) * 0.5, value: 0)
        }
        var health = recorder.health
        XCTAssertEqual(health.receivedBufferCount, 6)
        XCTAssertGreaterThan(health.writtenByteCount, 0)   // zeros vão ao writer (linha do tempo)
        XCTAssertEqual(health.recoveryAttemptCount, 0)     // 3,0 s ainda não passa do limiar

        scheduler.advance(to: 4.0)
        health = recorder.health
        XCTAssertEqual(health.recoveryAttemptCount, 1)
        XCTAssertEqual(health.lastRebuildReason, "digital-silence")
        XCTAssertEqual(health.digitalSilenceStallCount, 1)
        XCTAssertTrue(health.isStalled)
        XCTAssertEqual(primaries.count, 2)
        XCTAssertEqual(primaries[0].removeTapCount, 1)
        XCTAssertEqual(primaries[0].stopCount, 1)
    }

    func testLowNonZeroNoiseDoesNotTriggerRebuild() throws {
        let recorder = makeRecorder()
        try recorder.start()

        for step in 1...20 {
            scheduler.advance(to: Double(step) * 0.5)
            primaries[0].emitBuffer(hostTimeSeconds: Double(step) * 0.5, value: 1e-5)
        }

        let health = recorder.health
        XCTAssertEqual(health.recoveryAttemptCount, 0)
        XCTAssertEqual(health.digitalSilenceStallCount, 0)
        XCTAssertFalse(health.isStalled)
        XCTAssertEqual(primaries.count, 1)
    }

    func testRecoveryCountsOnlyWithNonZeroPCMAndZerosKeepBackoff() throws {
        let recorder = makeRecorder()
        try recorder.start()

        scheduler.advance(to: 4.0)   // stall sem buffers → rebuild 1
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 1)
        XCTAssertEqual(recorder.health.lastRebuildReason, "stall")

        scheduler.advance(to: 4.1)
        primaries[1].emitBuffer(hostTimeSeconds: 4.1, value: 0)
        var health = recorder.health
        XCTAssertEqual(health.recoverySuccessCount, 0)     // zeros não provam recuperação
        XCTAssertGreaterThan(health.writtenByteCount, 0)   // mas são escritos
        XCTAssertTrue(health.isStalled)

        scheduler.advance(to: 4.5)   // backoff não foi zerado pelos zeros → rebuild 2
        health = recorder.health
        XCTAssertEqual(health.recoveryAttemptCount, 2)
        XCTAssertEqual(health.lastRebuildReason, "digital-silence")
        XCTAssertEqual(health.digitalSilenceStallCount, 1)

        scheduler.advance(to: 4.6)
        primaries[2].emitBuffer(hostTimeSeconds: 4.6, value: 0.02)
        health = recorder.health
        XCTAssertEqual(health.recoverySuccessCount, 1)
        XCTAssertFalse(health.isStalled)

        scheduler.advance(to: 7.5)   // 2,9 s depois do áudio real: nenhum rebuild extra
        primaries[2].emitBuffer(hostTimeSeconds: 7.5)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 2)
        XCTAssertEqual(recorder.health.digitalSilenceStallCount, 1)
    }

    func testFallbackAfterTwoRebuildsThatOnlyProducedZeros() throws {
        let recorder = makeRecorder(withFallback: true)
        try recorder.start()

        for step in 1...8 {
            scheduler.advance(to: Double(step) * 0.5)
            primaries.last?.emitBuffer(hostTimeSeconds: Double(step) * 0.5, value: 0)
        }
        // t=4,0: rebuild 1 (digital-silence); zeros seguem no engine novo.
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 1)
        XCTAssertEqual(primaries.count, 2)
        scheduler.advance(to: 4.5)   // rebuild 2, ainda primário
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 2)
        XCTAssertEqual(primaries.count, 3)
        XCTAssertEqual(fallbacks.count, 0)
        primaries[2].emitBuffer(hostTimeSeconds: 4.7, value: 0)

        scheduler.advance(to: 5.5)   // rebuild 3 → AVCaptureSession
        var health = recorder.health
        XCTAssertEqual(health.recoveryAttemptCount, 3)
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertEqual(health.captureBackend, "captureSession")
        XCTAssertEqual(health.fallbackActivatedCount, 1)
        XCTAssertGreaterThanOrEqual(health.digitalSilenceStallCount, 2)

        scheduler.advance(to: 5.6)
        fallbacks[0].emitBuffer(hostTimeSeconds: 5.6, value: 0.03)
        health = recorder.health
        XCTAssertEqual(health.recoverySuccessCount, 1)
        XCTAssertFalse(health.isStalled)
        XCTAssertEqual(health.captureBackend, "captureSession")
    }
}
