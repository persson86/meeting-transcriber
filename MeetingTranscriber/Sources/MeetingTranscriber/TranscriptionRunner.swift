import Foundation

enum TranscriptionError: LocalizedError {
    case cancelled
    case pythonNotFound(String)
    case scriptNotFound(String)
    case noOutputPath(String)
    case processFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Transcrição cancelada pelo usuário."
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

/// Acumula stdout/stderr do processo Python de forma thread-safe enquanto os
/// readabilityHandlers dos pipes disparam em filas de background.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var lineBuf = Data()
    var onProgress: ((Int) -> Void)?

    func appendOut(_ d: Data) {
        let progressUpdates: [Int] = lock.withLock {
            out.append(d)
            lineBuf.append(d)

            var updates: [Int] = []
            while let newline = lineBuf.firstIndex(of: 0x0A) {
                let line = lineBuf[..<newline]
                lineBuf.removeSubrange(...newline)
                guard let text = String(data: line, encoding: .utf8),
                      text.hasPrefix("PROGRESS: "),
                      let value = Int(text.dropFirst("PROGRESS: ".count)) else { continue }
                updates.append(value)
            }
            return updates
        }
        for value in progressUpdates {
            onProgress?(value)
        }
    }
    func appendErr(_ d: Data) { lock.withLock { err.append(d) } }

    func strings() -> (String, String) {
        lock.withLock {
            (String(data: out, encoding: .utf8) ?? "", String(data: err, encoding: .utf8) ?? "")
        }
    }
}

final class TranscriptionRunner {
    private let python = AppConfig.pythonPath
    private let script = AppConfig.scriptPath
    private let lock = NSLock()
    private var proc: Process?
    private var processStarted = false
    private var cancelled = false

    func cancel() {
        let processToTerminate: Process? = lock.withLock {
            cancelled = true
            return processStarted ? proc : nil
        }
        processToTerminate?.terminate()
    }

    func run(
        micURL: URL?,
        systemURL: URL?,
        title: String,
        language: String = "pt",
        sysOffsetMs: Double = 0,
        outputDir: URL,
        onProgress: @escaping (Int) -> Void = { _ in }
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
            args += ["--mlx-model", AppConfig.mlxModel]
            if let backend = AppConfig.transcriptionBackend { args += ["--backend", backend] }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Drena os pipes em streaming em vez de só no fim: se o Python emitir mais
            // que o buffer do pipe (~64 KB) antes de sair, ler tudo no término trava.
            let drain = PipeDrain()
            drain.onProgress = onProgress
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil; return }
                drain.appendOut(d)
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil; return }
                drain.appendErr(d)
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                drain.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                drain.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                let (stdout, stderr) = drain.strings()
                let wasCancelled = self.lock.withLock {
                    self.proc = nil
                    self.processStarted = false
                    return self.cancelled
                }

                if wasCancelled {
                    continuation.resume(throwing: TranscriptionError.cancelled)
                } else if p.terminationStatus == 0 {
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

            let cancelledBeforeStart = lock.withLock {
                guard !cancelled else { return true }
                self.proc = proc
                return false
            }
            guard !cancelledBeforeStart else {
                continuation.resume(throwing: TranscriptionError.cancelled)
                return
            }

            do {
                try proc.run()
                let shouldTerminate = lock.withLock {
                    processStarted = true
                    return cancelled
                }
                if shouldTerminate {
                    proc.terminate()
                }
                if AppConfig.debugMemoryLogging {
                    NSLog("[mem] python pid=%d maxConcurrent=%d model=%@",
                          proc.processIdentifier, AppConfig.maxConcurrentTranscriptions, AppConfig.mlxModel)
                }
            } catch {
                lock.withLock {
                    self.proc = nil
                    self.processStarted = false
                }
                continuation.resume(throwing: error)
            }
        }
    }
}
