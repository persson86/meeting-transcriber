import CoreAudio
import Darwin
import Foundation

/// Assistência Teams (2.0): metadados de áudio por processo, sem PCM. O Core
/// Audio diz quais processos estão com entrada ou saída ativa; isso é sinal de
/// uso do microfone, não prova de reunião. Nada aqui grava, para ou abre áudio.
struct AudioProcessActivity: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String
    let executablePath: String
    /// nil = a leitura falhou (processo saindo, HAL ocupado): desconhecido.
    let isRunningInput: Bool?
    let isRunningOutput: Bool?
}

protocol AudioProcessActivityProviding: Sendable {
    /// nil quando o Core Audio não respondeu (leitura parcial, macOS sem a API):
    /// desconhecido não é "sem chamada".
    func snapshot() -> [AudioProcessActivity]?
}

/// Lê `kAudioHardwarePropertyProcessObjectList` (macOS 14+). Somente leitura de
/// propriedades: não cria IOProc, tap nem dispositivo.
struct CoreAudioProcessActivityProvider: AudioProcessActivityProviding {
    func snapshot() -> [AudioProcessActivity]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }

        return ids.compactMap { id in
            guard let pid = Self.pid(id) else { return nil }
            return AudioProcessActivity(
                pid: pid,
                bundleID: Self.bundleID(id) ?? "",
                executablePath: Self.executablePath(pid) ?? "",
                isRunningInput: Self.flag(id, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: Self.flag(id, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func pid(_ id: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Quais processos contam como "Teams". O novo Teams é `com.microsoft.teams2` e
/// seus helpers; a mídia pode rodar num helper sem bundle ID próprio, por isso o
/// caminho do executável também vale. O próprio app (inclusive o processo que
/// grava) nunca conta.
struct CallAppMatcher: Equatable {
    var bundleIDPrefixes: [String] = ["com.microsoft.teams"]
    var pathFragments: [String] = ["/Microsoft Teams.app/", "/Microsoft Teams classic.app/"]
    var excludedPID: pid_t = getpid()

    /// Diagnóstico local: `defaults write io.github.meetingtranscriber.app
    /// assistanceExtraBundleIDs -array <id>` acrescenta um app observado.
    static func configured(defaults: UserDefaults = .standard) -> CallAppMatcher {
        var matcher = CallAppMatcher()
        let extra = (defaults.array(forKey: "assistanceExtraBundleIDs") as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        matcher.bundleIDPrefixes += extra
        return matcher
    }

    func matches(_ process: AudioProcessActivity) -> Bool {
        guard process.pid != excludedPID else { return false }
        if bundleIDPrefixes.contains(where: { !process.bundleID.isEmpty && process.bundleID.hasPrefix($0) }) { return true }
        return pathFragments.contains(where: { !process.executablePath.isEmpty && process.executablePath.contains($0) })
    }

    /// Chamada provável = algum processo do Teams com entrada (microfone) ativa.
    /// Saída sozinha é toque, aviso sonoro ou vídeo: não conta. nil = desconhecido:
    /// leitura falhou, ou um processo do Teams não respondeu e nenhum outro
    /// confirma entrada ativa (falha de leitura não vira "chamada acabou").
    func callActive(in snapshot: [AudioProcessActivity]?) -> Bool? {
        guard let snapshot else { return nil }
        let teams = snapshot.filter(matches)
        if teams.contains(where: { $0.isRunningInput == true }) { return true }
        if teams.contains(where: { $0.isRunningInput == nil }) { return nil }
        return false
    }
}

/// Máquina de estados pura do episódio de chamada. Recebe "microfone do Teams
/// ativo?" a cada leitura e emite início/fim estáveis. Mute, silêncio e troca de
/// fone não encerram: o Teams mantém o microfone aberto mudo, e lacunas curtas
/// (troca de dispositivo, rearme) ficam dentro da tolerância de fim.
struct CallEpisodeDetector {
    struct Parameters: Equatable {
        /// Entrada ativa por esse tempo vira episódio (prévia de câmera conta: a
        /// pergunta aparece antes de entrar, o que é útil, e não grava nada).
        var startStability: TimeInterval = 2
        /// Entrada inativa por esse tempo encerra o episódio.
        var endStability: TimeInterval = 12
    }

    enum Event: Equatable {
        /// `observedStart` é falso quando a atividade já existia na primeira
        /// leitura (app reaberto no meio da chamada): o horário real de entrada
        /// é desconhecido e não serve para casar com o Calendar.
        case started(episode: UUID, at: Date, observedStart: Bool)
        case ended(episode: UUID, at: Date)
    }

    enum Phase: Equatable {
        case quiet
        case rising(since: TimeInterval, wall: Date, observed: Bool)
        case active(episode: UUID)
        case falling(episode: UUID, since: TimeInterval, wall: Date)
    }

    private(set) var phase: Phase = .quiet
    private var hasObserved = false
    /// Houve leitura desconhecida durante a queda: o silêncio só conta a partir
    /// da próxima leitura conhecida.
    private var unknownWhileFalling = false
    let parameters: Parameters

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    var activeEpisode: UUID? {
        switch phase {
        case .active(let episode), .falling(let episode, _, _): return episode
        case .quiet, .rising: return nil
        }
    }

    /// `active == nil` (leitura falhou) não é prova de início nem de fim: um
    /// início em formação recomeça, e a contagem de uma queda reinicia na
    /// próxima leitura conhecida.
    mutating func ingest(active: Bool?, at time: TimeInterval, wall: Date) -> Event? {
        guard let active else {
            switch phase {
            case .rising: phase = .quiet
            case .falling: unknownWhileFalling = true
            case .quiet, .active: break
            }
            return nil
        }
        let firstObservation = !hasObserved
        hasObserved = true
        switch phase {
        case .quiet:
            guard active else { return nil }
            phase = .rising(since: time, wall: wall, observed: !firstObservation)
            return promoteIfStable(at: time)
        case .rising:
            guard active else { phase = .quiet; return nil }
            return promoteIfStable(at: time)
        case .active(let episode):
            if !active { phase = .falling(episode: episode, since: time, wall: wall) }
            return nil
        case .falling(let episode, let since, let endedWall):
            if active { phase = .active(episode: episode); unknownWhileFalling = false; return nil }
            if unknownWhileFalling {
                unknownWhileFalling = false
                phase = .falling(episode: episode, since: time, wall: endedWall)
                return nil
            }
            guard time - since >= parameters.endStability else { return nil }
            phase = .quiet
            return .ended(episode: episode, at: endedWall)
        }
    }

    /// Assistência desligada ou pausada: esquece o episódio, sem emitir evento.
    mutating func reset() {
        phase = .quiet
        hasObserved = false
        unknownWhileFalling = false
    }

    private mutating func promoteIfStable(at time: TimeInterval) -> Event? {
        guard case .rising(let since, let wall, let observed) = phase,
              time - since >= parameters.startStability else { return nil }
        let episode = UUID()
        phase = .active(episode: episode)
        return .started(episode: episode, at: wall, observedStart: observed)
    }
}
