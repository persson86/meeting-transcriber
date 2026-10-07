import Foundation
import OSLog

/// Medição por sessão (manifest schemaVersion 2): quem gravou, com qual versão,
/// em que aparelho e como o ASR correu. É o que permite responder "a confiança
/// voltou?" com números (`report.py`). Tudo opcional: manifests v1 seguem válidos.
struct ASRAttempt: Codable, Equatable {
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    /// Tempo que o Python ficou suspenso (SIGSTOP) por causa de uma gravação.
    var pausedSeconds: Double
    var overlappedRecording: Bool
}

struct SessionRecord: Codable, Equatable {
    var appVersion: String?
    var appBuild: String?
    var pipelineVersion: String?
    var pipelineGitSha: String?
    var pipelineDirty: Bool?
    var recordingStartedAt: Date?
    var recordingStoppedAt: Date?
    /// "user", "quit" ou "error".
    var stopReason: String?
    /// Dispositivo de entrada efetivo lido no stop (ex.: "MacBook Air Microphone").
    var inputDevice: String?
    var asrAttempts: [ASRAttempt] = []

    static func starting(at date: Date) -> SessionRecord {
        SessionRecord(
            appVersion: AppVersion.app,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            recordingStartedAt: date
        )
    }
}

/// Faixa de pipeline que este app sabe operar e a checagem do checkout vivo.
enum PipelineGuard {
    static let minimumSupported = [0, 10, 0]
    static let firstUnsupported = [0, 11, 0]

    /// Mensagem de bloqueio, ou nil se a versão é suportada. Versão ilegível
    /// bloqueia: o app não adivinha o contrato de argumentos.
    static func blockingMessage(forVersion version: String?) -> String? {
        guard let version, let parts = parse(version) else {
            return "Não foi possível ler a versão do pipeline. O áudio foi preservado; reinstale o app e tente novamente."
        }
        if compare(parts, minimumSupported) >= 0, compare(parts, firstUnsupported) < 0 { return nil }
        return "Pipeline fora da faixa suportada (\(version); este app aceita " +
            "\(minimumSupported.map(String.init).joined(separator: "."))–<\(firstUnsupported.map(String.init).joined(separator: "."))). " +
            "O áudio foi preservado; atualize o app ou o pipeline e tente novamente."
    }

    static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        var numbers = parts.compactMap { $0 }
        while numbers.count < 3 { numbers.append(0) }
        return Array(numbers.prefix(3))
    }

    static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b ? -1 : 1 }
        return 0
    }

    /// `git status --porcelain` somente leitura sobre os arquivos do pipeline.
    /// nil quando o checkout não é git ou o git falha.
    static func gitState(scriptPath: String) -> (sha: String?, dirty: Bool?) {
        let directory = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().path
        let sha = run(["--no-optional-locks", "-C", directory, "rev-parse", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = run(["--no-optional-locks", "-C", directory, "status", "--porcelain", "--", "transcribe_meeting.py", "review_turns.py", "transcript_signals.py"])
        return (sha?.isEmpty == false ? sha : nil, status.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Categorias de log persistente (`log show --predicate 'subsystem == ...'`).
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.meetingtranscriber.app"
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let recovery = Logger(subsystem: subsystem, category: "recovery")
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let runner = Logger(subsystem: subsystem, category: "runner")
}
