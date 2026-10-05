import AppKit
import CoreAudio
import CoreMedia
import XCTest
@testable import MeetingTranscriber

/// v1.6: recuperação do microfone sem hardware. O caso de origem é a sessão de
/// 01/out/2026: headset Bluetooth conecta no clique, o rearme retorna sem erro e o
/// tap nunca mais recebe buffers.
final class MicResilienceTests: XCTestCase {

    // MARK: Planner

    func testNoAttemptWhileAudioIsFlowing() {
        var planner = MicRecoveryPlanner()
        XCTAssertEqual(planner.evaluate(now: 100, lastAudioAt: 99), .none)
        XCTAssertEqual(planner.evaluate(now: 100, lastAudioAt: 95.5), .none)
    }

    func testStallWithoutAnyNotificationTriggersAttempt() {
        var planner = MicRecoveryPlanner()
        // Nenhum buffer desde o início (t=0): aos 5,1 s já rearma.
        XCTAssertEqual(planner.evaluate(now: 5.1, lastAudioAt: 0), .attempt)
    }

    func testRearmWithoutErrorIsNotSuccessUntilAudioArrives() {
        var planner = MicRecoveryPlanner()
        XCTAssertEqual(planner.evaluate(now: 10, lastAudioAt: 0), .attempt)
        planner.noteAttempt(at: 10)

        // Áudio antigo (antes da tentativa) não encerra o episódio.
        XCTAssertFalse(planner.noteAudio(at: 0))
        XCTAssertEqual(planner.state(now: 12, lastAudioAt: 0, captureStartedAt: 0), .recovering(attempts: 1))

        XCTAssertTrue(planner.noteAudio(at: 11))
        XCTAssertEqual(planner.attemptsInEpisode, 0)
        XCTAssertEqual(planner.state(now: 12, lastAudioAt: 11, captureStartedAt: 0), .ok)
    }

    func testBackoffSpacesAttempts() {
        var planner = MicRecoveryPlanner()
        planner.noteAttempt(at: 10)
        XCTAssertEqual(planner.evaluate(now: 12, lastAudioAt: 0), .none)   // < 3 s
        XCTAssertEqual(planner.evaluate(now: 13, lastAudioAt: 0), .attempt)
        planner.noteAttempt(at: 13)
        XCTAssertEqual(planner.evaluate(now: 22, lastAudioAt: 0), .none)   // < 10 s
        XCTAssertEqual(planner.evaluate(now: 23, lastAudioAt: 0), .attempt)
    }

    func testAttemptsAreCappedAndReportFailure() {
        var planner = MicRecoveryPlanner()
        var now: TimeInterval = 10
        var attempts = 0
        while now < 10_000 {
            if planner.evaluate(now: now, lastAudioAt: 0) == .attempt {
                planner.noteAttempt(at: now)
                attempts += 1
            }
            now += 1
        }
        XCTAssertEqual(attempts, MicRecoveryPlanner.maxAttemptsPerEpisode)
        XCTAssertTrue(planner.exhausted)
        XCTAssertEqual(
            planner.state(now: now, lastAudioAt: 0, captureStartedAt: 0),
            .failed(attempts: MicRecoveryPlanner.maxAttemptsPerEpisode)
        )
    }

    func testManualRestartOpensNewSeriesAfterExhaustion() {
        var planner = MicRecoveryPlanner()
        for t in stride(from: 10.0, to: 1_000, by: 1) where planner.evaluate(now: t, lastAudioAt: 0) == .attempt {
            planner.noteAttempt(at: t)
        }
        XCTAssertTrue(planner.exhausted)

        planner.resetForManualAttempt()
        planner.noteAttempt(at: 1_000)
        XCTAssertFalse(planner.exhausted)
        XCTAssertEqual(planner.attemptsInEpisode, 1)
        XCTAssertTrue(planner.noteAudio(at: 1_001))
    }

    func testAudioAfterExhaustionStillCountsAsRecovery() {
        var planner = MicRecoveryPlanner()
        for t in stride(from: 10.0, to: 1_000, by: 1) where planner.evaluate(now: t, lastAudioAt: 0) == .attempt {
            planner.noteAttempt(at: t)
        }
        XCTAssertTrue(planner.noteAudio(at: 1_200))
        XCTAssertFalse(planner.exhausted)
    }

    func testWaitingStateBeforeFirstAudio() {
        let planner = MicRecoveryPlanner()
        XCTAssertEqual(planner.state(now: 2, lastAudioAt: nil, captureStartedAt: 0), .waitingForAudio)
        XCTAssertEqual(planner.state(now: 6, lastAudioAt: nil, captureStartedAt: 0), .recovering(attempts: 0))
    }

    func testStartupNotificationsDoNotInterruptRunningEngineWithCurrentFormat() {
        // 05/out: notificações após o próprio start/rearme causavam novas
        // paradas mesmo com engine rodando, antes de chegar o primeiro buffer.
        XCTAssertFalse(MicRecoveryPlanner.needsConfigurationRearm(engineRunning: true, inputFormatChanged: false))
        XCTAssertTrue(MicRecoveryPlanner.needsConfigurationRearm(engineRunning: false, inputFormatChanged: false))
        XCTAssertTrue(MicRecoveryPlanner.needsConfigurationRearm(engineRunning: true, inputFormatChanged: true))
    }

    func testStartupAndSlowRearmGetTimeToSettleBeforeWatchdogRetries() {
        // A sessão 12:06 levou 8,9 s num start. O relógio da tentativa anterior
        // não deve provocar outro stop assim que esse start termina.
        XCTAssertFalse(MicRecoveryPlanner.hasSettled(now: 14.2, configuredAt: 14.2))
        XCTAssertFalse(MicRecoveryPlanner.hasSettled(now: 19.2, configuredAt: 14.2))
        XCTAssertTrue(MicRecoveryPlanner.hasSettled(now: 19.3, configuredAt: 14.2))
    }

    // MARK: Política de dispositivo

    private let builtIn = MicInputDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone", transport: "built-in")
    private let headset = MicInputDevice(id: 20, uid: "AA-BB:input", name: "Headset", transport: "bluetooth")
    private let webcam = MicInputDevice(id: 30, uid: "usb-cam", name: "Webcam", transport: "usb")

    func testBuiltInPolicyIgnoresHeadsetThatBecameDefault() {
        let chosen = MicInputPolicy.builtIn.select(from: [headset, builtIn, webcam], systemDefault: headset)
        XCTAssertEqual(chosen, builtIn)
    }

    func testBuiltInPolicyFallsBackToDefaultWithoutBuiltInMic() {
        let chosen = MicInputPolicy.builtIn.select(from: [headset, webcam], systemDefault: webcam)
        XCTAssertEqual(chosen, webcam)
    }

    func testDefaultPolicyFollowsSystem() {
        XCTAssertEqual(MicInputPolicy.systemDefault.select(from: [builtIn, headset], systemDefault: headset), headset)
    }

    func testSilentBuiltInFallsBackToDefaultFromSecondAttempt() {
        XCTAssertNil(MicInputPolicy.fallbackForSilentDevice(policy: .builtIn, pinned: builtIn, systemDefault: webcam, attemptsInEpisode: 1, signalIsStalled: true))
        XCTAssertEqual(MicInputPolicy.fallbackForSilentDevice(policy: .builtIn, pinned: builtIn, systemDefault: webcam, attemptsInEpisode: 2, signalIsStalled: true), webcam)
        // Padrão é o próprio embutido, ou já saiu do embutido, ou política antiga: nada a trocar.
        XCTAssertNil(MicInputPolicy.fallbackForSilentDevice(policy: .builtIn, pinned: builtIn, systemDefault: builtIn, attemptsInEpisode: 3, signalIsStalled: true))
        XCTAssertNil(MicInputPolicy.fallbackForSilentDevice(policy: .builtIn, pinned: webcam, systemDefault: headset, attemptsInEpisode: 3, signalIsStalled: true))
        XCTAssertNil(MicInputPolicy.fallbackForSilentDevice(policy: .systemDefault, pinned: builtIn, systemDefault: webcam, attemptsInEpisode: 3, signalIsStalled: true))
    }

    func testConfigurationAttemptsBeforeRealStallDoNotAbandonBuiltInMic() {
        // 10:54 e 12:06 trocaram para Bluetooth com 1,3 e 3,1 s de captura,
        // apenas porque duas notificações já tinham disparado rearmes.
        XCTAssertNil(MicInputPolicy.fallbackForSilentDevice(
            policy: .builtIn, pinned: builtIn, systemDefault: headset,
            attemptsInEpisode: 2, signalIsStalled: false
        ))
    }

    func testDigitalSilenceIsNotSignal() {
        XCTAssertFalse(pcmHasSignal(Data(count: 4_096)))
        var noise = Data(count: 4_096)
        noise[1_001] = 1
        XCTAssertTrue(pcmHasSignal(noise))
        XCTAssertFalse(pcmHasSignal(Data()))
    }

    func testPolicyParsesConfigValues() {
        XCTAssertEqual(MicInputPolicy(rawValue: "builtin"), .builtIn)
        XCTAssertEqual(MicInputPolicy(rawValue: "default"), .systemDefault)
        XCTAssertNil(MicInputPolicy(rawValue: "headset"))
    }

    func testTransportNames() {
        XCTAssertEqual(MicInputDevices.transportName(kAudioDeviceTransportTypeBuiltIn), "built-in")
        XCTAssertEqual(MicInputDevices.transportName(kAudioDeviceTransportTypeBluetooth), "bluetooth")
        XCTAssertEqual(MicInputDevices.transportName(kAudioDeviceTransportTypeUSB), "usb")
    }

    // MARK: Diário

    func testEventLogKeepsMostRecentEntriesAndCountsDropped() {
        var log = MicEventLog()
        for index in 0..<(MicEventLog.capacity + 5) { log.append(at: Double(index), "evento \(index)") }
        XCTAssertEqual(log.entries.count, MicEventLog.capacity)
        XCTAssertEqual(log.droppedCount, 5)
        XCTAssertEqual(log.lines.first, "(5 eventos antigos descartados)")
        XCTAssertEqual(log.entries.last, "+204.0s evento 204")
    }

    func testRecorderLogsFirstAudioAndAudioAfterAttempt() {
        let recorder = MicRecorder(writer: WAVWriter())
        recorder.recordReceivedBuffer(hostTime: 1)
        recorder.recordReceivedBuffer(hostTime: 2)
        let arrivals = recorder.health.events.filter { $0.hasSuffix("buffers chegando") }
        XCTAssertEqual(arrivals.count, 1)
    }

    // MARK: Linha do tempo

    func testLongStallKeepsTimelineInsteadOfCappingAtThirtySeconds() {
        let gap = PCMGapFiller.silenceBeforeBuffer(
            lastSuccessfulWriteHostTime: hostTime(seconds: 0),
            lastSuccessfulWriteByteCount: 0,
            nextBufferHostTime: hostTime(seconds: 600)
        )
        XCTAssertFalse(gap.wasCapped)
        XCTAssertEqual(Double(gap.byteCount) / Double(PCMGapFiller.bytesPerSecond), 600, accuracy: 0.01)
    }

    func testChunkedSilenceWritesExactByteCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicResilienceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: "s.inprogress.wav")
        let count = 65_536 * 3 + 1_234
        XCTAssertTrue(writer.appendSilence(byteCount: count))
        XCTAssertEqual(writer.health.byteCount, UInt32(count))
        XCTAssertEqual(writer.health.appendCount, 4)
        XCTAssertTrue(writer.appendSilence(byteCount: 0))
    }

    // MARK: Integridade e UI

    @MainActor
    func testRoutineRearmWithoutLossStaysOutOfIntegrityIssues() {
        let issues = AppState.healthIssues(mic: micHealth(attempts: 2, successes: 1, silence: 0), system: nil)
        XCTAssertFalse(issues.contains { $0.contains("tentativa") })
    }

    @MainActor
    func testRecoveryThatNeverBroughtAudioBackIsAnIssue() {
        let issues = AppState.healthIssues(mic: micHealth(attempts: 6, successes: 0, silence: 0), system: nil)
        XCTAssertTrue(issues.contains { $0.contains("6 tentativa(s) de recuperação") })
    }

    @MainActor
    func testIntegrityCarriesMicDiagnostics() {
        let complete = AppState.captureIntegrity(issues: [], micEvents: ["+0.0s início"])
        XCTAssertEqual(complete.status, .complete)
        XCTAssertEqual(complete.diagnostics, ["+0.0s início"])
        XCTAssertNil(AppState.captureIntegrity(issues: ["x"], micEvents: []).diagnostics)
    }

    func testOldManifestWithoutDiagnosticsStillDecodes() throws {
        let json = #"{"status":"degraded","details":["microfone interrompido"]}"#
        let decoded = try JSONDecoder().decode(CaptureIntegrity.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .degraded(["microfone interrompido"]))
        XCTAssertNil(decoded.diagnostics)
    }

    @MainActor
    func testAlertMessagesByState() {
        XCTAssertNil(AppState.captureAlertMessage(for: .ok))
        XCTAssertNil(AppState.captureAlertMessage(for: .waitingForAudio))
        XCTAssertEqual(AppState.captureAlertMessage(for: .recovering(attempts: 2)), "Microfone sem áudio — tentativa 2 de recuperação.")
        XCTAssertTrue(AppState.captureAlertMessage(for: .failed(attempts: 6))?.contains("Reiniciar microfone") == true)
    }

    func testIndicatorTurnsRedOnlyForErrors() {
        XCTAssertEqual(AppIndicator.make(status: .idle, micState: .ok), .idle)
        XCTAssertEqual(AppIndicator.make(status: .recording, micState: .ok), .recording)
        XCTAssertEqual(AppIndicator.make(status: .recording, micState: .waitingForAudio), .recording)
        XCTAssertEqual(AppIndicator.make(status: .recording, micState: .recovering(attempts: 1)), .error)
        XCTAssertEqual(AppIndicator.make(status: .recording, micState: .failed(attempts: 6)), .error)
        XCTAssertEqual(AppIndicator.make(status: .error("permissão"), micState: .ok), .error)
    }

    func testErrorBadgeImageHasRedInTopRightCorner() throws {
        let image = AppIndicatorImage.logoWithErrorBadge(size: 36)
        XCTAssertFalse(image.isTemplate)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()

        var redPixels = 0
        for x in 18..<36 {
            for y in 0..<18 {   // bitmap: y=0 é o topo
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.7, color.greenComponent < 0.4, color.blueComponent < 0.4, color.alphaComponent > 0.5 {
                    redPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(redPixels, 20)
        if let path = ProcessInfo.processInfo.environment["MT_BADGE_PNG"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Helpers

    private func micHealth(attempts: UInt64, successes: UInt64, silence: UInt32) -> AudioCaptureHealth {
        AudioCaptureHealth(
            receivedBufferCount: 10,
            writtenByteCount: 1_000,
            firstBufferHostTime: 1,
            lastBufferHostTime: 2,
            firstErrorDescription: nil,
            recoveryAttemptCount: attempts,
            recoveryErrorDescription: nil,
            streamStopErrorDescription: nil,
            insertedSilenceByteCount: silence,
            recoverySuccessCount: successes
        )
    }

    private func hostTime(seconds: Double) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}
