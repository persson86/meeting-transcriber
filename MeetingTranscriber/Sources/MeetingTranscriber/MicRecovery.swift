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
struct MicRecoveryPlanner: Equatable {
    /// Sem callback por mais que isso, a trilha é considerada parada.
    static let stallThreshold: TimeInterval = 5
    /// Espera mínima entre uma tentativa e a próxima, para o HAL assentar a rota.
    static let backoff: [TimeInterval] = [3, 10, 30, 60]
    static let maxAttemptsPerEpisode = 6

    private(set) var attemptsInEpisode = 0
    private(set) var lastAttemptAt: TimeInterval?
    private(set) var exhausted = false

    enum Decision: Equatable {
        case none
        case attempt
    }

    static func isStalled(now: TimeInterval, lastAudioAt: TimeInterval) -> Bool {
        now - lastAudioAt > stallThreshold
    }

    /// `lastAudioAt`: último callback do tap; antes do primeiro, o início da captura.
    mutating func evaluate(now: TimeInterval, lastAudioAt: TimeInterval) -> Decision {
        guard Self.isStalled(now: now, lastAudioAt: lastAudioAt), !exhausted else { return .none }
        guard attemptsInEpisode > 0, let lastAttemptAt else { return .attempt }
        let wait = Self.backoff[min(attemptsInEpisode - 1, Self.backoff.count - 1)]
        guard now - lastAttemptAt >= wait else { return .none }
        guard attemptsInEpisode < Self.maxAttemptsPerEpisode else {
            exhausted = true
            return .none
        }
        return .attempt
    }

    mutating func noteAttempt(at now: TimeInterval) {
        attemptsInEpisode += 1
        lastAttemptAt = now
    }

    /// Retorna true quando este áudio encerra um episódio de recuperação.
    mutating func noteAudio(at time: TimeInterval) -> Bool {
        guard attemptsInEpisode > 0, let lastAttemptAt, time >= lastAttemptAt else { return false }
        attemptsInEpisode = 0
        self.lastAttemptAt = nil
        exhausted = false
        return true
    }

    /// Pedido explícito do usuário: zera o teto para permitir nova série.
    mutating func resetForManualAttempt() {
        attemptsInEpisode = 0
        lastAttemptAt = nil
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
