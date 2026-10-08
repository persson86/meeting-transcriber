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
/// v1.7, depois de 7/7 sessões `degraded` na 1.6.1: um único controle de
/// recuperação (`MicRecoveryPlanner`). Notificações de configuração não têm mais
/// orçamento próprio de rearmes; elas pedem ao planner, que aplica o mesmo
/// backoff do watchdog. O microfone não troca mais sozinho para outro dispositivo
/// por falta de sinal: o fallback para Bluetooth gerava dezenas de rearmes e
/// eco. As interrupções são medidas em segundos (`AudioLossTally`).
///
/// O rearme reaproveita o mesmo engine: um engine novo criado durante o voice
/// processing de outro processo grava zeros (reprovado em hardware no v1.5-wip).
final class MicRecorder: @unchecked Sendable {
    /// `.raw` (experimental, 07/out/2026): IOProc direto no mic embutido, sem
    /// AVAudioEngine — contingência para o inputNode preso ao padrão Bluetooth.
    enum CaptureBackend: String { case engine, raw }
    private lazy var engine = AVAudioEngine()
    private let captureBackend: CaptureBackend
    private var rawCapture: RawMicCapture?
    private let writer: WAVWriter
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private let policy: MicInputPolicy
    private let controlQueue = DispatchQueue(label: "MeetingTranscriber.MicRecorder.control")
    private let healthLock = NSLock()
    private var defaultInputToRestore: MicInputDevice?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var defaultReasserted = false
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
    private var lastConfiguredAtUptime: TimeInterval = 0
    private var configuredInputFormat: AVAudioFormat?
    private var lastManualRecoveryAtUptime: TimeInterval?
    static let manualRecoveryCooldown: TimeInterval = 3

    // Protegidos por healthLock (o tap escreve de outra thread).
    private var firstBufferHostTime: UInt64?
    private var lastReceivedBufferHostTime: UInt64?
    private var lastReceivedUptime: TimeInterval?
    /// Último buffer com sinal (alguma amostra diferente de zero). É o que conta
    /// como "áudio" para o watchdog: microfone embutido com a tampa fechada, ou
    /// engine preso em voice processing, entrega callbacks só com zeros.
    private var lastSignalUptime: TimeInterval?
    private var firstSignalHostTime: UInt64?
    private var lastSignalHostTime: UInt64?
    private var lastSignalByteCount = 0
    private var dropouts = AudioLossTally()
    private var trailingSilenceSeconds: TimeInterval?
    private var initialAudioDelaySeconds: TimeInterval?
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
    private var tapGeneration: UInt64 = 0

    /// Debounce das notificações de configuração: uma troca de rota Bluetooth
    /// dispara várias em menos de um segundo. Curto, porque o engine já parou
    /// quando a notificação chega; se o rearme cair no meio da troca, o watchdog
    /// repete.
    static let configChangeDebounce: TimeInterval = 0.2

    var firstBufferTime: UInt64? { healthLock.withLock { firstBufferHostTime } }

    var health: AudioCaptureHealth {
        return healthLock.withLock {
            let writerHealth = writer.health
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
                recoverySuccessCount: recoverySuccessCount,
                currentDeviceLabel: currentDeviceLabel,
                captureState: captureState,
                firstSignalHostTime: firstSignalHostTime,
                lastSignalHostTime: lastSignalHostTime,
                recoveryPending: awaitingAudioAfterAttempt,
                initialAudioDelaySeconds: initialAudioDelaySeconds,
                dropouts: dropouts,
                trailingSilenceSeconds: trailingSilenceSeconds,
                events: eventLog.lines
            )
        }
    }

    init(
        stagingDirectory: URL? = nil,
        stagingFileName: String = "mic.inprogress.wav",
        preserveOnDeinit: Bool? = nil,
        policy: MicInputPolicy = AppConfig.micInputPolicy,
        captureBackend: CaptureBackend = AppConfig.micCaptureBackend
    ) {
        self.writer = WAVWriter(
            stagingDirectory: stagingDirectory,
            stagingFileName: stagingDirectory == nil ? nil : stagingFileName,
            preserveOnDeinit: preserveOnDeinit
        )
        self.policy = policy
        self.captureBackend = captureBackend
    }

    init(writer: WAVWriter, policy: MicInputPolicy = .systemDefault,
         captureBackend: CaptureBackend = .engine) {
        self.writer = writer
        self.policy = policy
        self.captureBackend = captureBackend
    }

    // MARK: - Ciclo de vida

    func start() throws {
        try controlQueue.sync {
            startedAtUptime = Self.uptime()
            note("início: política \(policy.rawValue), backend \(captureBackend.rawValue)")
            // Antes do start: uma troca de rota no primeiro segundo não pode passar
            // despercebida (o observer nascia depois do start até a 1.5).
            if captureBackend == .engine {
                configObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { [weak self] _ in
                    self?.scheduleConfigurationRearm(reason: "configuração")
                }
            }
            do {
                if let restored = Self.restoreDefaultInputAfterCrashIfNeeded() { note("c1: \(restored)") }
                overrideDefaultInputIfNeeded()
                pinnedDevice = resolveDevice(previous: nil)
                try configureAndStart()
            } catch {
                if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
                configObserver = nil
                restoreDefaultInput()
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
            let now = Self.uptime()
            if let last = self.lastManualRecoveryAtUptime, now - last < Self.manualRecoveryCooldown {
                self.note("rearme manual já solicitado; aguardando a rota estabilizar")
                return
            }
            self.planner.resetForManualAttempt()
            self.rearm(reason: "manual")
            self.lastManualRecoveryAtUptime = Self.uptime()
        }
    }

    func stop(saveTo url: URL) throws {
        var shutdownError: Error?
        controlQueue.sync {
            // Fecha a conta de um rearme cujo áudio voltou depois do último tick.
            _ = beginTapGeneration()
            reconcileRecoveredAudio()
            let stoppedAt = Self.uptime()
            healthLock.withLock {
                trailingSilenceSeconds = max(0, stoppedAt - (lastSignalUptime ?? startedAtUptime))
            }
            active = false
            watchdog?.cancel()
            watchdog = nil
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
                self.configObserver = nil
            }
            removeDeviceListener()
            do { try stopCapture() } catch {
                // O salvamento segue mesmo se a parada falhar; o erro sobe depois.
                shutdownError = error
                recordProcessingFailure(error)
                note("parada falhou: \(error.localizedDescription)")
            }
            restoreDefaultInput()
            note("fim")
        }
        if !writer.isEmpty || writer.firstErrorDescription != nil {
            try writer.save(to: url)
        }
        if let shutdownError { throw shutdownError }
    }

    private var captureRunning: Bool {
        captureBackend == .raw ? rawCapture?.isRunning == true : engine.isRunning
    }

    private func stopCapture() throws {
        if captureBackend == .raw {
            try rawCapture?.stop()
            rawCapture = nil
        } else {
            try MTObjCExceptionCatcher.perform {
                self.engine.stop()
                self.engine.inputNode.removeTap(onBus: 0)
            }
        }
    }

    // MARK: - Entrada padrão do sistema (C1, controlQueue)

    /// Com a política builtin e outro dispositivo (fone Bluetooth, no caso medido)
    /// como entrada padrão, o inputNode do AVAudioEngine fica preso ao padrão e
    /// não entrega buffers (bateria de 07/out/2026; mesmo sintoma em jwulff/steno
    /// #104 e humanitas-labs/parrot #14). Antes de tocar no engine, a entrada
    /// padrão passa a ser o embutido; o stop restaura o anterior só se a entrada
    /// padrão ainda for a nossa e ele existir.
    private func overrideDefaultInputIfNeeded() {
        guard AppConfig.micDefaultInputOverride, policy == .builtIn,
              let current = MicInputDevices.systemDefault(), !current.isBuiltIn,
              let builtIn = MicInputDevices.all().first(where: \.isBuiltIn) else { return }
        let status = MicInputDevices.setSystemDefault(builtIn.id)
        if status == noErr {
            defaultInputToRestore = current
            // Marcador para restaurar no próximo lançamento se o app morrer no meio.
            UserDefaults.standard.set(current.uid, forKey: Self.pendingDefaultRestoreKey)
            note("c1: entrada padrão \(current.label) → \(builtIn.label) durante a gravação")
            listenToDefaultInputChanges(builtIn: builtIn)
        } else {
            note("c1: troca da entrada padrão falhou (status \(status))")
        }
    }

    static let pendingDefaultRestoreKey = "micDefaultInputPendingRestore"

    /// Chamado no lançamento do app: se uma gravação anterior morreu com a entrada
    /// padrão trocada, devolve o fone (só se a entrada padrão ainda for o embutido).
    static func restoreDefaultInputAfterCrashIfNeeded() -> String? {
        guard let uid = UserDefaults.standard.string(forKey: pendingDefaultRestoreKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingDefaultRestoreKey)
        guard let current = MicInputDevices.systemDefault(), current.isBuiltIn,
              let previous = MicInputDevices.find(uid: uid) else { return nil }
        let status = MicInputDevices.setSystemDefault(previous.id)
        return "entrada padrão restaurada para \(previous.label) após encerramento anormal (status \(status))"
    }

    /// macOS pode voltar a promover o fone a padrão (reconexão BT) no meio da
    /// gravação. Reafirma o embutido uma vez por gravação e registra; nunca em laço.
    private func listenToDefaultInputChanges(builtIn: MicInputDevice) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.active, self.defaultInputToRestore != nil else { return }
            guard let current = MicInputDevices.systemDefault(), !current.isBuiltIn else { return }
            if self.defaultReasserted {
                self.note("c1: entrada padrão mudou para \(current.label) de novo; deixando como está")
                self.defaultInputToRestore = nil
                UserDefaults.standard.removeObject(forKey: Self.pendingDefaultRestoreKey)
                return
            }
            self.defaultReasserted = true
            let status = MicInputDevices.setSystemDefault(builtIn.id)
            self.note("c1: entrada padrão voltou para \(current.label); reafirmado o embutido (status \(status))")
        }
        defaultInputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        defaultInputListener = nil
    }

    private func restoreDefaultInput() {
        removeDefaultInputListener()
        // O marcador é desta gravação; uma gravação que não trocou nada não pode
        // apagar o marcador deixado por um encerramento anormal anterior.
        guard let previous = defaultInputToRestore else { return }
        defaultInputToRestore = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingDefaultRestoreKey)
        guard let current = MicInputDevices.systemDefault(), current.isBuiltIn else {
            note("c1: entrada padrão mudou durante a gravação; não restaurada"); return
        }
        guard let same = MicInputDevices.find(uid: previous.uid) else {
            note("c1: \(previous.label) não está mais conectado; entrada padrão fica no embutido"); return
        }
        let status = MicInputDevices.setSystemDefault(same.id)
        note("c1: entrada padrão restaurada para \(same.label) (status \(status))")
    }

    // MARK: - Configuração do engine (controlQueue)

    /// Fixa o dispositivo (quando a política pede), instala o tap no formato atual
    /// do hardware e inicia. Lança erro, inclusive NSException convertida pelo shim.
    private func configureAndStart() throws {
        if captureBackend == .raw {
            try configureRaw()
            return
        }
        if policy != .systemDefault, let pinnedDevice {
            try setInputDevice(pinnedDevice)
        }
        let device = policy == .systemDefault ? MicInputDevices.systemDefault() : pinnedDevice
        healthLock.withLock { currentDeviceLabel = device?.label }

        // F8b: o 1º tap usa o formato do hardware, que evita a recusa 16→48 kHz.
        // Se o tap ou o start recusarem esse formato (visto em 07/out com fone BT
        // como entrada padrão depois de uma sessão HFP: erro -10868), reset do
        // engine e os caminhos da 1.7, nesta ordem: formato do nó, depois o do
        // hardware de novo. Só propaga quando os três falham.
        var srcFmt: AVAudioFormat?
        var lastError: Error?
        for (attempt, hardware) in [true, false, true].enumerated() {
            if attempt > 0 {
                try MTObjCExceptionCatcher.perform { self.engine.reset() }
                if policy != .systemDefault, let pinnedDevice {
                    try setInputDevice(pinnedDevice)
                }
            }
            do {
                srcFmt = try installTapAndStart(format: currentInputFormat(hardware: hardware))
                if attempt == 0 { note("f8b: tap com formato de hardware") }
                break
            } catch {
                lastError = error
                note("tap recusado (\(error.localizedDescription)); renovando o formato")
            }
        }
        guard let srcFmt else { throw lastError ?? NSError(domain: "MicRecorder", code: 6) }
        // Mesmo acessor da comparação em `scheduleConfigurationRearm`: o formato
        // de saída do nó pode diferir do de entrada em canais.
        configuredInputFormat = (try? currentInputFormat(hardware: true)) ?? srcFmt
        lastConfiguredAtUptime = Self.uptime()
        if let pinnedDevice { listen(to: pinnedDevice) }
        note("configurado: \(device?.label ?? "dispositivo padrão") \(Int(srcFmt.sampleRate)) Hz/\(srcFmt.channelCount) ch")
    }

    /// Backend raw: exige o mic embutido fixado (a política nunca cai no Bluetooth
    /// por fallback) e um cliente anterior já encerrado.
    private func configureRaw() throws {
        guard rawCapture == nil, let device = pinnedDevice, device.isBuiltIn else {
            throw NSError(domain: "MicRecorder", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Raw requer microfone embutido e cliente anterior encerrado"
            ])
        }
        let generation = beginTapGeneration()
        let capture = RawMicCapture(
            uid: device.uid,
            onBuffer: { [weak self] host in
                self?.recordReceivedBuffer(hostTime: host, generation: generation) ?? false
            },
            onPCM: { [weak self] data, host in
                self?.appendConvertedPCM(data, hostTime: host, generation: generation)
            },
            onError: { [weak self] error in
                self?.recordProcessingFailure(error, generation: generation)
            })
        rawCapture = capture
        healthLock.withLock { currentDeviceLabel = device.label }
        try capture.start()
        configuredInputFormat = capture.inputFormat
        lastConfiguredAtUptime = Self.uptime()
        listen(to: device)
        let rate = configuredInputFormat?.sampleRate ?? 0
        let channels = configuredInputFormat?.channelCount ?? 0
        note("configurado raw: \(device.label) \(Int(rate)) Hz/\(channels) ch")
    }

    /// Instala o tap e inicia o engine; qualquer recusa (tap ou start) sobe como
    /// erro para o chamador tentar outro formato.
    private func installTapAndStart(format: AVAudioFormat) throws -> AVAudioFormat {
        let srcFmt = try installTap(format: format)
        var startError: Error?
        try MTObjCExceptionCatcher.perform {
            self.engine.prepare()
            do { try self.engine.start() } catch { startError = error }
        }
        if let startError { throw startError }
        return srcFmt
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
        let generation = beginTapGeneration()
        try MTObjCExceptionCatcher.perform {
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: srcFmt) { [weak self] buf, time in
                guard let self else { return }
                let hostTime = time.isHostTimeValid ? time.hostTime : nil
                guard self.recordReceivedBuffer(hostTime: hostTime, generation: generation) else { return }
                switch convertToInt16MonoResult(buf, using: converter) {
                case .success(let data):
                    self.appendConvertedPCM(data, hostTime: hostTime, generation: generation)
                case .failure(let error):
                    self.recordProcessingFailure(error, generation: generation)
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
        for (selector, scope) in Self.deviceListenerSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(device.id, &address, controlQueue, block)
        }
        deviceListener = (device.id, block)
    }

    /// Taxa nominal, conexão e formato de stream de entrada (outro processo com
    /// voice processing muda o embutido de 1 para 3 canais, 07/out/2026).
    private static let deviceListenerSelectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput),
    ]

    private func removeDeviceListener() {
        guard let (id, block) = deviceListener else { return }
        for (selector, scope) in Self.deviceListenerSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
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
        // Um rearme do mesmo dispositivo não precisa pedir outra troca ao HAL.
        // Depois de reset/reconexão, confira o ID efetivo em vez de confiar no UID.
        var currentID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                kAudioUnitScope_Global, 0, &currentID, &size) == noErr,
           currentID == device.id {
            return
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
                let running = self.captureRunning
                // No raw, uma notificação HAL vale como formato mudado: o formato é
                // relido ao recriar a captura; o planner mantém o backoff.
                let currentFormat: AVAudioFormat? = self.captureBackend == .raw
                    ? nil : (try? self.currentInputFormat(hardware: true))
                let formatChanged = currentFormat?.sampleRate != self.configuredInputFormat?.sampleRate
                    || currentFormat?.channelCount != self.configuredInputFormat?.channelCount
                    || currentFormat == nil
                guard MicRecoveryPlanner.needsConfigurationRearm(
                    engineRunning: running,
                    inputFormatChanged: formatChanged
                ) else {
                    self.note("configuração já aplicada; engine continua rodando")
                    return
                }
                // Mesmo controle do watchdog: com o engine rodando, as tentativas
                // seguintes esperam o backoff, para a rota assentar. Com o engine
                // parado (F8a) o rearme é imediato, até 3 vezes em 10 s.
                guard self.planner.allowsConfigurationAttempt(now: Self.uptime(), engineRunning: running) else {
                    self.note("rearme recente; o watchdog decide a próxima tentativa")
                    return
                }
                if !running { self.note("f8a: rearme imediato") }
                self.rearm(reason: reason)
            }
        }
    }

    private func rearm(reason: String) {
        AppLog.recovery.info("rearm reason=\(reason, privacy: .public)")
        let running = captureRunning
        // A geração nova (recordRecoveryAttempt) já rejeita uma conversão antiga
        // ainda em andamento quando o stop retorna.
        recordRecoveryAttempt()
        let now = Self.uptime()
        planner.noteAttempt(at: now)
        note("rearme (\(reason)), tentativa \(planner.attemptsInEpisode); engine rodando=\(running)")
        do {
            try stopCapture()
            pinnedDevice = resolveDevice(previous: pinnedDevice)
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
        if MicRecoveryPlanner.hasSettled(now: now, configuredAt: lastConfiguredAtUptime),
           planner.evaluate(now: now, lastAudioAt: lastSignal ?? startedAtUptime) == .attempt {
            let reason: String
            if lastCallback.map({ now - $0 <= MicRecoveryPlanner.stallThreshold }) == true {
                reason = "callbacks só com zeros"
            } else {
                reason = lastSignal == nil ? "sem áudio desde o início" : "microfone parado"
            }
            rearm(reason: reason)
        }
        if planner.exhausted, !wasExhausted {
            note("sem áudio após \(planner.attemptsInEpisode) tentativas; seguem tentativas a cada \(Int(MicRecoveryPlanner.backoff.last ?? 60)) s")
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

    static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        CMTimeGetSeconds(CMTimeSubtract(
            CMClockMakeHostTimeFromSystemUnits(end),
            CMClockMakeHostTimeFromSystemUnits(start)
        ))
    }

    // MARK: - Callback do tap

    @discardableResult
    func beginTapGeneration() -> UInt64 {
        healthLock.withLock {
            tapGeneration &+= 1
            return tapGeneration
        }
    }

    func recordRecoveryAttempt() {
        healthLock.withLock {
            tapGeneration &+= 1
            recoveryAttemptCount &+= 1
            awaitingAudioAfterAttempt = true
        }
    }

    func recordRearmFailure(_ error: Error) {
        healthLock.withLock {
            if recoveryErrorDescription == nil {
                recoveryErrorDescription = error.localizedDescription
            }
        }
    }

    @discardableResult
    func recordReceivedBuffer(hostTime: UInt64?, generation: UInt64? = nil) -> Bool {
        let now = Self.uptime()
        let accepted: Bool = healthLock.withLock {
            if let generation, generation != tapGeneration { return false }
            if firstBufferHostTime == nil { firstBufferHostTime = hostTime }
            if let hostTime { lastReceivedBufferHostTime = hostTime }
            lastReceivedUptime = now
            receivedBufferCount &+= 1
            if receivedBufferCount == 1 {
                eventLog.append(at: max(0, now - startedAtUptime), "buffers chegando")
            }
            return true
        }
        return accepted
    }

    func recordProcessingFailure(_ error: Error, generation: UInt64? = nil) {
        healthLock.withLock {
            if let generation, generation != tapGeneration { return }
            if processingErrorDescription == nil {
                processingErrorDescription = error.localizedDescription
            }
        }
    }

    func appendConvertedPCM(_ data: Data, hostTime: UInt64?, generation: UInt64? = nil) {
        // A validação da geração e o write são atômicos em relação ao rearme.
        // Uma conversão iniciada no tap antigo não pode escrever/confirmar o novo.
        healthLock.withLock {
            if let generation, generation != tapGeneration { return }
            let gap = PCMGapFiller.silenceBeforeBuffer(
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                lastSuccessfulWriteByteCount: lastSuccessfulWriteByteCount,
                nextBufferHostTime: hostTime
            )
            if !gap.isEmpty {
                guard writer.appendSilence(byteCount: gap.byteCount) else { return }
                insertedSilenceByteCount &+= UInt32(clamping: gap.byteCount)
                if gap.wasCapped {
                    cappedGapCount &+= 1
                    if processingErrorDescription == nil {
                        processingErrorDescription = "Um intervalo sem callbacks excedeu \(Int(PCMGapFiller.maxSilenceSeconds)) segundos e foi limitado."
                    }
                }
                let seconds = Double(gap.byteCount) / Double(PCMGapFiller.bytesPerSecond)
                if seconds >= 0.25 {
                    eventLog.append(at: max(0, Self.uptime() - startedAtUptime),
                                    String(format: "silêncio inserido: %.1f s", seconds))
                }
            }
            guard writer.append(data) else { return }
            if pcmHasSignal(data) {
                let now = Self.uptime()
                // Interrupção = buraco entre dois buffers com sinal: cobre tanto
                // callbacks que pararam quanto callbacks só com zeros.
                if let previous = lastSignalHostTime, let hostTime {
                    let lastSignalDuration = Double(lastSignalByteCount) / Double(PCMGapFiller.bytesPerSecond)
                    // O buraco começa quando termina o último buffer com sinal.
                    let gapStart = (lastSignalUptime ?? now) - startedAtUptime + lastSignalDuration
                    dropouts.add(
                        seconds: Self.seconds(from: previous, to: hostTime) - lastSignalDuration,
                        atSeconds: gapStart
                    )
                }
                lastSignalByteCount = data.count
                let first = awaitingAudioAfterAttempt || lastSignalUptime == nil
                if lastSignalUptime == nil {
                    firstSignalHostTime = hostTime
                    initialAudioDelaySeconds = max(0, now - startedAtUptime)
                }
                lastSignalUptime = now
                lastSignalHostTime = hostTime
                awaitingAudioAfterAttempt = false
                if first {
                    eventLog.append(at: max(0, now - startedAtUptime), "áudio com sinal chegando")
                }
            }
            lastSuccessfulWriteHostTime = hostTime
            lastSuccessfulWriteByteCount = data.count
        }
    }

    func recordSuccessfulWrite(hostTime: UInt64?, byteCount: Int) {
        healthLock.withLock {
            lastSuccessfulWriteHostTime = hostTime
            lastSuccessfulWriteByteCount = byteCount
        }
    }
}
