import AudioToolbox
import AVFoundation
import Foundation
import ObjCExceptionCatcher

/// Captura do microfone com um único `AVAudioEngine` por gravação.
///
/// v1.6, depois da sessão de 01/out/2026 em que um headset Bluetooth conectou no
/// segundo do clique e a trilha morreu sem erro registrado:
/// - o dispositivo é fixado no início (`MicInputPolicy`), em vez de seguir o padrão
///   do sistema;
/// - o observer de configuração existe antes do primeiro `start`;
/// - start, rearme e stop rodam numa fila serial própria, nunca na thread que
///   posta a notificação;
/// - um watchdog rearma quando o tap para de receber buffers, mesmo sem
///   notificação, e só áudio novo conta como recuperação (`MicRecoveryPlanner`);
/// - as transições vão para um diário curto que acaba no manifest.
///
/// O rearme reaproveita o mesmo engine: um engine novo criado durante o voice
/// processing de outro processo grava zeros (reprovado em hardware no v1.5-wip).
final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writer: WAVWriter
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private let policy: MicInputPolicy
    private let controlQueue = DispatchQueue(label: "MeetingTranscriber.MicRecorder.control")
    private let healthLock = NSLock()
    private var configObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    /// Listener HAL no dispositivo fixado: troca de taxa ou desconexão não geram
    /// `AVAudioEngineConfigurationChange` quando o dispositivo é fixado à mão.
    private var deviceListener: (id: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

    // Só na controlQueue.
    private var active = false
    private var planner = MicRecoveryPlanner()
    private var pinnedDevice: MicInputDevice?
    private var configChangeToken: UInt64 = 0
    private var startedAtUptime: TimeInterval = 0
    /// Rearmes por notificação na janela recente: o teto e o backoff do planner
    /// valem para o watchdog; notificações têm limite próprio, contra laço de
    /// rearme que gera nova notificação.
    private var configRearmTimes: [TimeInterval] = []
    static let configRearmWindow: TimeInterval = 60
    static let maxConfigRearmsPerWindow = 8

    // Protegidos por healthLock (o tap escreve de outra thread).
    private var firstBufferHostTime: UInt64?
    private var lastReceivedBufferHostTime: UInt64?
    private var lastReceivedUptime: TimeInterval?
    /// Último buffer com sinal (alguma amostra diferente de zero). É o que conta
    /// como "áudio" para o watchdog: microfone embutido com a tampa fechada, ou
    /// engine preso em voice processing, entrega callbacks só com zeros.
    private var lastSignalUptime: TimeInterval?
    private var lastSuccessfulWriteHostTime: UInt64?
    private var lastSuccessfulWriteByteCount: Int = 0
    private var receivedBufferCount: UInt64 = 0
    private var processingErrorDescription: String?
    private var recoveryAttemptCount: UInt64 = 0
    private var recoverySuccessCount: UInt64 = 0
    private var recoveryErrorDescription: String?
    private var insertedSilenceByteCount: UInt32 = 0
    private var cappedGapCount: UInt64 = 0
    private var currentDeviceLabel: String?
    private var captureState: MicCaptureState = .waitingForAudio
    private var eventLog = MicEventLog()
    /// Marca a próxima chegada de áudio depois de uma tentativa, para registrá-la uma vez.
    private var awaitingAudioAfterAttempt = false

    /// Debounce das notificações de configuração: uma troca de rota Bluetooth
    /// dispara várias em menos de um segundo. Curto, porque o engine já parou
    /// quando a notificação chega; se o rearme cair no meio da troca, o watchdog
    /// repete.
    static let configChangeDebounce: TimeInterval = 0.2

    var firstBufferTime: UInt64? { healthLock.withLock { firstBufferHostTime } }

    var health: AudioCaptureHealth {
        let writerHealth = writer.health
        return healthLock.withLock {
            AudioCaptureHealth(
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
                recoverySuccessCount: recoverySuccessCount,
                currentDeviceLabel: currentDeviceLabel,
                captureState: captureState,
                events: eventLog.lines
            )
        }
    }

    init(
        stagingDirectory: URL? = nil,
        stagingFileName: String = "mic.inprogress.wav",
        preserveOnDeinit: Bool? = nil,
        policy: MicInputPolicy = AppConfig.micInputPolicy
    ) {
        self.writer = WAVWriter(
            stagingDirectory: stagingDirectory,
            stagingFileName: stagingDirectory == nil ? nil : stagingFileName,
            preserveOnDeinit: preserveOnDeinit
        )
        self.policy = policy
    }

    init(writer: WAVWriter, policy: MicInputPolicy = .systemDefault) {
        self.writer = writer
        self.policy = policy
    }

    // MARK: - Ciclo de vida

    func start() throws {
        try controlQueue.sync {
            startedAtUptime = Self.uptime()
            note("início: política \(policy.rawValue)")
            // Antes do start: uma troca de rota no primeiro segundo não pode passar
            // despercebida (o observer nascia depois do start até a 1.5).
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleConfigurationRearm(reason: "configuração")
            }
            do {
                pinnedDevice = resolveDevice(previous: nil)
                try configureAndStart()
            } catch {
                if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
                configObserver = nil
                note("início falhou: \(error.localizedDescription)")
                throw error
            }
            active = true
            startWatchdog()
        }
    }

    /// Botão "Reiniciar microfone": nova série de tentativas, sem esperar o backoff.
    func requestRecovery() {
        controlQueue.async { [weak self] in
            guard let self, self.active else { return }
            self.planner.resetForManualAttempt()
            self.rearm(reason: "manual")
        }
    }

    func stop(saveTo url: URL) throws {
        controlQueue.sync {
            // Fecha a conta de um rearme cujo áudio voltou depois do último tick.
            reconcileRecoveredAudio()
            active = false
            watchdog?.cancel()
            watchdog = nil
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
                self.configObserver = nil
            }
            removeDeviceListener()
            try? MTObjCExceptionCatcher.perform {
                self.engine.stop()
                self.engine.inputNode.removeTap(onBus: 0)
            }
            note("fim")
        }
        if !writer.isEmpty || writer.firstErrorDescription != nil {
            try writer.save(to: url)
        }
    }

    // MARK: - Configuração do engine (controlQueue)

    /// Fixa o dispositivo (quando a política pede), instala o tap no formato atual
    /// do hardware e inicia. Lança erro, inclusive NSException convertida pelo shim.
    private func configureAndStart() throws {
        if policy != .systemDefault, let pinnedDevice {
            try setInputDevice(pinnedDevice)
        }
        let device = policy == .systemDefault ? MicInputDevices.systemDefault() : pinnedDevice
        healthLock.withLock { currentDeviceLabel = device?.label }

        let srcFmt: AVAudioFormat
        do {
            srcFmt = try installTap(format: currentInputFormat(hardware: false))
        } catch {
            // Com o dispositivo fixado, o nó pode guardar o formato anterior a uma
            // troca de taxa ("Failed to create tap due to format mismatch"). Reset
            // do engine e formato lido do hardware; se falhar de novo, propaga.
            note("tap recusado (\(error.localizedDescription)); renovando o formato")
            try MTObjCExceptionCatcher.perform { self.engine.reset() }
            if policy != .systemDefault, let pinnedDevice {
                try setInputDevice(pinnedDevice)
            }
            srcFmt = try installTap(format: currentInputFormat(hardware: true))
        }

        var startError: Error?
        try MTObjCExceptionCatcher.perform {
            self.engine.prepare()
            do { try self.engine.start() } catch { startError = error }
        }
        if let startError { throw startError }
        if let pinnedDevice { listen(to: pinnedDevice) }
        note("configurado: \(device?.label ?? "dispositivo padrão") \(Int(srcFmt.sampleRate)) Hz/\(srcFmt.channelCount) ch")
    }

    /// `hardware: false` usa o formato de saída do nó (caminho da 1.5, provado em
    /// hardware); `true` usa o de entrada, que reflete o dispositivo após um reset.
    private func currentInputFormat(hardware: Bool) throws -> AVAudioFormat {
        var format: AVAudioFormat?
        try MTObjCExceptionCatcher.perform {
            let node = self.engine.inputNode
            format = hardware ? node.inputFormat(forBus: 0) : node.outputFormat(forBus: 0)
        }
        guard let format, format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MicRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Nenhum dispositivo de entrada de áudio disponível"])
        }
        return format
    }

    @discardableResult
    private func installTap(format srcFmt: AVAudioFormat) throws -> AVAudioFormat {
        guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw NSError(domain: "MicRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create mic audio converter"])
        }
        let inputNode = engine.inputNode
        try MTObjCExceptionCatcher.perform {
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: srcFmt) { [weak self] buf, time in
                guard let self else { return }
                let hostTime = time.isHostTimeValid ? time.hostTime : nil
                self.recordReceivedBuffer(hostTime: hostTime)
                switch convertToInt16MonoResult(buf, using: converter) {
                case .success(let data):
                    self.appendConvertedPCM(data, hostTime: hostTime)
                case .failure(let error):
                    self.recordProcessingFailure(error)
                }
            }
        }
        return srcFmt
    }

    /// Troca de taxa nominal ou desconexão do dispositivo fixado vira rearme
    /// imediato, como uma notificação de configuração do engine.
    private func listen(to device: MicInputDevice) {
        if let deviceListener, deviceListener.id == device.id { return }
        removeDeviceListener()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleConfigurationRearm(reason: "dispositivo mudou (taxa ou conexão)")
        }
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(device.id, &address, controlQueue, block)
        }
        deviceListener = (device.id, block)
    }

    private func removeDeviceListener() {
        guard let (id, block) = deviceListener else { return }
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(id, &address, controlQueue, block)
        }
        deviceListener = nil
    }

    private func setInputDevice(_ device: MicInputDevice) throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw NSError(domain: "MicRecorder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Unidade de entrada do microfone indisponível"])
        }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: "MicRecorder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Não foi possível fixar o microfone \(device.label) (status \(status))"])
        }
    }

    /// Mantém o dispositivo fixado enquanto ele existir (o ID numérico pode mudar);
    /// se sumiu, escolhe de novo pela política e registra a troca.
    private func resolveDevice(previous: MicInputDevice?) -> MicInputDevice? {
        guard policy != .systemDefault else { return nil }
        if let previous, let same = MicInputDevices.find(uid: previous.uid) {
            return same
        }
        let chosen = policy.select(from: MicInputDevices.all(), systemDefault: MicInputDevices.systemDefault())
        if let previous {
            note("dispositivo fixado indisponível (\(previous.label)); usando \(chosen?.label ?? "nenhum")")
        } else if let chosen {
            note("dispositivo fixado: \(chosen.label)")
        }
        return chosen
    }

    // MARK: - Recuperação (controlQueue)

    private func scheduleConfigurationRearm(reason: String) {
        controlQueue.async { [weak self] in
            guard let self, self.active else { return }
            self.configChangeToken &+= 1
            let token = self.configChangeToken
            self.note("notificado: \(reason)")
            self.controlQueue.asyncAfter(deadline: .now() + Self.configChangeDebounce) { [weak self] in
                guard let self, self.active, token == self.configChangeToken else { return }
                let now = Self.uptime()
                self.configRearmTimes = self.configRearmTimes.filter { now - $0 < Self.configRearmWindow }
                guard self.configRearmTimes.count < Self.maxConfigRearmsPerWindow else {
                    self.note("notificações em excesso; rearme fica com o watchdog")
                    return
                }
                self.configRearmTimes.append(now)
                self.rearm(reason: reason)
            }
        }
    }

    private func rearm(reason: String) {
        let running = engine.isRunning
        // Para antes de marcar a tentativa: depois do stop o tap antigo não entrega
        // mais nada, então só um buffer do tap novo pode encerrar o episódio.
        try? MTObjCExceptionCatcher.perform {
            if self.engine.isRunning { self.engine.stop() }
        }
        let now = Self.uptime()
        planner.noteAttempt(at: now)
        healthLock.withLock {
            recoveryAttemptCount &+= 1
            awaitingAudioAfterAttempt = true
        }
        note("rearme (\(reason)), tentativa \(planner.attemptsInEpisode); engine rodando=\(running)")
        do {
            pinnedDevice = resolveDevice(previous: pinnedDevice)
            if let fallback = MicInputPolicy.fallbackForSilentDevice(
                policy: policy,
                pinned: pinnedDevice,
                systemDefault: MicInputDevices.systemDefault(),
                attemptsInEpisode: planner.attemptsInEpisode
            ) {
                note("\(pinnedDevice?.label ?? "microfone") sem sinal; usando \(fallback.label)")
                pinnedDevice = fallback
            }
            try configureAndStart()
        } catch {
            recordRearmFailure(error)
            note("rearme falhou: \(error.localizedDescription)")
        }
        refreshCaptureState(now: now)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard active else { return }
        let now = Self.uptime()
        reconcileRecoveredAudio()
        let (lastSignal, lastCallback) = healthLock.withLock { (lastSignalUptime, lastReceivedUptime) }
        let wasExhausted = planner.exhausted
        if planner.evaluate(now: now, lastAudioAt: lastSignal ?? startedAtUptime) == .attempt {
            let reason: String
            if lastCallback.map({ now - $0 <= MicRecoveryPlanner.stallThreshold }) == true {
                reason = "callbacks só com zeros"
            } else {
                reason = lastSignal == nil ? "sem áudio desde o início" : "microfone parado"
            }
            rearm(reason: reason)
        } else if planner.exhausted, !wasExhausted {
            note("recuperação automática esgotada após \(planner.attemptsInEpisode) tentativas")
        }
        refreshCaptureState(now: now)
    }

    /// Sinal novo depois da última tentativa encerra o episódio (sucesso).
    private func reconcileRecoveredAudio() {
        let lastSignal = healthLock.withLock { lastSignalUptime }
        if let lastSignal, planner.noteAudio(at: lastSignal) {
            healthLock.withLock { recoverySuccessCount &+= 1 }
        }
    }

    private func refreshCaptureState(now: TimeInterval) {
        let lastAudio = healthLock.withLock { lastSignalUptime }
        let state = planner.state(now: now, lastAudioAt: lastAudio, captureStartedAt: startedAtUptime)
        healthLock.withLock { captureState = state }
    }

    /// Diário: tempo desde o início da captura + mensagem. Pode ser chamado do tap.
    private func note(_ message: String) {
        let elapsed = Self.uptime() - startedAtUptime
        healthLock.withLock { eventLog.append(at: max(0, elapsed), message) }
    }

    static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Callback do tap

    func recordRearmFailure(_ error: Error) {
        healthLock.withLock {
            if recoveryErrorDescription == nil {
                recoveryErrorDescription = error.localizedDescription
            }
        }
    }

    func recordReceivedBuffer(hostTime: UInt64?) {
        let now = Self.uptime()
        let firstAfterAttempt: Bool = healthLock.withLock {
            if firstBufferHostTime == nil { firstBufferHostTime = hostTime }
            if let hostTime { lastReceivedBufferHostTime = hostTime }
            lastReceivedUptime = now
            receivedBufferCount &+= 1
            let first = awaitingAudioAfterAttempt || receivedBufferCount == 1
            awaitingAudioAfterAttempt = false
            return first
        }
        if firstAfterAttempt { note("áudio chegando") }
    }

    func recordProcessingFailure(_ error: Error) {
        healthLock.withLock {
            if processingErrorDescription == nil {
                processingErrorDescription = error.localizedDescription
            }
        }
    }

    private func appendConvertedPCM(_ data: Data, hostTime: UInt64?) {
        let gap = healthLock.withLock {
            PCMGapFiller.silenceBeforeBuffer(
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                lastSuccessfulWriteByteCount: lastSuccessfulWriteByteCount,
                nextBufferHostTime: hostTime
            )
        }
        if !gap.isEmpty {
            guard writer.appendSilence(byteCount: gap.byteCount) else { return }
            healthLock.withLock {
                insertedSilenceByteCount &+= UInt32(clamping: gap.byteCount)
                if gap.wasCapped {
                    cappedGapCount &+= 1
                    if processingErrorDescription == nil {
                        processingErrorDescription = "Um intervalo sem callbacks excedeu \(Int(PCMGapFiller.maxSilenceSeconds)) segundos e foi limitado."
                    }
                }
            }
            let seconds = Double(gap.byteCount) / Double(PCMGapFiller.bytesPerSecond)
            if seconds >= 0.25 { note(String(format: "silêncio inserido: %.1f s", seconds)) }
        }
        if pcmHasSignal(data) {
            let now = Self.uptime()
            healthLock.withLock { lastSignalUptime = now }
        }
        guard writer.append(data) else { return }
        recordSuccessfulWrite(hostTime: hostTime, byteCount: data.count)
    }

    func recordSuccessfulWrite(hostTime: UInt64?, byteCount: Int) {
        healthLock.withLock {
            lastSuccessfulWriteHostTime = hostTime
            lastSuccessfulWriteByteCount = byteCount
        }
    }
}
