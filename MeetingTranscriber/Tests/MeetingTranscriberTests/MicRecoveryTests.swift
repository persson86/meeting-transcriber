import AVFoundation
import CoreMedia
import Foundation
import ObjCExceptionCatcher
import XCTest
@testable import MeetingTranscriber

/// Recuperação do mic sem hardware: engine falso, relógio/agendador falsos e a fila
/// de controle real (injetada) para sincronizar com o teste.
final class MicRecoveryTests: XCTestCase {
    private var directory: URL!
    private var scheduler: FakeMicScheduler!
    private var controlQueue: DispatchQueue!
    private var engines: [FakeCaptureEngine] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scheduler = FakeMicScheduler()
        controlQueue = DispatchQueue(label: "MicRecoveryTests.control")
        engines = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Sem fallback: estes testes cobrem só o caminho primário. O default de produção
    /// (`CaptureSessionEngine`) nunca pode ser instanciado em teste — tocaria o mic real.
    private func makeRecorder(writer: WAVWriter? = nil, startError: Error? = nil) -> MicRecorder {
        MicRecorder(
            writer: writer ?? WAVWriter(),
            engineFactory: { [unowned self] in
                let engine = FakeCaptureEngine()
                engine.startError = startError
                self.engines.append(engine)
                return engine
            },
            fallbackEngineFactory: nil,
            scheduler: scheduler,
            controlQueue: controlQueue
        )
    }

    /// A notificação de configuração chega por `controlQueue.async`; um sync vazio a drena.
    private func flushControlQueue() {
        controlQueue.sync {}
    }

    // MARK: - Shim ObjC

    func testShimTurnsObjCExceptionIntoSwiftError() {
        XCTAssertThrowsError(try MTObjCExceptionCatcher.raiseTestException(withReason: "tap inválido")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, MTObjCExceptionErrorDomain)
            XCTAssertEqual(nsError.userInfo[MTObjCExceptionReasonKey] as? String, "tap inválido")
            XCTAssertEqual(nsError.userInfo[MTObjCExceptionNameKey] as? String, "MTTestException")
            XCTAssertTrue(nsError.localizedDescription.contains("tap inválido"))
        }
        XCTAssertNoThrow(try MTObjCExceptionCatcher.perform {})
    }

    // MARK: - Ciclo básico

    func testStartInstallsTapPreparesStartsAndObserves() throws {
        let recorder = makeRecorder()
        try recorder.start()

        XCTAssertEqual(engines.count, 1)
        let engine = engines[0]
        XCTAssertEqual(engine.installTapCount, 1)
        XCTAssertEqual(engine.prepareCount, 1)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.handlerSetCount, 1)
        XCTAssertEqual(recorder.health.currentDeviceName, "Fake Mic")
        XCTAssertEqual(recorder.health.currentDeviceTransport, "virtual")
        XCTAssertEqual(recorder.health.rebuildCount, 0)
        XCTAssertFalse(recorder.health.isStalled)

        try recorder.stop(saveTo: directory.appendingPathComponent("mic.wav"))
        XCTAssertEqual(engine.removeTapCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.handlerClearedCount, 1)
    }

    func testStartFailureIsThrownAndPartialEngineIsCleanedUp() {
        let recorder = makeRecorder(startError: TestError.start)
        XCTAssertThrowsError(try recorder.start())
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(engines[0].removeTapCount, 1)
        XCTAssertEqual(engines[0].handlerSetCount, 0)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 0)
    }

    // MARK: - Watchdog

    func testWatchdogRebuildsOnlyAfterThreeSecondsWithoutBuffers() throws {
        let recorder = makeRecorder()
        try recorder.start()

        scheduler.advance(to: 3.0)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 0)
        XCTAssertEqual(engines.count, 1)

        scheduler.advance(to: 4.0)
        let health = recorder.health
        XCTAssertEqual(health.recoveryAttemptCount, 1)
        XCTAssertEqual(health.rebuildCount, 1)
        XCTAssertEqual(health.recoverySuccessCount, 0)
        XCTAssertEqual(health.lastRebuildReason, "stall")
        XCTAssertTrue(health.isStalled)
        XCTAssertEqual(engines.count, 2)

        let old = engines[0]
        XCTAssertEqual(old.removeTapCount, 1)
        XCTAssertEqual(old.stopCount, 1)
        XCTAssertEqual(old.handlerClearedCount, 1)
        XCTAssertEqual(engines[1].startCount, 1)
        XCTAssertEqual(engines[1].handlerSetCount, 1)

        // Recuperação só conta depois de PCM escrito pelo engine novo.
        engines[1].emitBuffer(hostTimeSeconds: 4.1)
        XCTAssertEqual(recorder.health.recoverySuccessCount, 1)
        XCTAssertFalse(recorder.health.isStalled)
        XCTAssertTrue(recorder.health.hasAudio)
    }

    func testWatchdogDoesNotRebuildWhileBuffersFlow() throws {
        let recorder = makeRecorder()
        try recorder.start()

        for step in 1...20 {
            scheduler.advance(to: Double(step) * 0.5)
            engines[0].emitBuffer(hostTimeSeconds: Double(step) * 0.5)
        }

        XCTAssertEqual(recorder.health.recoveryAttemptCount, 0)
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(recorder.health.receivedBufferCount, 20)
        XCTAssertFalse(recorder.health.isStalled)
    }

    // MARK: - Notificação de configuração

    func testConfigurationChangeWithoutBuffersRebuildsAfterDebounce() throws {
        let recorder = makeRecorder()
        try recorder.start()
        engines[0].emitBuffer(hostTimeSeconds: 0.1)

        engines[0].fireConfigurationChange()
        flushControlQueue()

        scheduler.advance(to: 0.4)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 0)
        scheduler.advance(to: 0.5)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 1)
        XCTAssertEqual(recorder.health.lastRebuildReason, "configuration-change")
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engines[0].removeTapCount, 1)
        XCTAssertEqual(engines[0].handlerClearedCount, 1)
    }

    func testConfigurationChangeWithFlowingBuffersDoesNotRebuild() throws {
        let recorder = makeRecorder()
        try recorder.start()

        engines[0].fireConfigurationChange()
        flushControlQueue()
        scheduler.advance(to: 0.2)
        engines[0].emitBuffer(hostTimeSeconds: 0.2)
        scheduler.advance(to: 1.0)

        XCTAssertEqual(recorder.health.recoveryAttemptCount, 0)
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(engines[0].removeTapCount, 0)
    }

    // MARK: - Stop durante rebuild pendente

    func testStopDuringPendingRebuildCancelsRebuildAndSaves() throws {
        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: "mic.inprogress.wav")
        let recorder = makeRecorder(writer: writer)
        try recorder.start()
        engines[0].emitBuffer(hostTimeSeconds: 0.1)
        let lateTap = engines[0].tapBlock

        engines[0].fireConfigurationChange()
        flushControlQueue()

        let output = directory.appendingPathComponent("mic.wav")
        try recorder.stop(saveTo: output)
        scheduler.advance(to: 10.0)

        XCTAssertEqual(recorder.health.recoveryAttemptCount, 0)
        XCTAssertEqual(engines.count, 1)
        let savedSize = try Data(contentsOf: output).count
        XCTAssertEqual(savedSize, 44 + FakeCaptureEngine.bytesPerBuffer)

        // Callback atrasado do engine antigo depois do stop: geração inválida, nada é escrito.
        lateTap?(FakeCaptureEngine.makeBuffer(), AVAudioTime(hostTime: hostTicks(1.0)))
        XCTAssertEqual(recorder.health.receivedBufferCount, 1)
        XCTAssertEqual(try Data(contentsOf: output).count, savedSize)
    }

    // MARK: - Gerações

    func testOldGenerationBuffersAreIgnoredAfterRebuild() throws {
        let recorder = makeRecorder()
        try recorder.start()
        engines[0].emitBuffer(hostTimeSeconds: 0.1)
        let oldTap = engines[0].tapBlock

        scheduler.advance(to: 4.0) // stall → rebuild
        XCTAssertEqual(engines.count, 2)
        let bytesBefore = recorder.health.writtenByteCount

        oldTap?(FakeCaptureEngine.makeBuffer(), AVAudioTime(hostTime: hostTicks(4.0)))
        XCTAssertEqual(recorder.health.receivedBufferCount, 1)
        XCTAssertEqual(recorder.health.writtenByteCount, bytesBefore)

        engines[1].emitBuffer(hostTimeSeconds: 4.1)
        XCTAssertEqual(recorder.health.receivedBufferCount, 2)
        XCTAssertGreaterThan(recorder.health.writtenByteCount, bytesBefore)
        XCTAssertEqual(recorder.health.recoverySuccessCount, 1)
    }

    // MARK: - Gaps longos

    func testGapLongerThanThirtySecondsIsPreservedOnMicTrack() throws {
        let recorder = makeRecorder()
        try recorder.start()

        engines[0].emitBuffer(hostTimeSeconds: 0.0)
        engines[0].emitBuffer(hostTimeSeconds: 60.0)

        let health = recorder.health
        let bufferSeconds = Double(FakeCaptureEngine.bytesPerBuffer) / Double(PCMGapFiller.bytesPerSecond)
        let expectedGap = (60.0 - bufferSeconds) * Double(PCMGapFiller.bytesPerSecond)
        XCTAssertEqual(Double(health.insertedSilenceByteCount), expectedGap, accuracy: 4)
        XCTAssertEqual(health.cappedGapCount, 0)
        XCTAssertEqual(
            Int(health.writtenByteCount),
            2 * FakeCaptureEngine.bytesPerBuffer + Int(health.insertedSilenceByteCount)
        )
    }

    func testGapFillerCapsOnlyBeyondSessionScale() {
        let below = PCMGapFiller.silenceBeforeBuffer(
            lastSuccessfulWriteHostTime: hostTicks(0),
            lastSuccessfulWriteByteCount: 0,
            nextBufferHostTime: hostTicks(120),
            maxSilenceSeconds: PCMGapFiller.sessionMaxSilenceSeconds
        )
        XCTAssertFalse(below.wasCapped)
        XCTAssertEqual(below.byteCount, 120 * PCMGapFiller.bytesPerSecond)

        let beyond = PCMGapFiller.silenceBeforeBuffer(
            lastSuccessfulWriteHostTime: hostTicks(0),
            lastSuccessfulWriteByteCount: 0,
            nextBufferHostTime: hostTicks(PCMGapFiller.sessionMaxSilenceSeconds + 1),
            maxSilenceSeconds: PCMGapFiller.sessionMaxSilenceSeconds
        )
        XCTAssertTrue(beyond.wasCapped)
        XCTAssertEqual(beyond.byteCount, Int(PCMGapFiller.sessionMaxSilenceSeconds) * PCMGapFiller.bytesPerSecond)
    }

    func testWriterAppendsLongSilenceInBoundedBlocks() throws {
        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: "silence.inprogress.wav")
        let total = WAVWriter.silenceBlockSize * 2 + 10

        XCTAssertTrue(writer.appendSilence(byteCount: total))
        XCTAssertEqual(Int(writer.health.byteCount), total)

        let output = directory.appendingPathComponent("silence.wav")
        try writer.save(to: output)
        XCTAssertEqual(try Data(contentsOf: output).count, 44 + total)
    }

    // MARK: - Backoff

    func testBackoffGrowsWhileSilentAndResetsAfterBuffer() throws {
        let recorder = makeRecorder()
        try recorder.start()
        func attempts() -> UInt64 { recorder.health.recoveryAttemptCount }

        scheduler.advance(to: 4.4)
        XCTAssertEqual(attempts(), 1)   // stall em t=4,0
        scheduler.advance(to: 4.6)
        XCTAssertEqual(attempts(), 2)   // +0,5 s
        scheduler.advance(to: 5.6)
        XCTAssertEqual(attempts(), 3)   // +1 s
        scheduler.advance(to: 7.6)
        XCTAssertEqual(attempts(), 4)   // +2 s
        scheduler.advance(to: 11.6)
        XCTAssertEqual(attempts(), 5)   // +4 s
        scheduler.advance(to: 16.6)
        XCTAssertEqual(attempts(), 6)   // teto de 5 s
        XCTAssertEqual(engines.count, 7)

        engines.last?.emitBuffer(hostTimeSeconds: 16.6)
        XCTAssertEqual(recorder.health.recoverySuccessCount, 1)

        scheduler.advance(to: 19.9)
        XCTAssertEqual(attempts(), 6)
        scheduler.advance(to: 20.0)
        XCTAssertEqual(attempts(), 7)   // novo stall 3 s após o último buffer
        scheduler.advance(to: 20.5)
        XCTAssertEqual(attempts(), 8)   // backoff voltou ao início (0,5 s), não ao teto
    }

    // MARK: - Conversor por geração

    func testTapConverterRecreatesItselfWhenFormatChanges() {
        let converter = TapConverter(destination: AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        )!)

        guard case .success(let first) = converter.convert(FakeCaptureEngine.makeBuffer()) else {
            return XCTFail("conversão 16 kHz falhou")
        }
        XCTAssertEqual(first.count, FakeCaptureEngine.bytesPerBuffer)
        XCTAssertEqual(converter.inputFormat?.sampleRate, 16_000)

        guard case .success(let second) = converter.convert(
            FakeCaptureEngine.makeBuffer(sampleRate: 48_000, frames: 480)
        ) else {
            return XCTFail("conversão 48 kHz falhou")
        }
        XCTAssertGreaterThan(second.count, 0)
        XCTAssertEqual(converter.inputFormat?.sampleRate, 48_000)
    }

    private enum TestError: LocalizedError {
        case start

        var errorDescription: String? { "start falhou" }
    }
}

// MARK: - Fakes

func hostTicks(_ seconds: Double) -> UInt64 {
    CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
}

final class FakeCaptureEngine: MicCaptureEngine {
    /// 160 frames a 16 kHz → 320 bytes Int16 mono; sem resample, a contagem é exata.
    static let bytesPerBuffer = 320

    var isRunning = false
    var inputDevice: MicInputDevice? = MicInputDevice(name: "Fake Mic", uid: "fake-uid", transport: "virtual")
    var startError: Error?
    var backendName = "audioEngine"

    private(set) var tapBlock: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private(set) var handler: (() -> Void)?
    private(set) var installTapCount = 0
    private(set) var removeTapCount = 0
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handlerSetCount = 0
    private(set) var handlerClearedCount = 0

    func installInputTap(
        bufferSize: AVAudioFrameCount,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        installTapCount += 1
        tapBlock = block
    }

    func removeInputTap() throws {
        removeTapCount += 1
        tapBlock = nil
    }

    func prepare() throws { prepareCount += 1 }

    func start() throws {
        if let startError { throw startError }
        startCount += 1
        isRunning = true
    }

    func stop() throws {
        stopCount += 1
        isRunning = false
    }

    func setConfigurationChangeHandler(_ handler: (() -> Void)?) {
        if handler == nil { handlerClearedCount += 1 } else { handlerSetCount += 1 }
        self.handler = handler
    }

    /// Por padrão o buffer carrega ruído baixo não-zero, como um mic real; `value: 0`
    /// simula silêncio digital (stream quebrado).
    func emitBuffer(hostTimeSeconds: Double, value: Float = FakeCaptureEngine.defaultSampleValue) {
        tapBlock?(Self.makeBuffer(value: value), AVAudioTime(hostTime: hostTicks(hostTimeSeconds)))
    }

    func fireConfigurationChange() {
        handler?()
    }

    static let defaultSampleValue: Float = 0.01

    static func makeBuffer(
        sampleRate: Double = 16_000,
        frames: AVAudioFrameCount = 160,
        value: Float = FakeCaptureEngine.defaultSampleValue
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData {
            channel[0].initialize(repeating: value, count: Int(frames))
        }
        return buffer
    }
}

/// Relógio determinístico. `advance` executa os trabalhos vencidos, em ordem, na fila
/// em que foram agendados (via sync), inclusive os que forem agendados no caminho.
final class FakeMicScheduler: MicRecoveryScheduler {
    final class Item: MicScheduledWork {
        let due: TimeInterval
        let queue: DispatchQueue
        let work: () -> Void
        var cancelled = false

        init(due: TimeInterval, queue: DispatchQueue, work: @escaping () -> Void) {
            self.due = due
            self.queue = queue
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var items: [Item] = []

    func now() -> TimeInterval {
        lock.withLock { current }
    }

    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        _ work: @escaping () -> Void
    ) -> MicScheduledWork {
        let item = Item(due: now() + delay, queue: queue, work: work)
        lock.withLock { items.append(item) }
        return item
    }

    func advance(to target: TimeInterval) {
        while true {
            let next: Item? = lock.withLock {
                items.removeAll { $0.cancelled }
                guard let index = items.indices.min(by: { items[$0].due < items[$1].due }),
                      items[index].due <= target else { return nil }
                let item = items.remove(at: index)
                current = max(current, item.due)
                return item
            }
            guard let next else { break }
            next.queue.sync { next.work() }
        }
        lock.withLock { current = max(current, target) }
    }

    func advance(by delta: TimeInterval) {
        advance(to: now() + delta)
    }
}
