import Foundation

/// F5: prova de vida da gravação, derivada da saúde que o monitor de 1 s já lê.
/// Nada aqui roda no caminho do tap de áudio.
enum ProofLevel: Equatable {
    case green
    case amber
    case red
}

struct TrackProof: Equatable {
    var title: String
    var device: String
    var secondsWritten: TimeInterval
    var level: ProofLevel
    var detail: String
}

struct CaptureProof: Equatable {
    var elapsed: TimeInterval
    var mic: TrackProof
    var system: TrackProof

    /// "Iniciando…": nos primeiros 10 s, enquanto alguma trilha ainda não escreveu.
    var isOpening: Bool {
        elapsed < Self.openingWindowSeconds && (mic.secondsWritten == 0 || system.secondsWritten == 0)
    }

    /// Sem 1º sinal nesse tempo, o microfone passa de âmbar para vermelho.
    static let openingGraceSeconds: TimeInterval = 30
    /// F8c: até aqui, uma trilha sem 1º write é "iniciando", não pendente.
    static let openingWindowSeconds: TimeInterval = 10
    /// Depois do 1º sinal, sem sinal por isso é perda.
    static let silenceAlertSeconds: TimeInterval = 5
    static let bytesPerSecond = 32_000.0

    @MainActor static func make(
        mic: AudioCaptureHealth,
        system: AudioCaptureHealth,
        elapsed: TimeInterval,
        now: UInt64? = nil
    ) -> CaptureProof {
        CaptureProof(
            elapsed: elapsed,
            mic: micProof(mic, elapsed: elapsed),
            system: systemProof(system, elapsed: elapsed)
        )
    }

    @MainActor static func micProof(_ health: AudioCaptureHealth, elapsed: TimeInterval) -> TrackProof {
        let written = Double(health.writtenByteCount) / bytesPerSecond
        let device = health.currentDeviceLabel ?? "microfone"
        let base = TrackProof(title: "Você", device: device, secondsWritten: written, level: .green, detail: "")
        guard health.firstSignalHostTime != nil else {
            var proof = base
            let seconds = Int(elapsed)
            proof.level = elapsed >= openingGraceSeconds ? .red : .amber
            if elapsed < openingWindowSeconds {
                proof.detail = "iniciando…"
            } else {
                proof.detail = "mic pendente · \(seconds) s" + (elapsed >= openingGraceSeconds ? "" : " · tentando")
            }
            return proof
        }
        let age = AppState.hostTimeAgeSeconds(health.lastSignalHostTime)
        var proof = base
        if age >= silenceAlertSeconds {
            proof.level = .red
            proof.detail = "sem som há \(age.isFinite ? "\(Int(age)) s" : "—")"
        } else {
            proof.detail = "som há \(Int(max(0, age))) s"
        }
        if health.captureState.needsAttention { proof.level = .red }
        return proof
    }

    /// O sistema nunca fica vermelho por silêncio (reunião presencial é legítima):
    /// só por stream que morreu. Âmbar quando os callbacks pararam.
    @MainActor static func systemProof(_ health: AudioCaptureHealth, elapsed: TimeInterval) -> TrackProof {
        let written = Double(health.writtenByteCount) / bytesPerSecond
        var proof = TrackProof(title: "Reunião", device: "áudio do sistema", secondsWritten: written, level: .green, detail: "")
        if health.streamStopErrorDescription != nil {
            proof.level = .red
            proof.detail = "captura interrompida"
        } else if AppState.systemIsStalled(health: health, secondsSinceCaptureStart: elapsed) {
            proof.level = .amber
            proof.detail = health.receivedBufferCount == 0
                ? "sistema pendente · \(Int(elapsed)) s"
                : "sem callbacks há mais de \(Int(silenceAlertSeconds)) s"
        } else {
            proof.detail = "recebendo"
        }
        return proof
    }

    /// F8c: o alerta vermelho do mic só vale depois da janela de abertura (30 s)
    /// quando ainda não houve 1º sinal; o rearme automático segue valendo antes.
    static func alertState(_ state: MicCaptureState, hasFirstSignal: Bool, elapsed: TimeInterval) -> MicCaptureState {
        if !hasFirstSignal, elapsed < openingGraceSeconds, case .recovering = state { return .waitingForAudio }
        return state
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
