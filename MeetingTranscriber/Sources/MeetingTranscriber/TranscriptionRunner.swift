import Foundation

enum TranscriptionError: LocalizedError {
    case cancelled
    case pythonNotFound(String)
    case scriptNotFound(String)
    case noOutputPath(String)
    case invalidOutput(String)
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
        case .invalidOutput(let detail):
            return "A transcrição terminou sem produzir artefatos válidos: \(detail)"
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
    private let python: String
    private let script: String
    private let lock = NSLock()
    private var proc: Process?
    private var processStarted = false
    private var cancelled = false

    init(python: String = AppConfig.pythonPath, script: String = AppConfig.scriptPath) {
        self.python = python
        self.script = script
    }

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
        sessionID: UUID? = nil,
        captureIntegrity: CaptureIntegrity = .unknown,
        recordedAt: Date? = nil,
        calendarMeeting: CalendarMeeting? = nil,
        onProgress: @escaping (Int) -> Void = { _ in }
    ) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw TranscriptionError.pythonNotFound(python)
        }
        guard FileManager.default.fileExists(atPath: script) else {
            throw TranscriptionError.scriptNotFound(script)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var args = Self.arguments(
                script: script,
                title: title,
                language: language,
                outputDir: outputDir,
                sessionID: sessionID,
                recordedAt: recordedAt,
                calendarMeeting: calendarMeeting,
                vocabularyURL: AppConfig.vocabularyURL
            )
            args += ["--capture-integrity", captureIntegrity.status.rawValue]
            for issue in captureIntegrity.details { args += ["--capture-issue", issue] }
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
                        do {
                            let outputURL = try Self.validateOutput(
                                declaredPath: path,
                                outputDirectory: outputDir,
                                sessionID: sessionID
                            )
                            continuation.resume(returning: outputURL)
                        } catch {
                            continuation.resume(throwing: error)
                        }
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

    /// Argumentos da CLI comuns a todo job. Datas saem com o fuso local
    /// (ex.: -03:00) para a transcrição mostrar o horário da reunião.
    static func arguments(
        script: String,
        title: String,
        language: String,
        outputDir: URL,
        sessionID: UUID?,
        recordedAt: Date?,
        calendarMeeting: CalendarMeeting?,
        vocabularyURL: URL?,
        fileManager: FileManager = .default
    ) -> [String] {
        var args = [script, "--out", outputDir.path, "--title", title, "--language", language]
        if let sessionID { args += ["--session-id", sessionID.uuidString] }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = .current
        if let recordedAt { args += ["--recorded-at", isoFormatter.string(from: recordedAt)] }
        if let vocabularyURL, fileManager.fileExists(atPath: vocabularyURL.path) {
            args += ["--vocabulary", vocabularyURL.path]
        }
        if let calendarMeeting {
            args += ["--calendar-title", calendarMeeting.title]
            args += ["--calendar-start", isoFormatter.string(from: calendarMeeting.startDate)]
            if let end = calendarMeeting.endDate {
                args += ["--calendar-end", isoFormatter.string(from: end)]
            }
            if let organizer = calendarMeeting.organizerName, !organizer.isEmpty {
                args += ["--calendar-organizer", organizer]
            }
            for name in calendarMeeting.attendeeNames ?? [] {
                args += ["--participant", name]
            }
        }
        return args
    }

    private static func validateOutput(
        declaredPath: String,
        outputDirectory: URL,
        sessionID: UUID?
    ) throws -> URL {
        let output = URL(fileURLWithPath: declaredPath).standardizedFileURL
        let root = outputDirectory.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard output.path.hasPrefix(rootPrefix), output.pathExtension == "md" else {
            throw TranscriptionError.invalidOutput("o caminho declarado não é um Markdown dentro da pasta configurada")
        }

        let base = output.deletingPathExtension()
        let jsonl = base.appendingPathExtension("jsonl")
        for artifact in [output, jsonl] {
            guard let values = try? artifact.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) > 0 else {
                throw TranscriptionError.invalidOutput("\(artifact.lastPathComponent) está ausente ou vazio")
            }
        }

        let jsonlText: String
        do {
            jsonlText = try String(contentsOf: jsonl, encoding: .utf8)
        } catch {
            throw TranscriptionError.invalidOutput("não foi possível ler \(jsonl.lastPathComponent)")
        }
        let rows = jsonlText.split(whereSeparator: \.isNewline)
        guard !rows.isEmpty else {
            throw TranscriptionError.invalidOutput("o JSONL não contém registros")
        }
        var parsedRows: [[String: Any]] = []
        do {
            parsedRows = try rows.map { line in
                guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw TranscriptionError.invalidOutput("o JSONL contém um registro que não é objeto")
                }
                return row
            }
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.invalidOutput("o JSONL não é parseável")
        }

        guard let firstRow = parsedRows.first,
              firstRow["type"] as? String == "meta" else {
            throw TranscriptionError.invalidOutput("o primeiro registro JSONL não contém metadados")
        }
        if let sessionID,
           firstRow["session_id"] as? String != sessionID.uuidString {
            throw TranscriptionError.invalidOutput("o JSONL não pertence à sessão solicitada")
        }
        return output
    }
}
