import Foundation

/// Regra de integridade v2 (app 1.8): o rótulo e as quantidades refletem a perda
/// medida em cada trilha — início, buracos e fim —, com a posição de cada uma.
/// Não há tolerância proporcional: 2 s num ponto ou 10 s somados já contam.

struct LossInterval: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case start, gap, end }
    var kind: Kind
    /// Segundos desde o clique em Gravar.
    var atS: Double
    var durS: Double
}

struct TrackIntegrity: Codable, Equatable, Sendable {
    /// Atraso medido até o primeiro sinal (mic) ou buffer (sistema), sem limiar.
    var startDelayS: Double
    var trailingS: Double
    var gapsS: Double
    /// Início + buracos + fim, só com o que passa dos limiares de ruído.
    var lossS: Double
    var intervals: [LossInterval]
}

struct IntegrityReport: Codable, Equatable, Sendable {
    var ruleVersion: Int
    var tracks: [String: TrackIntegrity]
    var sessionDurationS: Double
}

enum IntegrityRule {
    static let version = 2
    /// Um intervalo (início, buraco ou fim) a partir disso vira problema.
    static let materialEventSeconds: TimeInterval = 2
    /// Perda somada a partir disso também vira.
    static let materialLossSeconds: TimeInterval = 10
    /// Abaixo disso o início é a abertura normal do engine e o fim é o stop.
    static let minimumEdgeSeconds: TimeInterval = 1

    static func measure(_ health: AudioCaptureHealth, sessionDuration: TimeInterval) -> TrackIntegrity {
        var startDelay = max(0, health.initialAudioDelaySeconds ?? 0)
        var trailing = max(0, health.trailingSilenceSeconds ?? 0)
        // Nunca houve sinal: a sessão inteira é "início", não "fim em 00:00".
        if health.firstSignalHostTime == nil, health.initialAudioDelaySeconds == nil,
           health.writtenByteCount > 0, sessionDuration > 0 {
            startDelay = sessionDuration
            trailing = 0
        }
        let start = startDelay >= minimumEdgeSeconds ? startDelay : 0
        let end = trailing >= minimumEdgeSeconds ? trailing : 0
        var intervals = health.dropouts.intervals
        if start > 0 { intervals.append(LossInterval(kind: .start, atS: 0, durS: start)) }
        if end > 0 {
            intervals.append(LossInterval(kind: .end, atS: max(0, sessionDuration - end), durS: end))
        }
        intervals.sort { $0.atS < $1.atS }
        if intervals.count > AudioLossTally.maxIntervals {
            intervals = Array(intervals.sorted { $0.durS > $1.durS }
                .prefix(AudioLossTally.maxIntervals))
                .sorted { $0.atS < $1.atS }
        }
        return TrackIntegrity(
            startDelayS: startDelay,
            trailingS: trailing,
            gapsS: health.dropouts.totalSeconds,
            lossS: start + health.dropouts.totalSeconds + end,
            intervals: intervals
        )
    }

    /// Maior evento único da trilha, já sem o ruído de abertura e de stop.
    static func largestEvent(_ track: TrackIntegrity, largestGap: TimeInterval) -> TimeInterval {
        max(
            track.startDelayS >= minimumEdgeSeconds ? track.startDelayS : 0,
            track.trailingS >= minimumEdgeSeconds ? track.trailingS : 0,
            largestGap
        )
    }

    static func isMaterial(_ track: TrackIntegrity, largestGap: TimeInterval) -> Bool {
        largestEvent(track, largestGap: largestGap) >= materialEventSeconds
            || track.lossS >= materialLossSeconds
    }

    /// "Microfone sem áudio por 10 s no total: 7 s no início (00:00–00:07); 3 s no meio (12:03–12:06)."
    static func message(label: String, track: TrackIntegrity, health: AudioCaptureHealth) -> String {
        var parts: [String] = []
        let listed = track.intervals.prefix(4)
        for interval in listed {
            let place: String
            switch interval.kind {
            case .start: place = "no início"
            case .gap: place = "no meio"
            case .end: place = "no fim"
            }
            parts.append("\(seconds(interval.durS)) \(place) (\(clock(interval.atS))–\(clock(interval.atS + interval.durS)))")
        }
        if track.intervals.count > listed.count {
            parts.append("+\(track.intervals.count - listed.count) trecho(s)")
        }
        if health.dropouts.count > health.dropouts.intervals.count {
            // Interrupções sem posição (medidas sem relógio): só o agregado.
            parts.append("\(health.dropouts.count) interrupção(ões) no meio, maior \(seconds(health.dropouts.largestSeconds))")
        }
        let total = seconds(track.lossS)
        let detail = parts.isEmpty ? "" : ": \(parts.joined(separator: "; "))"
        return "\(label) por \(total) no total\(detail)."
    }

    static let micLabel = "Microfone sem áudio"
    static let systemLabel = "Áudio do sistema sem captura"

    /// Mensagens geradas por esta regra (perda medida), em oposição a falhas de escrita.
    static func isLossMessage(_ text: String) -> Bool {
        text.hasPrefix(micLabel) || text.hasPrefix(systemLabel)
            || text.hasPrefix(durationMessagePrefixBoth) || text.hasPrefix(durationMessagePrefixOne)
    }

    /// Mensagens da comparação de durações (também são perda medida, em segundos).
    static let durationMessagePrefixBoth = "As duas trilhas terminaram antes do fim da sessão"
    static let durationMessagePrefixOne = "A trilha do "


    static func seconds(_ value: TimeInterval) -> String {
        let rounded = Int(value.rounded())
        return rounded >= 60
            ? String(format: "%d min %02d s", rounded / 60, rounded % 60)
            : "\(rounded) s"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
