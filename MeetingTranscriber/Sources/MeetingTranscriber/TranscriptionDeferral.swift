import Foundation
import IOKit.ps

/// Por que a fila de transcrição está parada. A gravação sempre pausa; chamada
/// e bateria são adiamentos que a pessoa pode furar com "Retomar agora".
enum TranscriptionPauseReason: String, Equatable {
    case recording, call, battery

    /// Texto curto do menu, no lugar de "Em andamento" / "Na fila".
    var runningLabel: String {
        switch self {
        case .recording: return "Pausada durante a gravação"
        case .call: return "Pausada durante a chamada"
        case .battery: return "Pausada na bateria"
        }
    }

    var queuedLabel: String {
        switch self {
        case .recording: return "Na fila — começa quando a gravação terminar"
        case .call: return "Na fila — começa quando a chamada terminar"
        case .battery: return "Na fila — começa na tomada"
        }
    }

    var canOverride: Bool { self != .recording }
}

/// Política pura: o mlx-whisper só roda na tomada e fora de chamada. Gravação
/// vence tudo; "Retomar agora" só fura os adiamentos.
enum TranscriptionPausePolicy {
    static func reason(
        capturing: Bool,
        deferEnabled: Bool,
        overridden: Bool,
        callActive: Bool,
        onBattery: Bool
    ) -> TranscriptionPauseReason? {
        if capturing { return .recording }
        guard deferEnabled, !overridden else { return nil }
        if callActive { return .call }
        if onBattery { return .battery }
        return nil
    }
}

// MARK: - Energia

protocol PowerSourceReading: AnyObject {
    /// nil = não deu para ler (trata como tomada: não trava a fila por falha).
    var isOnBattery: Bool? { get }
    func startObserving(_ onChange: @escaping (Bool?) -> Void)
    func stopObserving()
}

/// Fonte de energia pelo IOKit: lê `IOPSGetProvidingPowerSourceType` e escuta a
/// notificação de troca no run loop principal. Mac sem bateria = sempre tomada.
final class IOKitPowerSource: PowerSourceReading {
    private var runLoopSource: CFRunLoopSource?
    private var onChange: ((Bool?) -> Void)?

    var isOnBattery: Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return (type as String) == kIOPMBatteryPowerKey
    }

    func startObserving(_ onChange: @escaping (Bool?) -> Void) {
        stopObserving()
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            monitor.onChange?(monitor.isOnBattery)
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stopObserving() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        runLoopSource = nil
        onChange = nil
    }

    deinit { stopObserving() }
}

// MARK: - Chamada

/// Diz se há chamada do Teams, para adiar o ASR. Mesmo sinal da assistência
/// (metadados de processo do Core Audio, sem PCM), mas independente do toggle
/// dela: só lê enquanto há transcrição na fila ou rodando.
@MainActor
final class CallActivityMonitor {
    private let provider: AudioProcessActivityProviding
    private let matcher: CallAppMatcher
    private let uptime: () -> TimeInterval
    private let pollInterval: TimeInterval
    private var detector = CallEpisodeDetector()
    private var pollTask: Task<Void, Never>?
    var onChange: (Bool) -> Void = { _ in }
    private(set) var callActive = false

    init(
        provider: AudioProcessActivityProviding = CoreAudioProcessActivityProvider(),
        matcher: CallAppMatcher = .configured(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pollInterval: TimeInterval = 2
    ) {
        self.provider = provider
        self.matcher = matcher
        self.uptime = uptime
        self.pollInterval = pollInterval
    }

    var isObserving: Bool { pollTask != nil }

    func setObserving(_ observe: Bool) {
        guard observe != isObserving else { return }
        guard observe, CallAssistant.platformSupported else {
            pollTask?.cancel()
            pollTask = nil
            detector.reset()
            update(false)
            return
        }
        let provider = provider
        let matcher = matcher
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Task.detached(priority: .utility) { provider.snapshot() }.value
                guard !Task.isCancelled, let self else { return }
                self.ingest(active: matcher.callActive(in: snapshot), at: self.uptime())
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Uma leitura. Leitura desconhecida não muda o estado (o detector cuida).
    func ingest(active: Bool?, at time: TimeInterval) {
        _ = detector.ingest(active: active, at: time, wall: Date())
        update(detector.activeEpisode != nil)
    }

    private func update(_ active: Bool) {
        guard active != callActive else { return }
        callActive = active
        onChange(active)
    }
}
