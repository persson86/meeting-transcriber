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
    /// Enquanto captura, a transcrição fica pausada (v1.7).
    var isCapturing: Bool { isStarting || isRecording || isStopping }
    var canStartRecording: Bool {
        if case .idle = self { return true }
        if case .error = self { return true }
        return false
    }
    var isError: Bool { if case .error = self { return true }; return false }

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
    var micURL: URL?
    var systemURL: URL?
    let outputDir: URL
    let sysOffsetMs: Double
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var status: TranscriptionJobStatus
    var progress: Int = 0
    var exportedToSecondBrain: Bool = false
    var captureIntegrity: CaptureIntegrity = .unknown
    /// Evento do Calendar escolhido pelo usuário para esta gravação (v1.4).
    var calendarMeeting: CalendarMeeting? = nil
    /// Medição da sessão para o manifest v2 (versões, aparelho, tentativas do ASR).
    var record: SessionRecord? = nil
    /// Erro de uma ação lateral (envio ao second-brain). Fica no job e nunca no
    /// estado de captura: um envio que falha não pode esconder a gravação.
    var sideError: String? = nil
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: RecordingStatus = .idle {
        didSet { applyTranscriptionPause() }
    }
    /// Transcrições em andamento suspensas durante a gravação.
    @Published private(set) var transcriptionsPaused = false
    @Published var meetingTitle: String = ""
    @Published var lastWarning: String?
    @Published var lastOutputURL: URL?
    @Published var outputDirectory: URL
    @Published var language: String  // "pt" | "en" | "auto"
    @Published var transcriptionJobs: [TranscriptionJob] = []
    @Published var isCalendarSyncing = false
    /// Mensagem de alerta enquanto o microfone está sem entregar áudio durante a
    /// gravação. O ícone da barra de menu muda enquanto não for nil.
    @Published var captureAlert: String?
    /// Estado da trilha do microfone durante a gravação (v1.6). Só vira `.ok`
    /// quando o áudio chega de fato.
    @Published var micCaptureState: MicCaptureState = .waitingForAudio
    @Published private(set) var canRestartMicrophone = true
    /// Prova de vida da gravação (v1.8): atualizada a cada segundo pelo monitor.
    @Published private(set) var captureProof: CaptureProof?
    /// Áudio do sistema parado ou com stream morto durante a gravação.
    @Published private(set) var systemNeedsAttention = false
    /// Há job falho ou com captura parcial que o usuário ainda não viu na lista.
    @Published private(set) var unseenJobProblem = false
    private var manualMicRecoveryAt: TimeInterval?
    /// Instância viva, para o delegate do app decidir o encerramento (v1.8).
    static weak var current: AppState?
    /// O usuário pediu para sair durante a captura: o app só sai depois que os
    /// WAVs e o manifest foram gravados.
    private var quitRequested = false
    /// Pergunta ao usuário se deve parar a gravação para sair. Injetável em teste.
    var confirmQuitWhileCapturing: () -> Bool = AppState.showQuitConfirmation
    /// Libera o `terminateLater` do `NSApplication`. Injetável em teste.
    var replyToTermination: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// Internos (não privados) só para os testes de invariante de estado.
    var mic: MicRecorder?
    var sys: SystemAudioRecorder?
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
    /// Evento escolhido no botão do Calendar e o título que ele preencheu. Se o
    /// usuário editar o título depois, a associação é descartada: evento errado
    /// é pior que nenhum.
    private var selectedCalendarMeeting: CalendarMeeting?
    private var selectedCalendarTitle: String?
    private var currentCalendarMeeting: CalendarMeeting?
    private var currentTitle: String?
    private var currentRecord: SessionRecord?

    /// Quantas transcrições concluídas ficam retidas (na lista e em memória).
    /// Jobs ativos não contam para esse limite — eles são sempre visíveis.
    private static let finishedJobRetentionCount = 5

    init(sessionStore: SessionStore = SessionStore()) {
        self.sessionStore = sessionStore
        maxConcurrentTranscriptions = AppConfig.maxConcurrentTranscriptions
        outputDirectory = UserDefaults.standard.url(forKey: "outputDirectory")
            ?? AppConfig.defaultOutputDirectory
        language = UserDefaults.standard.string(forKey: "language") ?? "pt"
        // Vazio de propósito: o título padrão é calculado no início da gravação,
        // não no stop anterior (o horário ficava errado em até 16 h).
        meetingTitle = ""
        let lease = try? sessionStore.acquireExclusiveLease()
        sessionLease = lease
        storageLeaseAvailable = lease != nil
        Self.current = self
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

    /// Invariante: `status` em {starting, recording, stopping} ⇔ há captura ativa.
    /// Um erro com recorder ainda ativo não autoriza iniciar outra gravação.
    var hasActiveRecorder: Bool { mic != nil || sys != nil }

    func startRecording() {
        guard storageLeaseAvailable, status.canStartRecording, !hasActiveRecorder,
              !isCalendarSyncing else { return }
        status = .starting
        lastWarning = nil

        // Não bloqueia gravar a próxima reunião, mas avisa: transcrição + nova
        // captura ao mesmo tempo é o pior caso de memória neste Mac.
        if hasActiveTranscription {
            lastWarning = "Transcrição em andamento — gravar agora aumenta o uso de memória (o app processa uma por vez). A gravação continua normalmente."
        }

        let typedTitle = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typedTitle.isEmpty ? Self.defaultTitle() : typedTitle
        let calendarMeeting = Self.calendarMeetingForTitle(
            title,
            selected: selectedCalendarMeeting,
            selectedTitle: selectedCalendarTitle
        )
        meetingTitle = title
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
                    if typedTitle.isEmpty { meetingTitle = "" }
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
                    createdAt: createdAt,
                    calendarMeeting: calendarMeeting,
                    record: SessionRecord.starting(at: createdAt)
                )
                pendingDirectory = dir

                let micRec = MicRecorder(
                    stagingDirectory: dir,
                    stagingFileName: "mic.inprogress.wav",
                    preserveOnDeinit: true
                )
                pendingMic = micRec
                let sessionStartUptime = ProcessInfo.processInfo.systemUptime
                try micRec.start()

                let sysRec = SystemAudioRecorder(
                    stagingDirectory: dir,
                    stagingFileName: "system.inprogress.wav",
                    preserveOnDeinit: true
                )
                pendingSystem = sysRec
                try await sysRec.start(sessionStartUptime: sessionStartUptime)

                mic = micRec
                sys = sysRec
                tempDir = dir
                currentSessionID = sessionID
                captureStartedAt = createdAt
                currentTitle = title
                currentRecord = SessionRecord.starting(at: createdAt)
                currentCalendarMeeting = calendarMeeting
                selectedCalendarMeeting = nil
                AppLog.capture.info("start session=\(sessionID.uuidString, privacy: .public)")
                selectedCalendarTitle = nil
                captureHealthWarnings = []
                captureAlert = nil
                micCaptureState = .waitingForAudio
                manualMicRecoveryAt = nil
                canRestartMicrophone = true
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
                if typedTitle.isEmpty { meetingTitle = "" }
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
        guard status.isRecording || (status.isError && hasActiveRecorder) else { return }
        status = .stopping

        let micCopy = mic
        let sysCopy = sys
        let dir = tempDir
        let sessionID = currentSessionID ?? UUID()
        let startedAt = captureStartedAt ?? Date()
        captureMonitorTask?.cancel()
        captureMonitorTask = nil

        let title = currentTitle ?? (meetingTitle.isEmpty ? Self.defaultTitle(at: startedAt) : meetingTitle)
        let calendarMeeting = currentCalendarMeeting
        var sessionRecord = currentRecord ?? SessionRecord.starting(at: captureStartedAt ?? Date())
        sessionRecord.stopReason = quitRequested ? "quit" : "user"
        let outDir = outputDirectory
        let currentLanguage = language
        AppLog.capture.info("stop session=\(sessionID.uuidString, privacy: .public) reason=\(sessionRecord.stopReason ?? "", privacy: .public)")
        captureAlert = nil
        micCaptureState = .waitingForAudio
        captureProof = nil
        systemNeedsAttention = false

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

                let finalMicHealth = micCopy?.health
                let finalSystemHealth = sysCopy?.health
                let sessionDuration = Date().timeIntervalSince(startedAt)
                captureIssues.append(contentsOf: Self.healthIssues(
                    mic: finalMicHealth,
                    system: finalSystemHealth,
                    sessionDuration: sessionDuration
                ))
                captureIssues = Array(Set(captureIssues)).sorted()

                mic = nil; sys = nil; tempDir = nil
                currentSessionID = nil; captureStartedAt = nil
                currentTitle = nil; currentCalendarMeeting = nil; currentRecord = nil
                captureHealthWarnings = []
                sessionRecord.recordingStoppedAt = Date()
                sessionRecord.inputDevice = finalMicHealth?.currentDeviceLabel

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
                    captureIntegrity: Self.captureIntegrity(
                        issues: captureIssues,
                        micEvents: finalMicHealth?.events ?? [],
                        measured: Self.integrityReport(
                            mic: finalMicHealth,
                            system: finalSystemHealth,
                            sessionDuration: sessionDuration
                        )
                    ),
                    calendarMeeting: calendarMeeting,
                    record: sessionRecord
                )

                transcriptionJobs.append(job)
                persist(job)
                if !captureIssues.isEmpty {
                    warn("Captura parcial: \(captureIssues.joined(separator: " ")) O áudio recuperável foi preservado.")
                }
                meetingTitle = ""
                status = .idle
                scheduleTranscriptionJobs()
                finishPendingQuit()

            } catch {
                mic = nil; sys = nil; tempDir = nil
                currentSessionID = nil; captureStartedAt = nil
                currentTitle = nil; currentCalendarMeeting = nil; currentRecord = nil
                captureHealthWarnings = []
                meetingTitle = ""
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
                finishPendingQuit()
            }
        }
    }

    // MARK: - Encerramento seguro (v1.8)

    /// Chamado por `applicationShouldTerminate`. Com captura ativa pergunta antes
    /// e só libera a saída depois de gravar WAVs e manifest; sem captura, cancela
    /// o que o ASR ainda estiver fazendo para o Python não sobreviver ao app.
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        if status.isStarting {
            lastWarning = "Aguarde a gravação terminar de iniciar para sair."
            return .terminateCancel
        }
        guard status.isCapturing || hasActiveRecorder else {
            cancelTranscriptionsForQuit()
            return .terminateNow
        }
        guard confirmQuitWhileCapturing() else { return .terminateCancel }
        quitRequested = true
        if status.isStopping { armQuitTimeout(); return .terminateLater }
        stopRecording()
        if status.isStopping { armQuitTimeout(); return .terminateLater }
        // Nada a parar (estado inconsistente): sai sem deixar o ASR para trás.
        quitRequested = false
        cancelTranscriptionsForQuit()
        return .terminateNow
    }

    /// Se o stop travar (ex.: `stopCapture` do sistema), o app não pode ficar
    /// preso em `terminateLater`: depois do prazo sai com o que já foi gravado em
    /// disco (WAVs em andamento são recuperados na próxima abertura).
    private func armQuitTimeout(seconds: TimeInterval = 20) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.quitRequested else { return }
            AppLog.capture.error("stop não terminou em \(seconds, privacy: .public) s; saindo")
            self.finishPendingQuit()
        }
    }

    private func finishPendingQuit() {
        guard quitRequested else { return }
        cancelTranscriptionsForQuit()
        replyToTermination(true)
    }

    /// Jobs em andamento viram `failed` ("cancelado ao sair") para não haver
    /// retry automático na próxima abertura; o áudio fica preservado.
    func cancelTranscriptionsForQuit() {
        for index in transcriptionJobs.indices where transcriptionJobs[index].status.isRunning {
            let id = transcriptionJobs[index].id
            runners[id]?.cancel()
            runners[id] = nil
            transcriptionJobs[index].status = .failed("Cancelado ao sair do app. O áudio foi preservado para tentar novamente.")
            transcriptionJobs[index].completedAt = Date()
            persist(transcriptionJobs[index])
        }
    }

    private static func showQuitConfirmation() -> Bool {
        // App de barra de menu: sem ativar, o alerta pode abrir atrás de outras janelas.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Há uma gravação em andamento"
        alert.informativeText = "Parar a gravação, salvar o áudio e sair?"
        alert.addButton(withTitle: "Parar e sair")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
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
                meetingTitle = ""
                status = .idle
                scheduleTranscriptionJobs()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Com recorder ativo, limpar o erro não pode declarar o app ocioso.
    func resetError() {
        guard storageLeaseAvailable, !hasActiveRecorder else { return }
        if case .error = status { status = .idle }
    }

    func clearWarning() {
        lastWarning = nil
        calendarWarning = nil
    }

    /// O intervalo mínimo deixa o dispositivo estabilizar antes de novo pedido.
    func restartMicrophone() {
        guard status.isRecording, canRestartMicrophone, let mic else { return }
        manualMicRecoveryAt = ProcessInfo.processInfo.systemUptime
        canRestartMicrophone = false
        mic.requestRecovery()
        captureAlert = "Reiniciando o microfone…"
    }

    /// Indicador do ícone da barra de menu e do cabeçalho do popover.
    var appIndicator: AppIndicator {
        AppIndicator.make(
            status: status,
            micState: micCaptureState,
            systemNeedsAttention: systemNeedsAttention,
            unseenJobProblem: unseenJobProblem
        )
    }

    /// O popover foi aberto: o selo por job falho ou parcial cumpriu a função.
    func acknowledgeJobProblems() {
        if unseenJobProblem { unseenJobProblem = false }
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

                let title = Self.calendarTitle(for: meeting)
                meetingTitle = title
                selectedCalendarMeeting = meeting
                selectedCalendarTitle = title
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, case .recording = self.status else { return }
                self.checkCaptureHealth()
            }
        }
    }

    private func checkCaptureHealth() {
        guard let mic, let sys else { return }
        if let requestedAt = manualMicRecoveryAt {
            canRestartMicrophone = ProcessInfo.processInfo.systemUptime - requestedAt >= MicRecorder.manualRecoveryCooldown
        }
        let micHealth = mic.health
        let systemHealth = sys.health
        // Avisos ao vivo só para o que pede ação agora. A integridade final vem da
        // perda medida no stop (`healthIssues`), não destes avisos.
        var issues: [String] = []
        if let error = micHealth.firstErrorDescription {
            issues.append("Falha ao gravar o microfone: \(error)")
        }
        if let error = systemHealth.firstErrorDescription {
            issues.append("Falha ao gravar o áudio do sistema: \(error)")
        }
        if let error = systemHealth.streamStopErrorDescription {
            issues.append("A captura do áudio do sistema foi interrompida: \(error)")
        }
        let micStalled = Self.micIsStalled(
            health: micHealth,
            secondsSinceCaptureStart: Date().timeIntervalSince(captureStartedAt ?? Date())
        )
        if micStalled {
            issues.append("O microfone deixou de entregar áudio há mais de cinco segundos.")
        }
        micCaptureState = micHealth.captureState
        let elapsed = Date().timeIntervalSince(captureStartedAt ?? Date())
        systemNeedsAttention = Self.systemIsStalled(health: systemHealth, secondsSinceCaptureStart: elapsed)
        captureProof = CaptureProof.make(mic: micHealth, system: systemHealth, elapsed: elapsed)
        updateCaptureAlert(state: CaptureProof.alertState(
            micHealth.captureState,
            hasFirstSignal: micHealth.firstSignalHostTime != nil,
            elapsed: elapsed
        ))
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

    /// O mlx-whisper rodava logo após cada reunião e, em 23 de 55 sessões, durante
    /// a seguinte: disputava o Mac com a captura. Agora o que está rodando é
    /// suspenso enquanto há gravação, e nada novo começa até ela terminar.
    private func applyTranscriptionPause() {
        let paused = status.isCapturing
        guard paused != transcriptionsPaused else { return }
        transcriptionsPaused = paused
        for runner in runners.values { runner.setPaused(paused) }
        AppLog.queue.info("asr \(paused ? "pausado" : "retomado", privacy: .public) jobs=\(self.runners.count, privacy: .public)")
        if !paused { scheduleTranscriptionJobs() }
    }

    private func scheduleTranscriptionJobs() {
        guard !transcriptionsPaused, !quitRequested else { return }
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
        let logURL = sessionStore.sessionDirectory(for: job.id).appendingPathComponent("pipeline.log")
        Task { [job, runner] in
            // O pipeline roda do checkout vivo: a versão é lida a cada job, não
            // só na abertura do app, e fora da faixa suportada o job não começa.
            let scriptPath = AppConfig.scriptPath
            let pipelineVersion = AppVersion.pipelineVersion(atPath: scriptPath)
            if let blocked = PipelineGuard.blockingMessage(forVersion: pipelineVersion) {
                AppLog.runner.error("job bloqueado: \(blocked, privacy: .public)")
                failTranscriptionJob(id: job.id, message: blocked)
                return
            }
            let git = await Task.detached { PipelineGuard.gitState(scriptPath: scriptPath) }.value
            let attemptStart = Date()
            mutateRecord(job.id) { record in
                record.pipelineVersion = pipelineVersion
                record.pipelineGitSha = git.sha
                record.pipelineDirty = git.dirty
                record.asrAttempts.append(ASRAttempt(
                    startedAt: attemptStart, endedAt: nil, exitCode: nil,
                    pausedSeconds: 0, overlappedRecording: transcriptionsPaused
                ))
            }
            AppLog.runner.info("job start id=\(job.id.uuidString, privacy: .public) pipeline=\(pipelineVersion ?? "?", privacy: .public) dirty=\(git.dirty.map(String.init) ?? "?", privacy: .public)")
            var attemptExitCode: Int32?
            defer { closeAttempt(job.id, runner: runner, startedAt: attemptStart, exitCode: attemptExitCode) }
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
                    calendarMeeting: job.calendarMeeting,
                    logURL: logURL,
                    onProgress: { [weak self] pct in
                        Task { @MainActor in
                            self?.updateProgress(id: job.id, pct: pct)
                        }
                    }
                )

                let archiveURL = try Self.archiveSessionFiles(
                    outputURL: outputURL,
                    micURL: job.micURL,
                    systemURL: job.systemURL,
                    title: job.title,
                    language: job.language,
                    sysOffsetMs: job.sysOffsetMs,
                    createdAt: job.createdAt,
                    captureIntegrity: job.captureIntegrity
                )

                let audio = Self.releaseSessionAudio(
                    micURL: job.micURL,
                    systemURL: job.systemURL,
                    archiveURL: archiveURL,
                    sessionRoot: sessionStore.rootDirectory
                )
                finishTranscriptionJob(id: job.id, outputURL: outputURL, micURL: audio.mic, systemURL: audio.system)
            } catch {
                if case TranscriptionError.processFailed(let code, _) = error { attemptExitCode = code }
                failTranscriptionJob(id: job.id, message: error.localizedDescription)
            }
        }
    }

    private func mutateRecord(_ id: UUID, _ body: (inout SessionRecord) -> Void) {
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        var record = transcriptionJobs[index].record ?? SessionRecord()
        body(&record)
        transcriptionJobs[index].record = record
        persist(transcriptionJobs[index])
    }

    /// Fecha a última tentativa: fim, tempo suspenso e se a gravação atravessou o ASR.
    private func closeAttempt(_ id: UUID, runner: TranscriptionRunner, startedAt: Date, exitCode: Int32?) {
        let paused = runner.pausedSecondsTotal
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        let succeeded: Bool
        if case .succeeded = transcriptionJobs[index].status { succeeded = true } else { succeeded = false }
        mutateRecord(id) { record in
            guard let last = record.asrAttempts.lastIndex(where: { $0.startedAt == startedAt }) else { return }
            record.asrAttempts[last].endedAt = Date()
            record.asrAttempts[last].pausedSeconds = (paused * 10).rounded() / 10
            record.asrAttempts[last].overlappedRecording = paused > 0
            record.asrAttempts[last].exitCode = succeeded ? 0 : exitCode
        }
    }

    func pipelineLogURL(for id: UUID) -> URL? {
        let url = sessionStore.sessionDirectory(for: id).appendingPathComponent("pipeline.log")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    private func finishTranscriptionJob(id: UUID, outputURL: URL, micURL: URL?, systemURL: URL?) {
        runners[id] = nil
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        transcriptionJobs[index].micURL = micURL
        transcriptionJobs[index].systemURL = systemURL
        transcriptionJobs[index].progress = 100
        transcriptionJobs[index].status = .succeeded(outputURL)
        transcriptionJobs[index].completedAt = Date()
        persist(transcriptionJobs[index])
        lastOutputURL = outputURL
        let result = JobPresentation.result(for: transcriptionJobs[index])
        if result.needsAttention { unseenJobProblem = true }
        NotificationManager.shared.notifyDone(
            fileURL: outputURL,
            title: result.notificationTitle,
            caveat: result.notificationCaveat
        )
        pruneFinishedJobs()
        scheduleTranscriptionJobs()
    }

    private func failTranscriptionJob(id: UUID, message: String) {
        runners[id] = nil
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        let wasCancelledByUser: Bool
        if case .cancelling = transcriptionJobs[index].status { wasCancelledByUser = true } else { wasCancelledByUser = false }
        transcriptionJobs[index].status = .failed(message)
        transcriptionJobs[index].completedAt = Date()
        persist(transcriptionJobs[index])
        if !wasCancelledByUser, !quitRequested {
            // Falha de transcrição nunca é silenciosa (antes de v1.8 não havia aviso).
            unseenJobProblem = true
            NotificationManager.shared.notifyFailure(title: transcriptionJobs[index].title, message: message)
        }
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

    /// Ação lateral: qualquer falha vai para o job e para o aviso, nunca para
    /// `status` (que pertence ao ciclo de captura).
    func sendToSecondBrain(_ job: TranscriptionJob) {
        guard !status.isCapturing,
              case .succeeded(let outputURL) = job.status,
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
                reportSideError(jobID: job.id, "Não foi possível criar queue/transcricoes/: \(error.localizedDescription)")
                return
            }
        }

        let ts = Int(Date().timeIntervalSince1970)
        let slug = outputURL.deletingPathExtension().lastPathComponent

        var copied: [URL] = []
        do {
            for (source, suffix) in Self.secondBrainArtifacts(for: outputURL, fileManager: fm) {
                let destination = queueDir.appendingPathComponent("\(ts)-meeting-\(slug).\(suffix)")
                try fm.copyItem(at: source, to: destination)
                copied.append(destination)
            }
            guard !copied.isEmpty else {
                reportSideError(jobID: job.id, "Nenhum arquivo de transcrição encontrado para enviar")
                return
            }
            transcriptionJobs[index].exportedToSecondBrain = true
            transcriptionJobs[index].sideError = nil
            persist(transcriptionJobs[index])
        } catch {
            // Pacote incompleto não fica na fila: o retry usa outro timestamp e
            // o feed trataria as cópias parciais como outra reunião.
            for url in copied { try? fm.removeItem(at: url) }
            reportSideError(jobID: job.id, "Falha ao enviar para o second-brain: \(error.localizedDescription)")
        }
    }

    private func reportSideError(jobID: UUID, _ message: String) {
        if let index = transcriptionJobs.firstIndex(where: { $0.id == jobID }) {
            transcriptionJobs[index].sideError = message
        }
        lastWarning = message
    }

    /// Arquivos que vão juntos para o Second Brain, com o mesmo basename: o
    /// companion `.analysis.jsonl` (revisão) só existe a partir do pipeline 0.9.0.
    static func secondBrainArtifacts(
        for outputURL: URL,
        fileManager fm: FileManager = .default
    ) -> [(source: URL, suffix: String)] {
        let directory = outputURL.deletingLastPathComponent()
        let stem = outputURL.deletingPathExtension().lastPathComponent
        return ["md", "jsonl", "analysis.jsonl"].compactMap { suffix in
            let source = directory.appendingPathComponent("\(stem).\(suffix)")
            return fm.fileExists(atPath: source.path) ? (source, suffix) : nil
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

    @discardableResult
    static func archiveSessionFiles(
        outputURL: URL,
        micURL: URL?,
        systemURL: URL?,
        title: String,
        language: String,
        sysOffsetMs: Double,
        createdAt: Date = Date(),
        captureIntegrity: CaptureIntegrity = .unknown
    ) throws -> URL {
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

        var metadata: [String: Any] = [
            "title": title,
            "language": language,
            "sysOffsetMs": sysOffsetMs,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "output": outputURL.lastPathComponent,
            "format": outputURL.pathExtension,
            "files": files,
            "captureIntegrity": captureIntegrity.status.rawValue,
            "captureIssues": captureIntegrity.details,
            "captureDiagnostics": captureIntegrity.diagnostics ?? []
        ]
        if let measured = captureIntegrity.measured,
           let encoded = try? JSONEncoder().encode(measured),
           let object = try? JSONSerialization.jsonObject(with: encoded) {
            metadata["integrity"] = object
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: archiveURL.appendingPathComponent("metadata.json"))
        return archiveURL
    }

    /// Depois do arquivamento, o WAV da sessão é uma cópia idêntica do que foi
    /// para a pasta da transcrição: eram 12 GB duplicados em out/2026. Remove a
    /// cópia da sessão só quando ela está dentro de `sessionRoot` e o arquivo
    /// arquivado tem o mesmo tamanho; o job passa a apontar para o arquivado.
    static func releaseSessionAudio(
        micURL: URL?,
        systemURL: URL?,
        archiveURL: URL,
        sessionRoot: URL,
        fileManager fm: FileManager = .default
    ) -> (mic: URL?, system: URL?) {
        func release(_ source: URL?, archivedName: String) -> URL? {
            guard let source else { return nil }
            let archived = archiveURL.appendingPathComponent(archivedName)
            let root = sessionRoot.standardizedFileURL.path + "/"
            guard source.standardizedFileURL.path.hasPrefix(root),
                  let sourceSize = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? NSNumber,
                  let archivedSize = (try? fm.attributesOfItem(atPath: archived.path))?[.size] as? NSNumber,
                  sourceSize == archivedSize else { return source }
            do {
                try fm.removeItem(at: source)
                return archived
            } catch {
                return source
            }
        }
        return (release(micURL, archivedName: "mic.wav"), release(systemURL, archivedName: "system.wav"))
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

    /// Cobre a latência de abertura e de parada; uma reunião longa não ganha margem.
    static let durationToleranceSeconds: TimeInterval = 5

    static func durationIntegrityIssues(
        micURL: URL?,
        systemURL: URL?,
        sessionDuration: TimeInterval,
        sysOffsetMs: Double = 0
    ) -> [String] {
        guard let micDuration = audioDuration(micURL),
              let systemDuration = audioDuration(systemURL) else { return [] }
        // A duração da sessão começa na captura, não no primeiro buffer do mic.
        // Se o mic demorou a chegar, o offset do sistema é negativo: normalize
        // ambas as trilhas antes de comparar seus finais com a sessão.
        let offset = sysOffsetMs / 1_000
        let micEnd = max(0, -offset) + micDuration
        let systemEnd = max(0, offset) + systemDuration
        // Tolerância fixa: o fim de cada trilha também é medido por trilha
        // (`IntegrityRule`), então não há margem proporcional à duração.
        let tolerance = durationToleranceSeconds
        if sessionDuration - max(micEnd, systemEnd) > tolerance {
            return [
                IntegrityRule.durationMessagePrefixBoth + " " +
                "(\(Int(micDuration))s de microfone, \(Int(systemDuration))s de sistema, " +
                "\(Int(sessionDuration))s de sessão)."
            ]
        }
        guard abs(micEnd - systemEnd) > tolerance else { return [] }
        let shorter = micEnd < systemEnd ? "microfone" : "sistema"
        return [
            IntegrityRule.durationMessagePrefixOne + "\(shorter) terminou antes da outra " +
            "(\(Int(micDuration))s de microfone, \(Int(systemDuration))s de sistema)."
        ]
    }

    /// Uma interrupção no meio da trilha a partir disso vira problema de integridade.
    static let materialDropoutSeconds = IntegrityRule.materialEventSeconds
    /// Perda somada (início + interrupções + fim) a partir disso também vira.
    static let materialLossSeconds = IntegrityRule.materialLossSeconds

    /// v1.7: `degraded` só com falha de escrita/conversão ou perda medida em
    /// segundos. Contagem de rearmes, erro de uma tentativa que depois funcionou e
    /// micro-correções do relógio ficam no diário (`diagnostics`): na 1.6.1 elas
    /// rebaixaram 7 de 7 sessões, três delas com o microfone íntegro.
    /// v1.8: as duas trilhas medem início, buracos e fim com a mesma regra.
    static func healthIssues(
        mic: AudioCaptureHealth?,
        system: AudioCaptureHealth?,
        sessionDuration: TimeInterval = 0
    ) -> [String] {
        var issues: [String] = []
        if let error = mic?.firstErrorDescription {
            issues.append("Falha de escrita no microfone: \(error)")
        }
        if let error = mic?.processingErrorDescription {
            issues.append("Falha ao converter o áudio do microfone: \(error)")
        }
        if let error = system?.firstErrorDescription {
            issues.append("Falha de escrita no áudio do sistema: \(error)")
        }
        if let error = system?.streamStopErrorDescription {
            issues.append("A captura do sistema foi interrompida: \(error)")
        }
        if let error = system?.processingErrorDescription {
            issues.append("Falha ao converter o áudio do sistema: \(error)")
        }
        if let mic, mic.cappedGapCount > 0 {
            issues.append("Um intervalo do microfone excedeu o limite de preenchimento; a sincronização das trilhas pode estar comprometida.")
        }
        if let system, system.cappedGapCount > 0 {
            issues.append("Um intervalo do áudio do sistema excedeu o limite de preenchimento; a sincronização das trilhas pode estar comprometida.")
        }
        if let mic, let loss = micLossIssue(mic, sessionDuration: sessionDuration) {
            issues.append(loss)
        }
        if let system, let loss = lossIssue(label: IntegrityRule.systemLabel, health: system, sessionDuration: sessionDuration) {
            issues.append(loss)
        }
        return Array(Set(issues)).sorted()
    }

    /// Quantidades medidas por trilha, para o manifest e para a interface.
    static func integrityReport(
        mic: AudioCaptureHealth?,
        system: AudioCaptureHealth?,
        sessionDuration: TimeInterval
    ) -> IntegrityReport? {
        var tracks: [String: TrackIntegrity] = [:]
        if let mic, mic.writtenByteCount > 0 { tracks["mic"] = IntegrityRule.measure(mic, sessionDuration: sessionDuration) }
        if let system, system.writtenByteCount > 0 { tracks["system"] = IntegrityRule.measure(system, sessionDuration: sessionDuration) }
        guard !tracks.isEmpty else { return nil }
        return IntegrityReport(ruleVersion: IntegrityRule.version, tracks: tracks, sessionDurationS: max(0, sessionDuration))
    }

    static func micLossIssue(_ mic: AudioCaptureHealth, sessionDuration: TimeInterval = 0) -> String? {
        guard mic.writtenByteCount > 0 else { return nil }
        guard mic.firstSignalHostTime != nil || mic.initialAudioDelaySeconds != nil else {
            return "O microfone não entregou áudio em nenhum momento da gravação."
        }
        return lossIssue(label: IntegrityRule.micLabel, health: mic, sessionDuration: sessionDuration)
    }

    private static func lossIssue(label: String, health: AudioCaptureHealth, sessionDuration: TimeInterval) -> String? {
        guard health.writtenByteCount > 0 else { return nil }
        let track = IntegrityRule.measure(health, sessionDuration: sessionDuration)
        guard IntegrityRule.isMaterial(track, largestGap: health.dropouts.largestSeconds) else { return nil }
        return IntegrityRule.message(label: label, track: track, health: health)
    }

    static func seconds(_ value: TimeInterval) -> String { IntegrityRule.seconds(value) }

    static func hostTimeAgeSeconds(_ hostTime: UInt64?) -> TimeInterval {
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

    static func defaultTitle(at date: Date = Date()) -> String {
        "Reunião \(formattedTitleDate(date))"
    }

    /// Evento vale para a gravação só se o título ainda é o que o botão preencheu.
    static func calendarMeetingForTitle(
        _ title: String,
        selected: CalendarMeeting?,
        selectedTitle: String?
    ) -> CalendarMeeting? {
        guard let selected, let selectedTitle,
              title == selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return selected
    }

    /// Além dos callbacks, considera o estado do watchdog de sinal: callbacks
    /// contendo apenas zeros não comprovam que o microfone voltou a gravar.
    static func micIsStalled(
        health: AudioCaptureHealth,
        secondsSinceCaptureStart: TimeInterval,
        threshold: TimeInterval = 5
    ) -> Bool {
        guard secondsSinceCaptureStart > threshold else { return false }
        if health.captureState.needsAttention { return true }
        // Abertura lenta (fone BT, ~6 s de mediana) não é falha: sem nenhum
        // callback, o aviso só vem depois da janela de abertura (v1.8).
        if health.receivedBufferCount == 0 {
            return secondsSinceCaptureStart >= CaptureProof.openingGraceSeconds
        }
        let lastReceived = health.lastSignalHostTime ?? health.lastReceivedBufferHostTime ?? health.lastBufferHostTime
        return hostTimeAgeSeconds(lastReceived) > threshold
    }

    /// Callbacks do sistema pararam por mais de `threshold` s, ou o stream morreu.
    /// Silêncio com callbacks não conta: reunião presencial não gera áudio do sistema.
    static func systemIsStalled(
        health: AudioCaptureHealth,
        secondsSinceCaptureStart: TimeInterval,
        threshold: TimeInterval = 5
    ) -> Bool {
        if health.streamStopErrorDescription != nil { return true }
        guard secondsSinceCaptureStart > threshold else { return false }
        if health.receivedBufferCount == 0 { return true }
        // Sem relógio de sincronização não há idade confiável: não alarma.
        guard let last = health.lastReceivedBufferHostTime else { return false }
        return hostTimeAgeSeconds(last) > threshold
    }

    private func updateCaptureAlert(state: MicCaptureState) {
        if let message = Self.captureAlertMessage(for: state) {
            captureAlert = message
        } else if captureAlert != nil {
            captureAlert = nil
            lastWarning = "O microfone voltou a gravar. O intervalo sem áudio fica registrado na transcrição."
        }
    }

    static func captureAlertMessage(for state: MicCaptureState) -> String? {
        switch state {
        case .waitingForAudio, .ok:
            return nil
        case .recovering(let attempts):
            return attempts == 0
                ? "Microfone sem áudio — tentando recuperar a captura."
                : "Microfone sem áudio — tentativa \(attempts) de recuperação."
        case .failed(let attempts):
            return "Microfone sem áudio após \(attempts) tentativas automáticas. Use Reiniciar microfone ou pare e grave de novo."
        }
    }

    static func captureIntegrity(
        issues: [String],
        micEvents: [String],
        measured: IntegrityReport? = nil
    ) -> CaptureIntegrity {
        var integrity: CaptureIntegrity = issues.isEmpty ? .complete : .degraded(issues)
        integrity.diagnostics = micEvents.isEmpty ? nil : micEvents
        integrity.measured = measured
        return integrity
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
