import Foundation

enum TranscriptionError: LocalizedError {
    case pythonNotFound(String)
    case scriptNotFound(String)
    case noOutputPath(String)
    case processFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound(let path):
            return "Python não encontrado em \(path). Crie o venv (make setup) ou ajuste pythonPath via defaults."
        case .scriptNotFound(let path):
            return "Script de transcrição não encontrado em \(path). Ajuste scriptPath via defaults."
        case .noOutputPath(let out):
            return "Script não retornou caminho do arquivo.\n\(out)"
        case .processFailed(let code, let out):
            return "Transcrição falhou (exit \(code)):\n\(out)"
        }
    }
}

final class TranscriptionRunner {
    private let python = AppConfig.pythonPath
    private let script = AppConfig.scriptPath

    func run(
        micURL: URL?,
        systemURL: URL?,
        title: String,
        language: String = "pt",
        sysOffsetMs: Double = 0,
        outputDir: URL
    ) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw TranscriptionError.pythonNotFound(python)
        }
        guard FileManager.default.fileExists(atPath: script) else {
            throw TranscriptionError.scriptNotFound(script)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var args = [script, "--out", outputDir.path, "--title", title, "--language", language]
            for term in AppConfig.contextTerms {
                args += ["--context-term", term]
            }
            if abs(sysOffsetMs) > 10 {   // ignora offsets menores que 10ms (ruído de medição)
                args += ["--sys-offset", String(format: "%.1f", sysOffsetMs)]
            }
            if let mic = micURL { args += ["--mic", mic.path] }
            if let sys = systemURL { args += ["--system", sys.path] }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            proc.terminationHandler = { p in
                let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if p.terminationStatus == 0 {
                    let path = stdout.components(separatedBy: "\n")
                        .first(where: { $0.hasPrefix("Output: ") })
                        .map { String($0.dropFirst("Output: ".count)) }

                    if let path, !path.isEmpty {
                        continuation.resume(returning: URL(fileURLWithPath: path))
                    } else {
                        continuation.resume(throwing: TranscriptionError.noOutputPath(stdout))
                    }
                } else {
                    let detail = stderr.isEmpty ? stdout : stderr
                    continuation.resume(throwing: TranscriptionError.processFailed(
                        p.terminationStatus,
                        String(detail.suffix(1000))
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
