import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation

enum RecordingStatus {
    case idle
    case starting
    case recording
    case stopping
    case importing
    case error(String)

    var isStarting: Bool { if case .starting = self { return true }; return false }
    var isRecording: Bool { if case .recording = self { return true }; return false }
    var isStopping: Bool { if case .stopping = self { return true }; return false }
    var isImporting: Bool { if case .importing = self { return true }; return false }
    var isBusy: Bool { isStarting || isRecording || isStopping || isImporting }
    var canStartRecording: Bool {
        if case .idle = self { return true }
        if case .error = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Pronto"
        case .starting: return "Iniciando gravação…"
        case .recording: return "Gravando…"
        case .stopping: return "Salvando áudio…"
        case .importing: return "Importando áudio…"
        case .error(let msg): return msg
        }
    }
}

enum TranscriptionJobStatus: Equatable {
    case queued
    case running
    case cancelling
    case succeeded(URL)
    case failed(String)

    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    var isRunning: Bool {
        switch self {
        case .running, .cancelling: return true
        default: return false
        }
    }

    var isFinished: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .queued, .running, .cancelling: return false
        }
    }
}

struct TranscriptionJob: Identifiable, Equatable {
    let id: UUID
    let title: String
    let language: String
    let micURL: URL?
    let systemURL: URL?
    let outputDir: URL
    let sysOffsetMs: Double
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var status: TranscriptionJobStatus
    var progress: Int = 0
    var exportedToSecondBrain: Bool = false
    var captureIntegrity: CaptureIntegrity = .unknown
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: RecordingStatus = .idle
    @Published var meetingTitle: String = ""
    @Published var lastWarning: String?
    @Published var lastOutputURL: URL?
    @Published var outputDirectory: URL
    @Published var language: String  // "pt" | "en" | "auto"
    @Published var transcriptionJobs: [TranscriptionJob] = []
    @Published var isCalendarSyncing = false

    private var mic: MicRecorder?
    private var sys: SystemAudioRecorder?
    private var tempDir: URL?
    private var currentSessionID: UUID?
    private var captureStartedAt: Date?
    private var captureMonitorTask: Task<Void, Never>?
    private var captureHealthWarnings: Set<String> = []
    private let maxConcurrentTranscriptions: Int
    private var runners: [UUID: TranscriptionRunner] = [:]
    private let calendarLookup = CalendarLookup()
    private let sessionStore: SessionStore
    private let sessionLease: SessionStoreLease?
    private let storageLeaseAvailable: Bool
    private var calendarWarning: String?

    /// Quantas transcrições concluídas ficam retidas (na lista e em memória).
    /// Jobs ativos não contam para esse limite — eles são sempre visíveis.
    private static let finishedJobRetentionCount = 5

    init(sessionStore: SessionStore = SessionStore()) {
        self.sessionStore = sessionStore
        maxConcurrentTranscriptions = AppConfig.maxConcurrentTranscriptions
        outputDirectory = UserDefaults.standard.url(forKey: "outputDirectory")
            ?? AppConfig.defaultOutputDirectory
        language = UserDefaults.standard.string(forKey: "language") ?? "pt"
        meetingTitle = Self.defaultTitle()
        let lease = try? sessionStore.acquireExclusiveLease()
        sessionLease = lease
        storageLeaseAvailable = lease != nil
        guard storageLeaseAvailable else {
            status = .error("Outra instância do Meeting Transcriber já está usando as sessões. Feche-a antes de continuar.")
            return
        }
        let recovered = sessionStore.loadJobs()
        let recoveredOutputs = Set(recovered.compactMap { job -> String? in
            guard case .succeeded(let url) = job.status else { return nil }
            return url.resolvingSymlinksInPath().path
        })
        let legacy = Self.loadRecentFinishedJobs(from: outputDirectory, limit: Self.finishedJobRetentionCount)
            .filter { job in
                guard case .succeeded(let url) = job.status else { return true }
                return !recoveredOutputs.contains(url.resolvingSymlinksInPath().path)
            }
        transcriptionJobs = recovered + legacy
        for job in recovered { try? sessionStore.save(job) }
        pruneFinishedJobs()
        Task { scheduleTranscriptionJobs() }
    }

    var runningTranscriptionCount: Int {
        transcriptionJobs.filter { $0.status.isRunning }.count
    }

    var queuedTranscriptionCount: Int {
        transcriptionJobs.filter { $0.status.isQueued }.count
    }

    var activeTranscriptionCount: Int {
        runningTranscriptionCount + queuedTranscriptionCount
    }

    var hasActiveTranscription: Bool { activeTranscriptionCount > 0 }

    var storageIsAvailable: Bool { storageLeaseAvailable }

    var maxConcurrentTranscriptionCount: Int {
        maxConcurrentTranscriptions
    }

    /// Fila visível no popover: primeiro os jobs ativos, na ordem em que serão
    /// processados; depois as transcrições concluídas mais recentes. Um job em
    /// execução nunca sai da lista enquanto o contador de status ainda o conta.
    var visibleTranscriptionJobs: [TranscriptionJob] {
        Self.visibleJobs(from: transcriptionJobs, finishedLimit: Self.finishedJobRetentionCount)
    }

    static func visibleJobs(from jobs: [TranscriptionJob], finishedLimit: Int) -> [TranscriptionJob] {
        let active = jobs.filter { !$0.status.isFinished }
        let recentFinished = jobs.filter { $0.status.isFinished }
            .sorted { finishedAt($0) > finishedAt($1) }
            .prefix(finishedLimit)
        return active + recentFinished
    }

    private static func finishedAt(_ job: TranscriptionJob) -> Date {
        job.completedAt ?? job.createdAt
    }

    var statusLabel: String {
        if status.isBusy {
            return status.label
        }
        if runningTranscriptionCount > 0 {
            let queued = queuedTranscriptionCount
            return queued > 0
                ? "Transcrevendo \(runningTranscriptionCount) • \(queued) na fila"
                : "Transcrevendo \(runningTranscriptionCount)"
        }
        if queuedTranscriptionCount > 0 {
            return "\(queuedTranscriptionCount) na fila"
        }
        return status.label
    }

    func startRecording() {
        guard storageLeaseAvailable, status.canStartRecording, !isCalendarSyncing else { return }
        status = .starting
        lastWarning = nil

        // Não bloqueia gravar a próxima reunião, mas avisa: transcrição + nova
        // captura ao mesmo tempo é o pior caso de memória neste Mac.
        if hasActiveTranscription {
            lastWarning = "Transcrição em andamento — gravar agora aumenta o uso de memória (o app processa uma por vez). A gravação continua normalmente."
        }

        let title = meetingTitle.isEmpty ? Self.defaultTitle() : meetingTitle
        let outDir = outputDirectory
        let currentLanguage = language
        let sessionID = UUID()

        Task {
            var pendingDirectory: URL?
            var pendingMic: MicRecorder?
            var pendingSystem: SystemAudioRecorder?
            var recordingStartedAt: Date?
            do {
                guard await ensureMicrophoneAccess() else {
                    status = .error("Permissão de microfone necessária. Ative o Meeting Transcriber em Configurações do Sistema → Privacidade e Segurança → Microfone, depois tente novamente.")
                    return
                }

                let createdAt = Date()
                recordingStartedAt = createdAt

                let dir = try sessionStore.prepareRecording(
                    id: sessionID,
                    title: title,
                    language: currentLanguage,
                    outputDirectory: outDir,
                    createdAt: createdAt
                )
                pendingDirectory = dir

                let micRec = MicRecorder(
                    stagingDirectory: dir,
                    stagingFileName: "mic.inprogress.wav",
                    preserveOnDeinit: true
                )
                pendingMic = micRec
                try micRec.start()

                let sysRec = SystemAudioRecorder(
                    stagingDirectory: dir,
                    stagingFileName: "system.inprogress.wav",
                    preserveOnDeinit: true
                )
                pendingSystem = sysRec
                try await sysRec.start()

                mic = micRec
                sys = sysRec
                tempDir = dir
                currentSessionID = sessionID
                captureStartedAt = createdAt
                captureHealthWarnings = []
                status = .recording
                startCaptureMonitor()

            } catch {
                let msg = error.localizedDescription
                if let dir = pendingDirectory {
                    let micURL = dir.appendingPathComponent("mic.wav")
                    let systemURL = dir.appendingPathComponent("system.wav")
                    try? pendingMic?.stop(saveTo: micURL)
                    try? await pendingSystem?.stop(saveTo: systemURL)
                    let failedJob = TranscriptionJob(
                        id: sessionID,
                        title: title,
                        language: currentLanguage,
                        micURL: Self.existingAudioFileURL(micURL),
                        systemURL: Self.existingAudioFileURL(systemURL),
                        outputDir: outDir,
                        sysOffsetMs: 0,
                        createdAt: recordingStartedAt ?? Date(),
                        startedAt: recordingStartedAt,
                        completedAt: Date(),
                        status: .failed("Não foi possível iniciar a captura: \(msg)"),
                        captureIntegrity: .degraded(["A inicialização da captura foi interrompida."])
                    )
                    transcriptionJobs.append(failedJob)
                    persist(failedJob)
                }
                if msg.contains("declined") || msg.contains("not authorized") || msg.contains("userDeclined") {
                    CGRequestScreenCaptureAccess()
                    status = .error("Permissão de gravação de tela necessária. Ative o Meeting Transcriber em Configurações do Sistema → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema, depois tente novamente.")
                } else {
                    status = .error(msg)
                }
            }
        }
    }

    func stopRecording() {
        guard case .recording = status else { return }
        status = .stopping

        let micCopy = mic
        let sysCopy = sys
        let dir = tempDir
        let sessionID = currentSessionID ?? UUID()
        let startedAt = captureStartedAt ?? Date()
        captureMonitorTask?.cancel()
        captureMonitorTask = nil

        let title = meetingTitle.isEmpty ? Self.defaultTitle() : meetingTitle
        let outDir = outputDirectory
        let currentLanguage = language

        Task {
            do {
                guard let micURL = dir?.appendingPathComponent("mic.wav"),
                      let sysURL = dir?.appendingPathComponent("system.wav") else {
                    throw NSError(
                        domain: "MeetingTranscriber",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Diretório temporário da gravação indisponível"]
                    )
                }

                var captureIssues: [String] = []
                do { try micCopy?.stop(saveTo: micURL) }
                catch { captureIssues.append("Falha ao finalizar o microfone: \(error.localizedDescription)") }
                do { try await sysCopy?.stop(saveTo: sysURL) }
                catch { captureIssues.append("Falha ao finalizar o áudio do sistema: \(error.localizedDescription)") }

                captureIssues.append(contentsOf: Self.healthIssues(
                    mic: micCopy?.health,
                    system: sysCopy?.health
                ))
                captureIssues.append(contentsOf: captureHealthWarnings)
                captureIssues = Array(Set(captureIssues)).sorted()

                mic = nil; sys = nil; tempDir = nil
                currentSessionID = nil; captureStartedAt = nil
                captureHealthWarnings = []

                let recordedMicURL = Self.existingAudioFileURL(micURL)
                let recordedSystemURL = Self.existingAudioFileURL(sysURL)
                guard recordedMicURL != nil || recordedSystemURL != nil else {
                    throw NSError(
                        domain: "MeetingTranscriber",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Nenhuma trilha de áudio foi capturada"]
                    )
                }

                // Apenas uma trilha foi capturada: transcreve o que temos, mas avisa
                // em vez de gerar um transcript incompleto em silêncio.
                if recordedMicURL == nil {
                    captureIssues.append("Sua voz (microfone) não foi capturada.")
                } else if recordedSystemURL == nil {
                    captureIssues.append("O áudio do sistema (interlocutor) não foi capturado.")
                }

                if AppConfig.debugMemoryLogging {
                    let micKB = (recordedMicURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0) / 1024
                    let sysKB = (recordedSystemURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0) / 1024
                    NSLog("[mem] tracks saved mic=%dKB system=%dKB", micKB, sysKB)
                }

                // Calcula offset real entre trilhas a partir do primeiro buffer de cada uma.
                // sysOffsetMs > 0: sistema iniciou depois do mic → timestamps do sistema adiantados.
                let sysOffsetMs = Self.computeOffsetMs(
                    micTime: micCopy?.firstBufferTime,
                    sysTime: sysCopy?.firstBufferTime
                )

                captureIssues.append(contentsOf: Self.durationIntegrityIssues(
                    micURL: recordedMicURL,
                    systemURL: recordedSystemURL,
                    sessionDuration: Date().timeIntervalSince(startedAt),
                    sysOffsetMs: sysOffsetMs
                ))

                let job = TranscriptionJob(
                    id: sessionID,
                    title: title,
                    language: currentLanguage,
                    micURL: recordedMicURL,
                    systemURL: recordedSystemURL,
                    outputDir: outDir,
                    sysOffsetMs: sysOffsetMs,
                    createdAt: startedAt,
                    startedAt: nil,
                    completedAt: nil,
                    status: .queued,
                    captureIntegrity: captureIssues.isEmpty ? .complete : .degraded(captureIssues)
                )

                transcriptionJobs.append(job)
                persist(job)
                if !captureIssues.isEmpty {
                    warn("Captura parcial: \(captureIssues.joined(separator: " ")) O áudio recuperável foi preservado.")
                }
                meetingTitle = Self.defaultTitle()
                status = .idle
                scheduleTranscriptionJobs()

            } catch {
                mic = nil; sys = nil; tempDir = nil
                currentSessionID = nil; captureStartedAt = nil
                captureHealthWarnings = []
                let failedMicURL = dir.map { Self.existingAudioFileURL($0.appendingPathComponent("mic.wav")) } ?? nil
                let failedSystemURL = dir.map { Self.existingAudioFileURL($0.appendingPathComponent("system.wav")) } ?? nil
                if !transcriptionJobs.contains(where: { $0.id == sessionID }) {
                    let failedJob = TranscriptionJob(
                        id: sessionID,
                        title: title,
                        language: currentLanguage,
                        micURL: failedMicURL,
                        systemURL: failedSystemURL,
                        outputDir: outDir,
                        sysOffsetMs: 0,
                        createdAt: startedAt,
                        startedAt: startedAt,
                        completedAt: Date(),
                        status: .failed(error.localizedDescription),
                        captureIntegrity: .degraded(["Não foi possível concluir a captura."])
                    )
                    transcriptionJobs.append(failedJob)
                    persist(failedJob)
                }
                status = .error(error.localizedDescription)
            }
        }
    }

    func importAudioFile(_ sourceURL: URL) {
        guard storageLeaseAvailable, status.canStartRecording, !isCalendarSyncing else { return }
        lastWarning = nil
        status = .importing

        let title = meetingTitle.isEmpty ? Self.defaultTitle() : meetingTitle
        let outDir = outputDirectory
        let currentLanguage = language
        let sessionID = UUID()

        Task {
            do {
                let sessionDirectory = sessionStore.sessionDirectory(for: sessionID)
                let stagedURL = try await Self.stageImportedAudio(from: sourceURL, destinationDirectory: sessionDirectory)
                let job = TranscriptionJob(
                    id: sessionID,
                    title: title,
                    language: currentLanguage,
                    micURL: stagedURL,
                    systemURL: nil,
                    outputDir: outDir,
                    sysOffsetMs: 0,
                    createdAt: Date(),
                    startedAt: nil,
                    completedAt: nil,
                    status: .queued,
                    captureIntegrity: .complete
                )

                transcriptionJobs.append(job)
                persist(job)
                meetingTitle = Self.defaultTitle()
                status = .idle
                scheduleTranscriptionJobs()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func resetError() {
        guard storageLeaseAvailable else { return }
        if case .error = status { status = .idle }
    }

    func clearWarning() {
        lastWarning = nil
        calendarWarning = nil
    }

    func syncMeetingTitleFromCalendar() {
        guard status.canStartRecording, !isCalendarSyncing else { return }
        isCalendarSyncing = true

        Task {
            defer { isCalendarSyncing = false }

            do {
                guard let meeting = try await calendarLookup.nextConfirmedMeeting() else {
                    showCalendarWarning("Nenhuma reunião confirmada nas próximas 24h.")
                    return
                }

                meetingTitle = Self.calendarTitle(for: meeting)
                clearCalendarWarning()
            } catch let error as CalendarLookupError {
                showCalendarWarning(error.localizedDescription)
            } catch {
                showCalendarWarning("Não foi possível consultar o Calendar: \(error.localizedDescription)")
            }
        }
    }

    private func warn(_ message: String) {
        lastWarning = message
        NotificationManager.shared.notifyWarning(message)
    }

    private func startCaptureMonitor() {
        captureMonitorTask?.cancel()
        captureMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, case .recording = self.status else { return }
                self.checkCaptureHealth()
            }
        }
    }

    private func checkCaptureHealth() {
        guard let mic, let sys else { return }
        let micHealth = mic.health
        let systemHealth = sys.health
        var issues: [String] = []
        if let error = micHealth.firstErrorDescription {
            issues.append("Falha ao gravar o microfone: \(error)")
        }
        if let error = micHealth.recoveryErrorDescription {
            issues.append("O microfone não retomou após a troca de dispositivo: \(error)")
        }
        if let error = systemHealth.firstErrorDescription {
            issues.append("Falha ao gravar o áudio do sistema: \(error)")
        }
        if let error = systemHealth.streamStopErrorDescription {
            issues.append("A captura do áudio do sistema foi interrompida: \(error)")
        }
        if Date().timeIntervalSince(captureStartedAt ?? Date()) > 5,
           micHealth.receivedBufferCount == 0 || Self.hostTimeAgeSeconds(micHealth.lastBufferHostTime) > 5 {
            issues.append("O microfone deixou de entregar áudio há mais de cinco segundos.")
        }
        for issue in issues where captureHealthWarnings.insert(issue).inserted {
            warn("Captura parcial: \(issue) A gravação recuperável continua sendo preservada.")
        }
    }

    private func showCalendarWarning(_ message: String) {
        calendarWarning = message
        lastWarning = message
    }

    private func clearCalendarWarning() {
        if lastWarning == calendarWarning {
            lastWarning = nil
        }
        calendarWarning = nil
    }

    /// Garante acesso ao microfone antes de gravar. Sem isso, o AVAudioEngine pode
    /// iniciar e não entregar nenhum buffer, produzindo uma trilha vazia em silêncio.
    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func scheduleTranscriptionJobs() {
        while runningTranscriptionCount < maxConcurrentTranscriptions,
              let index = transcriptionJobs.firstIndex(where: { $0.status.isQueued }) {
            transcriptionJobs[index].status = .running
            transcriptionJobs[index].startedAt = Date()
            persist(transcriptionJobs[index])
            runTranscriptionJob(transcriptionJobs[index])
        }
    }

    private func runTranscriptionJob(_ job: TranscriptionJob) {
        let runner = TranscriptionRunner()
        runners[job.id] = runner
        Task { [job, runner] in
            do {
                let outputURL = try await runner.run(
                    micURL: job.micURL,
                    systemURL: job.systemURL,
                    title: job.title,
                    language: job.language,
                    sysOffsetMs: job.sysOffsetMs,
                    outputDir: job.outputDir,
                    sessionID: job.id,
                    captureIntegrity: job.captureIntegrity,
                    recordedAt: job.createdAt,
                    onProgress: { [weak self] pct in
                        Task { @MainActor in
                            self?.updateProgress(id: job.id, pct: pct)
                        }
                    }
                )

                try Self.archiveSessionFiles(
                    outputURL: outputURL,
                    micURL: job.micURL,
                    systemURL: job.systemURL,
                    title: job.title,
                    language: job.language,
                    sysOffsetMs: job.sysOffsetMs,
                    createdAt: job.createdAt,
                    captureIntegrity: job.captureIntegrity
                )

                finishTranscriptionJob(id: job.id, outputURL: outputURL)
            } catch {
                failTranscriptionJob(id: job.id, message: error.localizedDescription)
            }
        }
    }

    private func updateProgress(id: UUID, pct: Int) {
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }),
              transcriptionJobs[index].status.isRunning else { return }
        let previousProgress = transcriptionJobs[index].progress
        transcriptionJobs[index].progress = max(transcriptionJobs[index].progress, pct)
        if pct == 100 || pct / 5 > previousProgress / 5 {
            persist(transcriptionJobs[index])
        }
    }

    private func finishTranscriptionJob(id: UUID, outputURL: URL) {
        runners[id] = nil
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        transcriptionJobs[index].progress = 100
        transcriptionJobs[index].status = .succeeded(outputURL)
        transcriptionJobs[index].completedAt = Date()
        persist(transcriptionJobs[index])
        lastOutputURL = outputURL
        NotificationManager.shared.notifyDone(fileURL: outputURL)
        pruneFinishedJobs()
        scheduleTranscriptionJobs()
    }

    private func failTranscriptionJob(id: UUID, message: String) {
        runners[id] = nil
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        transcriptionJobs[index].status = .failed(message)
        transcriptionJobs[index].completedAt = Date()
        persist(transcriptionJobs[index])
        pruneFinishedJobs()
        scheduleTranscriptionJobs()
    }

    /// Limita apenas o histórico visual em memória. Áudio e manifest continuam no
    /// armazenamento recuperável até um descarte explícito futuro.
    private func pruneFinishedJobs() {
        let retainedIDs = Set(visibleTranscriptionJobs.map(\.id))
        let stale = transcriptionJobs.filter { $0.status.isFinished && !retainedIDs.contains($0.id) }
        guard !stale.isEmpty else { return }

        let staleIDs = Set(stale.map(\.id))
        transcriptionJobs.removeAll { staleIDs.contains($0.id) }
    }

    func cancelJob(_ id: UUID) {
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        if transcriptionJobs[index].status.isQueued {
            transcriptionJobs[index].status = .failed("Cancelada. O áudio foi preservado para tentar novamente.")
            transcriptionJobs[index].completedAt = Date()
            persist(transcriptionJobs[index])
            scheduleTranscriptionJobs()
            return
        }
        guard transcriptionJobs[index].status.isRunning else { return }
        transcriptionJobs[index].status = .cancelling
        persist(transcriptionJobs[index])
        runners[id]?.cancel()
    }

    func retryJob(_ id: UUID) {
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }),
              case .failed = transcriptionJobs[index].status,
              transcriptionJobs[index].micURL != nil || transcriptionJobs[index].systemURL != nil else { return }
        transcriptionJobs[index].status = .queued
        transcriptionJobs[index].startedAt = nil
        transcriptionJobs[index].completedAt = nil
        transcriptionJobs[index].progress = 0
        persist(transcriptionJobs[index])
        scheduleTranscriptionJobs()
    }

    func dismissJob(_ id: UUID) {
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }),
              transcriptionJobs[index].status.isFinished else { return }
        do { try sessionStore.hide(id: id) } catch {
            // Itens legados não têm manifest; remover da lista continua seguro.
        }
        transcriptionJobs.remove(at: index)
    }

    func sendToSecondBrain(_ job: TranscriptionJob) {
        guard case .succeeded(let outputURL) = job.status,
              let root = AppConfig.secondBrainPath,
              let index = transcriptionJobs.firstIndex(where: { $0.id == job.id }),
              !transcriptionJobs[index].exportedToSecondBrain else { return }

        let fm = FileManager.default
        let queueDir = URL(fileURLWithPath: root)
            .appendingPathComponent("queue")
            .appendingPathComponent("transcricoes")
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: queueDir.path, isDirectory: &isDir) || !isDir.boolValue {
            do {
                try fm.createDirectory(at: queueDir, withIntermediateDirectories: true)
            } catch {
                status = .error("Não foi possível criar queue/transcricoes/: \(error.localizedDescription)")
                return
            }
        }

        let ts = Int(Date().timeIntervalSince1970)
        let base = outputURL.deletingPathExtension()
        let slug = base.lastPathComponent

        do {
            var copied = 0
            for ext in ["md", "jsonl"] {
                let source = base.appendingPathExtension(ext)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = queueDir.appendingPathComponent("\(ts)-meeting-\(slug).\(ext)")
                try fm.copyItem(at: source, to: destination)
                copied += 1
            }
            guard copied > 0 else {
                status = .error("Nenhum arquivo de transcrição encontrado para enviar")
                return
            }
            transcriptionJobs[index].exportedToSecondBrain = true
            persist(transcriptionJobs[index])
        } catch {
            status = .error("Falha ao enviar para o second-brain: \(error.localizedDescription)")
        }
    }

    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
        UserDefaults.standard.set(url, forKey: "outputDirectory")
    }

    func setLanguage(_ lang: String) {
        language = lang
        UserDefaults.standard.set(lang, forKey: "language")
    }

    /// Converte dois mach_absolute_time em offset em ms (sys - mic).
    static func computeOffsetMs(micTime: UInt64?, sysTime: UInt64?) -> Double {
        guard let mic = micTime, let sys = sysTime else { return 0 }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nsPerTick = Double(info.numer) / Double(info.denom)
        let micNs = Double(mic) * nsPerTick
        let sysNs = Double(sys) * nsPerTick
        return (sysNs - micNs) / 1_000_000.0  // ns → ms
    }

    static func archiveSessionFiles(
        outputURL: URL,
        micURL: URL?,
        systemURL: URL?,
        title: String,
        language: String,
        sysOffsetMs: Double,
        createdAt: Date = Date(),
        captureIntegrity: CaptureIntegrity = .unknown
    ) throws {
        let fm = FileManager.default
        let archiveURL = try uniqueArchiveDirectory(for: outputURL)
        try fm.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        var files: [String: String] = [:]
        if let micURL {
            try fm.copyItem(at: micURL, to: archiveURL.appendingPathComponent("mic.wav"))
            files["mic"] = "mic.wav"
        }
        if let systemURL {
            try fm.copyItem(at: systemURL, to: archiveURL.appendingPathComponent("system.wav"))
            files["system"] = "system.wav"
        }

        let metadata: [String: Any] = [
            "title": title,
            "language": language,
            "sysOffsetMs": sysOffsetMs,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "output": outputURL.lastPathComponent,
            "format": outputURL.pathExtension,
            "files": files,
            "captureIntegrity": captureIntegrity.status.rawValue,
            "captureIssues": captureIntegrity.details
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: archiveURL.appendingPathComponent("metadata.json"))
    }

    private static func existingAudioFileURL(_ url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 44 else {
            return nil
        }
        return url
    }

    private static func stageImportedAudio(from sourceURL: URL, destinationDirectory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard sourceURL.pathExtension.lowercased() == "wav" else {
                throw AudioImportError.unsupportedFile
            }

            let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let audioFile = try AVAudioFile(forReading: sourceURL)
            guard audioFile.length > 0 else {
                throw AudioImportError.emptyFile
            }
            guard abs(audioFile.fileFormat.sampleRate - 16_000) < 0.5 else {
                throw AudioImportError.unsupportedSampleRate(audioFile.fileFormat.sampleRate)
            }

            let directory = destinationDirectory
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stagedURL = directory.appendingPathComponent("mic.wav")
                try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                return stagedURL
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private func persist(_ job: TranscriptionJob) {
        do {
            try sessionStore.save(job)
        } catch {
            lastWarning = "Não foi possível persistir o estado da sessão: \(error.localizedDescription)"
        }
    }

    private static func audioDuration(_ url: URL?) -> TimeInterval? {
        guard let url, let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return nil
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func durationIntegrityIssues(
        micURL: URL?,
        systemURL: URL?,
        sessionDuration: TimeInterval,
        sysOffsetMs: Double = 0
    ) -> [String] {
        guard let micDuration = audioDuration(micURL),
              let systemDuration = audioDuration(systemURL) else { return [] }
        let micEnd = micDuration
        let systemEnd = sysOffsetMs / 1_000 + systemDuration
        let reference = max(micEnd, systemEnd, sessionDuration)
        let tolerance = max(5.0, reference * 0.05)
        if sessionDuration - max(micEnd, systemEnd) > tolerance {
            return [
                "As duas trilhas terminaram antes do fim da sessão " +
                "(\(Int(micDuration))s de microfone, \(Int(systemDuration))s de sistema, " +
                "\(Int(sessionDuration))s de sessão)."
            ]
        }
        guard abs(micEnd - systemEnd) > tolerance else { return [] }
        let shorter = micEnd < systemEnd ? "microfone" : "sistema"
        return [
            "A trilha do \(shorter) terminou antes da outra " +
            "(\(Int(micDuration))s de microfone, \(Int(systemDuration))s de sistema)."
        ]
    }

    static func healthIssues(
        mic: AudioCaptureHealth?,
        system: AudioCaptureHealth?
    ) -> [String] {
        var issues: [String] = []
        if let error = mic?.firstErrorDescription {
            issues.append("Falha de escrita no microfone: \(error)")
        }
        if let error = mic?.recoveryErrorDescription {
            issues.append("Falha ao retomar o microfone: \(error)")
        }
        if let error = system?.firstErrorDescription {
            issues.append("Falha de escrita no áudio do sistema: \(error)")
        }
        if let error = system?.streamStopErrorDescription {
            issues.append("A captura do sistema foi interrompida: \(error)")
        }
        if let mic, mic.insertedSilenceByteCount > 32_000 {
            issues.append("O microfone teve um intervalo de captura superior a um segundo; silêncio foi inserido para preservar a linha do tempo.")
        }
        if let system, system.insertedSilenceByteCount > 32_000 {
            issues.append("O áudio do sistema teve um intervalo de captura superior a um segundo; silêncio foi inserido para preservar a linha do tempo.")
        }
        return Array(Set(issues)).sorted()
    }

    private static func hostTimeAgeSeconds(_ hostTime: UInt64?) -> TimeInterval {
        guard let hostTime else { return .infinity }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_absolute_time() >= hostTime ? mach_absolute_time() - hostTime : 0
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    private static func uniqueArchiveDirectory(for outputURL: URL) throws -> URL {
        let fm = FileManager.default
        let base = outputURL.deletingPathExtension()
        if !fm.fileExists(atPath: base.path) {
            return base
        }

        for index in 1...999 {
            let candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(index)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw NSError(
            domain: "MeetingTranscriber",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Não foi possível criar pasta única para os áudios da sessão"]
        )
    }

    static func defaultTitle() -> String {
        "Reunião \(formattedTitleDate(Date()))"
    }

    private static func calendarTitle(for meeting: CalendarMeeting) -> String {
        "\(meeting.title) — \(formattedTitleDate(meeting.startDate))"
    }

    private static func formattedTitleDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }

    /// A fila só vive na memória do processo: sem isso, reabrir o app zera a
    /// lista mesmo com transcrições recentes já salvas em disco. Reconstrói os
    /// jobs mais recentes a partir dos `.md` existentes na pasta de saída.
    private static func loadRecentFinishedJobs(from outputDirectory: URL, limit: Int) -> [TranscriptionJob] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let recent = entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)

        return recent.map { url, date in
            TranscriptionJob(
                id: UUID(),
                title: transcriptTitle(from: url) ?? url.deletingPathExtension().lastPathComponent,
                language: "auto",
                micURL: nil,
                systemURL: nil,
                outputDir: outputDirectory,
                sysOffsetMs: 0,
                createdAt: date,
                startedAt: nil,
                completedAt: date,
                status: .succeeded(url)
            )
        }
    }

    /// O Markdown gerado por transcribe_meeting.py começa com "# {título}".
    private static func transcriptTitle(from url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
        else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# ") else { return nil }
        return String(trimmed.dropFirst(2))
    }
}

private enum AudioImportError: LocalizedError {
    case unsupportedFile
    case emptyFile
    case unsupportedSampleRate(Double)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Selecione um arquivo WAV."
        case .emptyFile:
            return "O arquivo selecionado não contém áudio."
        case .unsupportedSampleRate(let sampleRate):
            return "O WAV precisa ter 16 kHz; o arquivo selecionado tem \(Int(sampleRate)) Hz."
        }
    }
}
