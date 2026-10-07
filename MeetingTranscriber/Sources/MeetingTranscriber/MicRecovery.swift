import Foundation

/// Estado da trilha do microfone como o usuário precisa ver: só é `ok` depois
/// que o áudio chegou de fato, não quando o engine diz que iniciou.
enum MicCaptureState: Equatable, Sendable {
    case waitingForAudio
    case ok
    case recovering(attempts: Int)
    case failed(attempts: Int)

    var needsAttention: Bool {
        switch self {
        case .recovering, .failed: return true
        case .waitingForAudio, .ok: return false
        }
    }
}

/// Decide quando rearmar o microfone. Puro (relógio injetado) para ser testado
/// sem hardware. Um episódio começa no primeiro rearme e termina quando chega
/// áudio depois da última tentativa. Rearme "sem erro" não conta como sucesso:
/// só áudio novo encerra o episódio (sessão de 01/out/2026, em que o rearme
/// retornou sem erro e o tap nunca mais recebeu buffers).
///
/// v1.7: o teto não desiste mais. Depois de `maxAttemptsPerEpisode` o estado vira
/// `.failed` (alerta vermelho e botão), mas as tentativas seguem no último
/// intervalo do backoff. Na sessão de 05/out em que o teto esgotou aos 89 s, o
/// microfone ficou mudo até o clique manual aos 591 s, que funcionou de primeira.
struct MicRecoveryPlanner: Equatable {
    /// Sem sinal escrito por mais que isso, a trilha é considerada parada.
    static let stallThreshold: TimeInterval = 5
    /// Espera mínima entre uma tentativa e a próxima, para o HAL assentar a rota.
    /// O último valor é o intervalo das tentativas depois do teto.
    static let backoff: [TimeInterval] = [3, 10, 30, 60]
    static let maxAttemptsPerEpisode = 6
    /// F8a: com o engine parado, a notificação de configuração rearma sem esperar
    /// o backoff, no máximo `immediateAttemptCap` vezes por `immediateWindow`.
    static let immediateAttemptCap = 3
    static let immediateWindow: TimeInterval = 10

    private(set) var attemptsInEpisode = 0
    private(set) var lastAttemptAt: TimeInterval?
    private(set) var exhausted = false
    private var recentAttempts: [TimeInterval] = []

    enum Decision: Equatable {
        case none
        case attempt
    }

    static func isStalled(now: TimeInterval, lastAudioAt: TimeInterval) -> Bool {
        now - lastAudioAt > stallThreshold
    }

    /// Uma notificação pode estar na fila desde o próprio start/rearme. Se o
    /// engine já roda no formato instalado, pará-lo de novo só interrompe a
    /// estabilização da rota. Falta de áudio continua coberta pelo watchdog.
    static func needsConfigurationRearm(engineRunning: Bool, inputFormatChanged: Bool) -> Bool {
        !engineRunning || inputFormatChanged
    }

    static func hasSettled(now: TimeInterval, configuredAt: TimeInterval) -> Bool {
        now - configuredAt > stallThreshold
    }

    /// `lastAudioAt`: último sinal escrito; antes do primeiro, o início da captura.
    mutating func evaluate(now: TimeInterval, lastAudioAt: TimeInterval) -> Decision {
        guard Self.isStalled(now: now, lastAudioAt: lastAudioAt) else { return .none }
        guard backoffElapsed(now: now) else { return .none }
        if attemptsInEpisode >= Self.maxAttemptsPerEpisode { exhausted = true }
        return .attempt
    }

    /// Notificação de configuração com engine parado ou formato novo: rearma na
    /// hora se for a primeira tentativa do episódio; as seguintes esperam o mesmo
    /// backoff do watchdog. Até a 1.6.1 as notificações tinham um teto próprio de
    /// 8 por minuto e esgotavam o episódio em segundos.
    ///
    /// F8a: com o engine parado não há o que estabilizar, então o rearme só espera
    /// o debounce. Passado o teto de `immediateAttemptCap` em `immediateWindow`,
    /// volta a valer o backoff (protege contra o laço de 41 rearmes de 05/out).
    func allowsConfigurationAttempt(now: TimeInterval, engineRunning: Bool = true) -> Bool {
        if !engineRunning {
            let recent = recentAttempts.filter { now - $0 < Self.immediateWindow }.count
            if recent < Self.immediateAttemptCap { return true }
        }
        return backoffElapsed(now: now)
    }

    private func backoffElapsed(now: TimeInterval) -> Bool {
        guard attemptsInEpisode > 0, let lastAttemptAt else { return true }
        let wait = Self.backoff[min(attemptsInEpisode - 1, Self.backoff.count - 1)]
        return now - lastAttemptAt >= wait
    }

    mutating func noteAttempt(at now: TimeInterval) {
        attemptsInEpisode += 1
        lastAttemptAt = now
        recentAttempts = recentAttempts.filter { now - $0 < Self.immediateWindow } + [now]
    }

    /// Retorna true quando este áudio encerra um episódio de recuperação.
    mutating func noteAudio(at time: TimeInterval) -> Bool {
        guard attemptsInEpisode > 0, let lastAttemptAt, time >= lastAttemptAt else { return false }
        attemptsInEpisode = 0
        self.lastAttemptAt = nil
        recentAttempts = []
        exhausted = false
        return true
    }

    /// Pedido explícito do usuário: zera o teto para permitir nova série.
    mutating func resetForManualAttempt() {
        attemptsInEpisode = 0
        lastAttemptAt = nil
        recentAttempts = []
        exhausted = false
    }

    func state(now: TimeInterval, lastAudioAt: TimeInterval?, captureStartedAt: TimeInterval) -> MicCaptureState {
        if exhausted { return .failed(attempts: attemptsInEpisode) }
        let reference = lastAudioAt ?? captureStartedAt
        if Self.isStalled(now: now, lastAudioAt: reference) {
            return .recovering(attempts: attemptsInEpisode)
        }
        return lastAudioAt == nil ? .waitingForAudio : .ok
    }
}

/// Diário curto das transições do microfone, persistido no manifest. Sem log
/// por buffer: só início, trocas de configuração, rearmes, primeiro áudio após
/// cada tentativa e falhas.
struct MicEventLog: Equatable, Sendable {
    static let capacity = 200

    private(set) var entries: [String] = []
    private(set) var droppedCount = 0

    mutating func append(at seconds: TimeInterval, _ message: String) {
        if entries.count >= Self.capacity {
            entries.removeFirst()
            droppedCount += 1
        }
        entries.append(String(format: "+%.1fs %@", seconds, message))
    }

    var lines: [String] {
        droppedCount > 0 ? ["(\(droppedCount) eventos antigos descartados)"] + entries : entries
    }
}
