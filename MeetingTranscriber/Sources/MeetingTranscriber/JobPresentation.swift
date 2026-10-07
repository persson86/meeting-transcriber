import Foundation

/// F3: como o resultado de um job aparece na lista e na notificação. Perder 7 s
/// e perder 8 min não podem ter a mesma cara; falha de transcrição também não.
enum JobResultLevel: Equatable {
    case complete
    /// `degraded`, mas só com perda pequena e medida: segue como concluída, com ressalva.
    case minorLoss
    case partial
    case failed
}

struct JobResult: Equatable {
    var level: JobResultLevel
    /// Texto da linha de status na lista.
    var listText: String
    var notificationTitle: String
    /// Ressalva na notificação final; nil quando não há.
    var notificationCaveat: String?

    var symbol: String {
        switch level {
        case .complete: return "checkmark.circle.fill"
        case .minorLoss: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    /// Só `partial` e `failed` pedem o selo no ícone da barra de menu.
    var needsAttention: Bool { level == .partial || level == .failed }
}

enum JobPresentation {
    /// Perda pequena: abaixo destes dois limites juntos.
    static let minorLossSeconds: TimeInterval = 30
    static let minorLossFraction = 0.02

    static func result(for job: TranscriptionJob) -> JobResult {
        switch job.status {
        case .succeeded:
            return succeededResult(job)
        case .failed(let message):
            return JobResult(
                level: .failed,
                listText: "Falhou · \(message)",
                notificationTitle: "Transcrição falhou",
                notificationCaveat: message
            )
        case .queued, .running, .cancelling:
            return JobResult(level: .complete, listText: "", notificationTitle: "", notificationCaveat: nil)
        }
    }

    private static func succeededResult(_ job: TranscriptionJob) -> JobResult {
        let integrity = job.captureIntegrity
        guard integrity.status == .degraded else {
            return JobResult(level: .complete, listText: "Concluída", notificationTitle: "Transcrição concluída", notificationCaveat: nil)
        }
        guard let report = integrity.measured, !report.tracks.isEmpty else {
            return JobResult(
                level: .partial,
                listText: "Captura parcial · ver detalhes",
                notificationTitle: "Transcrição concluída com captura parcial",
                notificationCaveat: "Atenção: captura parcial"
            )
        }
        let duration = max(report.sessionDurationS, 1)
        let worst = report.tracks.max { $0.value.lossS < $1.value.lossS }!
        let total = report.tracks.values.reduce(0) { $0 + $1.lossS }
        let onlyMeasuredLoss = integrity.details.allSatisfy(IntegrityRule.isLossMessage)
        let name = trackName(worst.key)
        if onlyMeasuredLoss, total < minorLossSeconds, total < duration * minorLossFraction {
            let place = worst.value.intervals.max { $0.durS < $1.durS }.map { " \(placeText($0))" } ?? ""
            let phrase = "\(name) \(short(worst.value.lossS))\(place)"
            return JobResult(
                level: .minorLoss,
                listText: "Concluída · \(name) sem áudio \(short(worst.value.lossS))\(place)",
                notificationTitle: "Transcrição concluída",
                notificationCaveat: "Concluída com perda pequena: \(phrase)"
            )
        }
        let percent = Int((worst.value.lossS / duration * 100).rounded())
        let amount = "\(name) \(short(worst.value.lossS)) de \(short(duration)) (\(percent)%)"
        return JobResult(
            level: .partial,
            listText: "Captura parcial · \(amount)",
            notificationTitle: "Transcrição concluída com captura parcial",
            notificationCaveat: "Atenção: captura parcial, \(amount)"
        )
    }

    private static func trackName(_ key: String) -> String { key == "mic" ? "mic" : "sistema" }

    private static func placeText(_ interval: LossInterval) -> String {
        switch interval.kind {
        case .start: return "no início"
        case .end: return "no fim"
        case .gap: return "em \(IntegrityRule.clock(interval.atS))"
        }
    }

    /// "6 s", "8 min": a lista é curta, a precisão fica no manifest.
    static func short(_ value: TimeInterval) -> String {
        value < 60 ? "\(Int(value.rounded())) s" : "\(Int((value / 60).rounded())) min"
    }
}
