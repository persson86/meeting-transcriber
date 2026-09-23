import AVFoundation
import Foundation
import ObjCExceptionCatcher

// MARK: - Abstrações injetáveis (engine, relógio e agendador)

struct MicInputDevice: Equatable, Sendable {
    let name: String?
    let uid: String?
    let transport: String?
}

/// Superfície mínima do AVAudioEngine usada pelo MicRecorder. Em produção é o
/// AVAudioEngine atrás do shim ObjC; nos testes, um engine falso.
protocol MicCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    var inputDevice: MicInputDevice? { get }
    /// Tap com `format: nil`: o formato real chega em cada buffer.
    func installInputTap(
        bufferSize: AVAudioFrameCount,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws
    func removeInputTap() throws
    func prepare() throws
    func start() throws
    func stop() throws
    /// Um único handler de AVAudioEngineConfigurationChange; nil remove o observer.
    func setConfigurationChangeHandler(_ handler: (() -> Void)?)
    /// Nome do backend para health/meta ("audioEngine" ou "captureSession").
    var backendName: String { get }
}

extension MicCaptureEngine {
    var backendName: String { "audioEngine" }
}

protocol MicScheduledWork: AnyObject {
    func cancel()
}

extension DispatchWorkItem: MicScheduledWork {}

/// Relógio monotônico e agendamento na fila de controle. Falso nos testes.
protocol MicRecoveryScheduler {
    func now() -> TimeInterval
    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        _ work: @escaping () -> Void
    ) -> MicScheduledWork
}

struct DispatchMicScheduler: MicRecoveryScheduler {
    func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        _ work: @escaping () -> Void
    ) -> MicScheduledWork {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}

/// AVAudioEngine real. Nenhuma chamada que possa levantar NSException roda em Swift:
/// tudo passa pelo MTAudioEngineShim (ObjC), que devolve NSError.
final class ShimmedAudioEngine: MicCaptureEngine {
    private let shim = MTAudioEngineShim()
    private var observer: NSObjectProtocol?

    var isRunning: Bool { shim.isRunning }

    var inputDevice: MicInputDevice? {
        let name = shim.inputDeviceName
        let uid = shim.inputDeviceUID
        guard name != nil || uid != nil else { return nil }
        return MicInputDevice(name: name, uid: uid, transport: shim.inputDeviceTransport)
    }

    func installInputTap(
        bufferSize: AVAudioFrameCount,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        try shim.installInputTap(withBufferSize: bufferSize, block: block)
    }

    func removeInputTap() throws { try shim.removeInputTap() }
    func prepare() throws { try shim.prepare() }
    func start() throws { try shim.start() }
    func stop() throws { try shim.stop() }

    func setConfigurationChangeHandler(_ handler: (() -> Void)?) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let handler else { return }
        // queue: nil entrega na fila interna do AVFAudio; por isso o handler só agenda.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: shim.engine,
            queue: nil
        ) { _ in handler() }
    }

    deinit {
        setConfigurationChangeHandler(nil)
    }
}

// MARK: - MicRecorder

/// Captura do microfone com recuperação própria: uma fila serial de controle é dona
/// de start/rebuild/stop/watchdog; o callback do tap só usa um lock curto. Um engine
/// que para de entregar buffers é descartado e substituído por um AVAudioEngine novo.
final class MicRecorder: @unchecked Sendable {
    enum RebuildReason: String {
        case configurationChange = "configuration-change"
        case stall = "stall"
        /// Buffers chegam, mas só com zeros exatos: stream quebrado, não silêncio de sala.
        case digitalSilence = "digital-silence"
    }

    static let stallThresholdSeconds: TimeInterval = 3.0
    static let configurationCheckDelaySeconds: TimeInterval = 0.5
    static let watchdogIntervalSeconds: TimeInterval = 1.0
    static let retiredEngineHoldSeconds: TimeInterval = 1.0
    static let initialRetryDelaySeconds: TimeInterval = 0.5
    static let maxRetryDelaySeconds: TimeInterval = 5.0
    static let tapBufferSize: AVAudioFrameCount = 4096
    /// Rebuilds seguidos sem nenhum buffer aceito antes de trocar para o fallback.
    static let fallbackAfterSilentRebuilds: UInt64 = 2

    private let writer: WAVWriter
    private let engineFactory: () -> MicCaptureEngine
    private let fallbackEngineFactory: (() -> MicCaptureEngine)?
    private let scheduler: MicRecoveryScheduler
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!

    /// Fila serial de controle: start, rebuild, stop, watchdog e checagens.
    private let controlQueue: DispatchQueue
    /// Lock curto compartilhado com o callback do tap (geração, contadores, tempos).
    private let stateLock = NSLock()

    // Só na controlQueue.
    private var engine: MicCaptureEngine?
    private var retiredEngines: [MicCaptureEngine] = []
    private var watchdogWork: MicScheduledWork?
    private var configurationCheckWork: MicScheduledWork?
    private var retryWork: MicScheduledWork?
    private var buffersAtConfigurationChange: UInt64 = 0

    // Protegido por stateLock.
    private var currentGeneration: UInt64 = 0
    private var captureActive = false
    private var finalizing = false
    private var lastReceivedAt: TimeInterval?
    /// Último buffer com PCM não-zero. Só áudio real reseta stall, backoff e contagem de fallback.
    private var lastAudioAt: TimeInterval?
    private var digitalSilenceStallCount: UInt64 = 0
    private var lastRebuildAt: TimeInterval?
    private var retryDelay: TimeInterval = 0
    private var awaitingRecoveryPCM = false
    private var currentDevice: MicInputDevice?
    private var currentBackend: String?
    private var useFallback = false
    private var rebuildsSinceLastBuffer: UInt64 = 0
    private var fallbackActivatedCount: UInt64 = 0
    private var firstBufferHostTime: UInt64?
    private var lastReceivedBufferHostTime: UInt64?
    private var lastSuccessfulWriteHostTime: UInt64?
    private var lastSuccessfulWriteByteCount: Int = 0
    private var receivedBufferCount: UInt64 = 0
    private var processingErrorDescription: String?
    private var recoveryAttemptCount: UInt64 = 0
    private var rebuildCount: UInt64 = 0
    private var recoverySuccessCount: UInt64 = 0
    private var lastRebuildReason: String?
    private var recoveryErrorDescription: String?
    private var insertedSilenceByteCount: UInt32 = 0
    private var cappedGapCount: UInt64 = 0

    /// Mach absolute time do primeiro buffer recebido. Usado para calcular offset entre trilhas.
    var firstBufferTime: UInt64? { stateLock.withLock { firstBufferHostTime } }

    var health: AudioCaptureHealth {
        let writerHealth = writer.health
        let now = scheduler.now()
        return stateLock.withLock {
            let stalled = captureActive && !finalizing
                && (lastAudioAt.map { now - $0 > Self.stallThresholdSeconds } ?? false)
            return AudioCaptureHealth(
                receivedBufferCount: receivedBufferCount,
                writtenByteCount: writerHealth.byteCount,
                firstBufferHostTime: firstBufferHostTime,
                lastBufferHostTime: lastSuccessfulWriteHostTime,
                firstErrorDescription: processingErrorDescription ?? writerHealth.firstErrorDescription,
                recoveryAttemptCount: recoveryAttemptCount,
                recoveryErrorDescription: recoveryErrorDescription,
                streamStopErrorDescription: nil,
                lastReceivedBufferHostTime: lastReceivedBufferHostTime,
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                processingErrorDescription: processingErrorDescription,
                insertedSilenceByteCount: insertedSilenceByteCount,
                cappedGapCount: cappedGapCount,
                rebuildCount: rebuildCount,
                recoverySuccessCount: recoverySuccessCount,
                lastRebuildReason: lastRebuildReason,
                currentDeviceName: currentDevice?.name,
                currentDeviceUID: currentDevice?.uid,
                currentDeviceTransport: currentDevice?.transport,
                isStalled: stalled,
                captureBackend: currentBackend,
                fallbackActivatedCount: fallbackActivatedCount,
                digitalSilenceStallCount: digitalSilenceStallCount
            )
        }
    }

    convenience init(
        stagingDirectory: URL? = nil,
        stagingFileName: String = "mic.inprogress.wav",
        preserveOnDeinit: Bool? = nil
    ) {
        self.init(writer: WAVWriter(
            stagingDirectory: stagingDirectory,
            stagingFileName: stagingDirectory == nil ? nil : stagingFileName,
            preserveOnDeinit: preserveOnDeinit
        ))
    }

    init(
        writer: WAVWriter,
        engineFactory: @escaping () -> MicCaptureEngine = { ShimmedAudioEngine() },
        fallbackEngineFactory: (() -> MicCaptureEngine)? = { CaptureSessionEngine() },
        scheduler: MicRecoveryScheduler = DispatchMicScheduler(),
        controlQueue: DispatchQueue = DispatchQueue(label: "MeetingTranscriber.MicRecorder.control")
    ) {
        self.writer = writer
        self.engineFactory = engineFactory
        self.fallbackEngineFactory = fallbackEngineFactory
        self.scheduler = scheduler
        self.controlQueue = controlQueue
    }

    // MARK: Ciclo de vida

    func start() throws {
        try controlQueue.sync {
            guard engine == nil else {
                throw NSError(domain: "MicRecorder", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "A captura do microfone já foi iniciada."])
            }
            let now = scheduler.now()
            stateLock.withLock {
                captureActive = true
                finalizing = false
                currentGeneration = 1
                lastReceivedAt = now
                lastAudioAt = now
                retryDelay = 0
            }
            do {
                try buildEngine()
            } catch {
                stateLock.withLock { captureActive = false }
                throw error
            }
            scheduleWatchdogTick()
        }
    }

    func stop(saveTo url: URL) throws {
        try controlQueue.sync {
            cancelScheduledWork()
            // Invalida a geração antes de tocar no engine: nenhum append entra depois daqui.
            stateLock.withLock {
                captureActive = false
                finalizing = true
                currentGeneration &+= 1
            }
            if let engine {
                retireImmediately(engine)
                self.engine = nil
            }
            retiredEngines.removeAll()
            if !writer.isEmpty || writer.firstErrorDescription != nil {
                try writer.save(to: url)
            }
        }
    }

    // MARK: Construção e reconstrução (controlQueue)

    private func buildEngine() throws {
        let (generation, useFallbackEngine) = stateLock.withLock { (currentGeneration, useFallback) }
        // Uma vez no fallback, fica nele até o fim da sessão (sem alternar).
        let newEngine = (useFallbackEngine ? fallbackEngineFactory : nil)?() ?? engineFactory()
        let converter = TapConverter(destination: dstFmt)
        do {
            try newEngine.installInputTap(bufferSize: Self.tapBufferSize) { [weak self] buffer, time in
                self?.handleTapBuffer(buffer, at: time, generation: generation, converter: converter)
            }
            try newEngine.prepare()
            try newEngine.start()
        } catch {
            try? newEngine.removeInputTap()
            try? newEngine.stop()
            throw error
        }
        newEngine.setConfigurationChangeHandler { [weak self] in
            self?.configurationDidChange()
        }
        engine = newEngine
        let device = newEngine.inputDevice
        let backend = newEngine.backendName
        stateLock.withLock {
            currentDevice = device
            currentBackend = backend
            if generation > 1 { rebuildCount &+= 1 }
        }
    }

    private func rebuild(reason: RebuildReason) {
        let now = scheduler.now()
        let previous = engine
        engine = nil
        stateLock.withLock {
            currentGeneration &+= 1
            recoveryAttemptCount &+= 1
            lastRebuildReason = reason.rawValue
            lastRebuildAt = now
            retryDelay = retryDelay == 0
                ? Self.initialRetryDelaySeconds
                : min(retryDelay * 2, Self.maxRetryDelaySeconds)
            awaitingRecoveryPCM = true
            // Dois rebuilds seguidos sem buffer: o AVAudioEngine não vai voltar sozinho
            // (ex.: voice processing de outro app); a próxima reconstrução usa o fallback.
            if !useFallback, fallbackEngineFactory != nil,
               rebuildsSinceLastBuffer >= Self.fallbackAfterSilentRebuilds {
                useFallback = true
                fallbackActivatedCount &+= 1
            }
            rebuildsSinceLastBuffer &+= 1
        }
        if let previous { retire(previous) }
        do {
            try buildEngine()
        } catch {
            recordRearmFailure(error)
        }
        scheduleRetryCheck()
    }

    /// Para o engine antigo uma vez e o segura por ~1 s: um callback em voo não pode
    /// encontrar o objeto já liberado.
    private func retire(_ old: MicCaptureEngine) {
        retireImmediately(old)
        retiredEngines.append(old)
        _ = scheduler.schedule(after: Self.retiredEngineHoldSeconds, on: controlQueue) { [weak self] in
            self?.retiredEngines.removeAll { $0 === old }
        }
    }

    private func retireImmediately(_ old: MicCaptureEngine) {
        old.setConfigurationChangeHandler(nil)
        try? old.removeInputTap()
        try? old.stop()
    }

    // MARK: Notificação de mudança de configuração

    private func configurationDidChange() {
        controlQueue.async { [weak self] in
            self?.scheduleConfigurationCheck()
        }
    }

    private func scheduleConfigurationCheck() {
        guard isCaptureActive else { return }
        configurationCheckWork?.cancel()
        buffersAtConfigurationChange = stateLock.withLock { receivedBufferCount }
        configurationCheckWork = scheduler.schedule(
            after: Self.configurationCheckDelaySeconds,
            on: controlQueue
        ) { [weak self] in
            self?.runConfigurationCheck()
        }
    }

    private func runConfigurationCheck() {
        configurationCheckWork = nil
        guard isCaptureActive else { return }
        let received = stateLock.withLock { receivedBufferCount }
        // Buffers seguem chegando (ex.: mudou só a rota de saída): não mexe no engine.
        guard received == buffersAtConfigurationChange else { return }
        rebuild(reason: .configurationChange)
    }

    // MARK: Watchdog e backoff

    private func scheduleWatchdogTick() {
        watchdogWork?.cancel()
        watchdogWork = scheduler.schedule(after: Self.watchdogIntervalSeconds, on: controlQueue) { [weak self] in
            self?.watchdogTick()
        }
    }

    private func watchdogTick() {
        watchdogWork = nil
        guard isCaptureActive else { return }
        rebuildForStallIfNeeded()
        scheduleWatchdogTick()
    }

    private func scheduleRetryCheck() {
        retryWork?.cancel()
        let delay = stateLock.withLock { retryDelay }
        retryWork = scheduler.schedule(after: delay, on: controlQueue) { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            self.rebuildForStallIfNeeded()
        }
    }

    /// Stall = mais de 3 s sem áudio real (nenhum buffer, ou só zeros exatos). Entre
    /// tentativas sem sucesso vale o backoff; o primeiro buffer não-zero zera o backoff.
    private func rebuildForStallIfNeeded() {
        let now = scheduler.now()
        let reason: RebuildReason? = stateLock.withLock {
            guard captureActive, !finalizing, let lastAudioAt else { return nil }
            guard now - lastAudioAt > Self.stallThresholdSeconds else { return nil }
            if let lastRebuildAt, now - lastRebuildAt < retryDelay { return nil }
            let buffersStillArriving = (lastReceivedAt ?? lastAudioAt) > lastAudioAt
            if buffersStillArriving { digitalSilenceStallCount &+= 1 }
            return buffersStillArriving ? RebuildReason.digitalSilence : RebuildReason.stall
        }
        if let reason { rebuild(reason: reason) }
    }

    private var isCaptureActive: Bool {
        stateLock.withLock { captureActive && !finalizing }
    }

    private func cancelScheduledWork() {
        watchdogWork?.cancel(); watchdogWork = nil
        configurationCheckWork?.cancel(); configurationCheckWork = nil
        retryWork?.cancel(); retryWork = nil
    }

    // MARK: Callback do tap (thread de render do engine)

    private func handleTapBuffer(
        _ buffer: AVAudioPCMBuffer,
        at time: AVAudioTime,
        generation: UInt64,
        converter: TapConverter
    ) {
        let hostTime = time.isHostTimeValid ? time.hostTime : nil
        let now = scheduler.now()
        // Zeros exatos no formato de entrada: mic real sempre tem ruído de fundo.
        let isSilent = pcmBufferIsDigitalSilence(buffer)
        let accepted: Bool = stateLock.withLock {
            guard generation == currentGeneration, !finalizing else { return false }
            recordReceivedBufferLocked(hostTime: hostTime, now: now, isSilent: isSilent)
            return true
        }
        guard accepted else { return }
        // Conversão fora do lock: o conversor pertence a esta geração e só esta thread o usa.
        switch converter.convert(buffer) {
        case .success(let data):
            appendConvertedPCM(data, hostTime: hostTime, generation: generation, isSilent: isSilent)
        case .failure(let error):
            recordProcessingFailure(error)
        }
    }

    private func recordReceivedBufferLocked(hostTime: UInt64?, now: TimeInterval, isSilent: Bool) {
        if firstBufferHostTime == nil { firstBufferHostTime = hostTime }
        if let hostTime { lastReceivedBufferHostTime = hostTime }
        receivedBufferCount &+= 1
        lastReceivedAt = now
        guard !isSilent else { return }
        lastAudioAt = now
        retryDelay = 0
        rebuildsSinceLastBuffer = 0
    }

    private func appendConvertedPCM(_ data: Data, hostTime: UInt64?, generation: UInt64, isSilent: Bool) {
        stateLock.withLock {
            // Geração e finalização rechecadas aqui: um save nunca corre junto de um append.
            guard generation == currentGeneration, !finalizing else { return }
            let gap = PCMGapFiller.silenceBeforeBuffer(
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                lastSuccessfulWriteByteCount: lastSuccessfulWriteByteCount,
                nextBufferHostTime: hostTime,
                maxSilenceSeconds: PCMGapFiller.sessionMaxSilenceSeconds
            )
            if gap.byteCount > 0 {
                guard writer.appendSilence(byteCount: gap.byteCount) else { return }
                insertedSilenceByteCount &+= UInt32(truncatingIfNeeded: gap.byteCount)
                if gap.wasCapped {
                    cappedGapCount &+= 1
                    if processingErrorDescription == nil {
                        processingErrorDescription = "Um intervalo sem callbacks excedeu \(Int(PCMGapFiller.sessionMaxSilenceSeconds)) segundos e foi limitado."
                    }
                }
            }
            guard writer.append(data) else { return }
            lastSuccessfulWriteHostTime = hostTime
            lastSuccessfulWriteByteCount = data.count
            if awaitingRecoveryPCM, !isSilent {
                // Recuperação só conta depois de PCM não-zero no disco; zeros são escritos
                // para preservar a linha do tempo, mas não provam que o mic voltou.
                awaitingRecoveryPCM = false
                recoverySuccessCount &+= 1
            }
        }
    }

    // MARK: Registro de saúde (também usados pelos testes sem hardware)

    func recordRearmFailure(_ error: Error) {
        stateLock.withLock {
            if recoveryErrorDescription == nil {
                recoveryErrorDescription = error.localizedDescription
            }
        }
    }

    func recordReceivedBuffer(hostTime: UInt64?) {
        let now = scheduler.now()
        stateLock.withLock { recordReceivedBufferLocked(hostTime: hostTime, now: now, isSilent: false) }
    }

    func recordProcessingFailure(_ error: Error) {
        stateLock.withLock {
            if processingErrorDescription == nil {
                processingErrorDescription = error.localizedDescription
            }
        }
    }

    func recordSuccessfulWrite(hostTime: UInt64?, byteCount: Int) {
        stateLock.withLock {
            lastSuccessfulWriteHostTime = hostTime
            lastSuccessfulWriteByteCount = byteCount
        }
    }
}
