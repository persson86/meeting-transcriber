import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation

enum RecordingStatus {
    case idle
    case recording
    case stopping
    case error(String)

    var isRecording: Bool { if case .recording = self { return true }; return false }
    var isStopping: Bool { if case .stopping = self { return true }; return false }
    var isBusy: Bool { isRecording || isStopping }
    var canStartRecording: Bool {
        if case .idle = self { return true }
        if case .error = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .stopping: return "Saving audio..."
        case .error(let msg): return msg
        }
    }
}

enum TranscriptionJobStatus: Equatable {
    case queued
    case running
    case succeeded(URL)
    case failed(String)

    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isFinished: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .queued, .running: return false
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

    private var mic: MicRecorder?
    private var sys: SystemAudioRecorder?
    private var tempDir: URL?
    private let maxConcurrentTranscriptions: Int
    private var runners: [UUID: TranscriptionRunner] = [:]

    init() {
        maxConcurrentTranscriptions = AppConfig.maxConcurrentTranscriptions
        outputDirectory = UserDefaults.standard.url(forKey: "outputDirectory")
            ?? AppConfig.defaultOutputDirectory
        language = UserDefaults.standard.string(forKey: "language") ?? "pt"
        meetingTitle = Self.defaultTitle()
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

    var maxConcurrentTranscriptionCount: Int {
        maxConcurrentTranscriptions
    }

    var visibleTranscriptionJobs: [TranscriptionJob] {
        Array(transcriptionJobs.suffix(5).reversed())
    }

    var statusLabel: String {
        if status.isRecording || status.isStopping {
            return status.label
        }
        if runningTranscriptionCount > 0 {
            let queued = queuedTranscriptionCount
            return queued > 0
                ? "Transcribing \(runningTranscriptionCount), \(queued) queued"
                : "Transcribing \(runningTranscriptionCount)"
        }
        if queuedTranscriptionCount > 0 {
            return "\(queuedTranscriptionCount) queued"
        }
        return status.label
    }

    func startRecording() {
        guard status.canStartRecording else { return }
        lastWarning = nil

        // Não bloqueia gravar a próxima reunião, mas avisa: transcrição + nova
        // captura ao mesmo tempo é o pior caso de memória neste Mac.
        if hasActiveTranscription {
            lastWarning = "Transcrição em andamento — gravar agora aumenta o uso de memória (o app processa uma por vez). A gravação continua normalmente."
        }

        Task {
            do {
                guard await ensureMicrophoneAccess() else {
                    status = .error("Permissão de microfone necessária. Ative o Meeting Transcriber em Configurações do Sistema → Privacidade e Segurança → Microfone, depois tente novamente.")
                    return
                }

                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("meeting-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let micRec = MicRecorder()
                try micRec.start()

                let sysRec = SystemAudioRecorder()
                try await sysRec.start()

                mic = micRec
                sys = sysRec
                tempDir = dir
                status = .recording

            } catch {
                let msg = error.localizedDescription
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
        mic = nil; sys = nil; tempDir = nil

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

                try micCopy?.stop(saveTo: micURL)
                try await sysCopy?.stop(saveTo: sysURL)

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
                    warn("Sua voz (microfone) não foi capturada nesta reunião — só o áudio do sistema foi salvo. Verifique o dispositivo de entrada e a permissão do microfone antes da próxima gravação.")
                } else if recordedSystemURL == nil {
                    warn("O áudio do sistema (interlocutor) não foi capturado — só a sua voz foi salva. Verifique a permissão de Gravação de Tela e Áudio do Sistema.")
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

                let job = TranscriptionJob(
                    id: UUID(),
                    title: title,
                    language: currentLanguage,
                    micURL: recordedMicURL,
                    systemURL: recordedSystemURL,
                    outputDir: outDir,
                    sysOffsetMs: sysOffsetMs,
                    createdAt: Date(),
                    startedAt: nil,
                    completedAt: nil,
                    status: .queued
                )

                transcriptionJobs.append(job)
                meetingTitle = Self.defaultTitle()
                status = .idle
                scheduleTranscriptionJobs()

            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func resetError() {
        if case .error = status { status = .idle }
    }

    func clearWarning() {
        lastWarning = nil
    }

    private func warn(_ message: String) {
        lastWarning = message
        NotificationManager.shared.notifyWarning(message)
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
                    sysOffsetMs: job.sysOffsetMs
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
        transcriptionJobs[index].progress = max(transcriptionJobs[index].progress, pct)
    }

    private func finishTranscriptionJob(id: UUID, outputURL: URL) {
        runners[id] = nil
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        transcriptionJobs[index].progress = 100
        transcriptionJobs[index].status = .succeeded(outputURL)
        transcriptionJobs[index].completedAt = Date()
        lastOutputURL = outputURL
        NotificationManager.shared.notifyDone(fileURL: outputURL)
        scheduleTranscriptionJobs()
    }

    private func failTranscriptionJob(id: UUID, message: String) {
        runners[id] = nil
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        transcriptionJobs[index].status = .failed(message)
        transcriptionJobs[index].completedAt = Date()
        scheduleTranscriptionJobs()
    }

    func cancelJob(_ id: UUID) {
        guard let index = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        let job = transcriptionJobs[index]
        runners[id]?.cancel()
        runners[id] = nil
        transcriptionJobs.remove(at: index)
        deleteTempDir(for: job)
        scheduleTranscriptionJobs()
    }

    private func deleteTempDir(for job: TranscriptionJob) {
        guard let audioURL = job.micURL ?? job.systemURL else { return }
        let directory = audioURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporaryDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard directory.path.hasPrefix(temporaryDirectory.path + "/") else { return }
        try? FileManager.default.removeItem(at: directory)
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
        sysOffsetMs: Double
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
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "output": outputURL.lastPathComponent,
            "format": outputURL.pathExtension,
            "files": files
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
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return "Reunião \(fmt.string(from: Date()))"
    }
}
