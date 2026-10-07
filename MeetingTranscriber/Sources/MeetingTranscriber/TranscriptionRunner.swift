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
    private var pausedSince: Date?
    private var pausedAccumulated: TimeInterval = 0
    /// Pausado enquanto há gravação (v1.7): o mlx-whisper disputava CPU, GPU e
    /// memória com a reunião seguinte e deixava o Mac lento.
    private var paused = false

    init(python: String = AppConfig.pythonPath, script: String = AppConfig.scriptPath) {
        self.python = python
        self.script = script
    }

    func cancel() {
        let (processToTerminate, wasPaused): (Process?, Bool) = lock.withLock {
            cancelled = true
            defer { paused = false }
            return (processStarted ? proc : nil, paused)
        }
        // Processo suspenso não trata SIGTERM até voltar a rodar.
        if wasPaused { processToTerminate?.resume() }
        processToTerminate?.terminate()
    }

    /// Suspende (SIGSTOP) ou retoma o Python sem perder o progresso. Pode ser
    /// chamado antes de o processo existir: ele já nasce suspenso.
    func setPaused(_ value: Bool) {
        let process: Process? = lock.withLock {
            guard paused != value, !cancelled else { return nil }
            paused = value
            if value { pausedSince = Date() }
            else if let since = pausedSince {
                pausedAccumulated += Date().timeIntervalSince(since)
                pausedSince = nil
            }
            return processStarted ? proc : nil
        }
        guard let process else { return }
        _ = value ? process.suspend() : process.resume()
    }

    var isPaused: Bool { lock.withLock { paused } }

    /// Tempo total suspenso (SIGSTOP), incluindo uma pausa ainda em curso.
    var pausedSecondsTotal: TimeInterval {
        lock.withLock { pausedAccumulated + (pausedSince.map { Date().timeIntervalSince($0) } ?? 0) }
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
        logURL: URL? = nil,
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
            args += Self.captureLossArguments(captureIntegrity)
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
            // Prioridade de background: núcleos de eficiência e I/O com baixa
            // prioridade, para a transcrição não competir com o uso do Mac.
            proc.qualityOfService = .background

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
                if let logURL { Self.writeLog(stderr, to: logURL) }
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
                let (shouldTerminate, shouldSuspend) = lock.withLock {
                    processStarted = true
                    return (cancelled, paused)
                }
                if shouldTerminate {
                    proc.terminate()
                } else if shouldSuspend {
                    proc.suspend()
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

    /// `--capture-loss <trilha>:<tipo>:<início>:<duração>` por intervalo medido.
    static func captureLossArguments(_ integrity: CaptureIntegrity) -> [String] {
        guard let measured = integrity.measured else { return [] }
        var args: [String] = []
        for track in measured.tracks.keys.sorted() {
            for interval in measured.tracks[track]?.intervals ?? [] {
                args += ["--capture-loss", String(
                    format: "%@:%@:%.1f:%.1f", track, interval.kind.rawValue, interval.atS, interval.durS
                )]
            }
        }
        return args
    }

    /// stderr completo do Python (até 1 MB, o fim é o que importa) ao lado da sessão.
    static func writeLog(_ stderr: String, to url: URL, limit: Int = 1_048_576) {
        guard !stderr.isEmpty else { return }
        let data = Data(stderr.utf8)
        let tail = data.count > limit ? data.suffix(limit) : data
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(tail).write(to: url, options: .atomic)
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
        // Companion de revisão: trilha por turno, sinais de qualidade e decisão
        // de cada bloco (vocabulário, retry). Não muda o texto nem o .md/.jsonl.
        args.append("--with-analysis")
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
