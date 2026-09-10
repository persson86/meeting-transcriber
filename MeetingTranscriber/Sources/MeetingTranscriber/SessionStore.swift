import Foundation
import Darwin

enum SessionStoreError: LocalizedError {
    case cannotAcquireLease(String)

    var errorDescription: String? {
        switch self {
        case .cannotAcquireLease(let detail):
            return "Outra instância do Meeting Transcriber está usando as sessões: \(detail)"
        }
    }
}

final class SessionStoreLease {
    private var descriptor: Int32

    init(lockURL: URL) throws {
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw SessionStoreError.cannotAcquireLease(String(cString: strerror(errno)))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(fd)
            throw SessionStoreError.cannotAcquireLease(detail)
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

enum CaptureIntegrityStatus: String, Codable {
    case unknown
    case complete
    case degraded
}

struct CaptureIntegrity: Codable, Equatable {
    var status: CaptureIntegrityStatus
    var details: [String]

    static let unknown = CaptureIntegrity(status: .unknown, details: [])
    static let complete = CaptureIntegrity(status: .complete, details: [])

    static func degraded(_ details: [String]) -> CaptureIntegrity {
        CaptureIntegrity(status: .degraded, details: details)
    }
}

enum DurableSessionState: String, Codable {
    case recording
    case queued
    case running
    case cancelling
    case succeeded
    case failed
}

struct DurableSessionManifest: Codable, Equatable {
    var schemaVersion = 1
    let id: UUID
    var title: String
    var language: String
    var outputDirectory: String
    var micPath: String?
    var systemPath: String?
    var sysOffsetMs: Double
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var state: DurableSessionState
    var progress: Int
    var outputPath: String?
    var error: String?
    var exportedToSecondBrain: Bool
    var hidden: Bool
    var captureIntegrity: CaptureIntegrity
}

struct SessionStore {
    let rootDirectory: URL

    init(rootDirectory: URL = AppConfig.sessionRoot) {
        self.rootDirectory = rootDirectory
    }

    func acquireExclusiveLease() throws -> SessionStoreLease {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        return try SessionStoreLease(lockURL: rootDirectory.appendingPathComponent(".instance.lock"))
    }

    func prepareRecording(
        id: UUID,
        title: String,
        language: String,
        outputDirectory: URL,
        createdAt: Date
    ) throws -> URL {
        let directory = sessionDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = DurableSessionManifest(
            id: id,
            title: title,
            language: language,
            outputDirectory: outputDirectory.path,
            micPath: directory.appendingPathComponent("mic.wav").path,
            systemPath: directory.appendingPathComponent("system.wav").path,
            sysOffsetMs: 0,
            createdAt: createdAt,
            startedAt: createdAt,
            completedAt: nil,
            state: .recording,
            progress: 0,
            outputPath: nil,
            error: nil,
            exportedToSecondBrain: false,
            hidden: false,
            captureIntegrity: .unknown
        )
        try write(manifest)
        return directory
    }

    func save(_ job: TranscriptionJob, hidden: Bool? = nil) throws {
        let previous = try? readManifest(id: job.id)
        let state: DurableSessionState
        let outputPath: String?
        let error: String?
        switch job.status {
        case .queued:
            state = .queued; outputPath = nil; error = nil
        case .running:
            state = .running; outputPath = nil; error = nil
        case .cancelling:
            state = .cancelling; outputPath = nil; error = nil
        case .succeeded(let url):
            state = .succeeded; outputPath = url.path; error = nil
        case .failed(let message):
            state = .failed; outputPath = nil; error = message
        }

        let manifest = DurableSessionManifest(
            id: job.id,
            title: job.title,
            language: job.language,
            outputDirectory: job.outputDir.path,
            micPath: job.micURL?.path,
            systemPath: job.systemURL?.path,
            sysOffsetMs: job.sysOffsetMs,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            state: state,
            progress: job.progress,
            outputPath: outputPath,
            error: error,
            exportedToSecondBrain: job.exportedToSecondBrain,
            hidden: hidden ?? previous?.hidden ?? false,
            captureIntegrity: job.captureIntegrity
        )
        try write(manifest)
    }

    func hide(id: UUID) throws {
        var manifest = try readManifest(id: id)
        manifest.hidden = true
        try write(manifest)
    }

    func loadJobs() -> [TranscriptionJob] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { directory -> TranscriptionJob? in
            guard var manifest = try? readManifest(at: directory), !manifest.hidden else { return nil }

            let recovery = recoverInProgressAudio(in: directory, manifest: &manifest)
            if !recovery.recoveredRoles.isEmpty || !recovery.issues.isEmpty {
                let details = manifest.captureIntegrity.details
                    + recovery.recoveredRoles.map { "Áudio parcial de \($0) recuperado após interrupção." }
                    + recovery.issues
                manifest.captureIntegrity = .degraded(Array(Set(details)).sorted())
                try? write(manifest)
            }

            if manifest.state == .recording {
                manifest.state = .failed
                manifest.completedAt = manifest.completedAt ?? Date()
                manifest.error = recovery.issues.isEmpty
                    ? "A gravação foi interrompida. O áudio recuperável foi preservado."
                    : "A gravação foi interrompida. " + recovery.issues.joined(separator: " ")
                manifest.captureIntegrity = .degraded(
                    Array(Set(manifest.captureIntegrity.details + [manifest.error!])).sorted()
                )
                try? write(manifest)
            }

            let status: TranscriptionJobStatus
            var completedAt = manifest.completedAt
            switch manifest.state {
            case .recording:
                status = .failed(manifest.error ?? "A gravação foi interrompida.")
                completedAt = completedAt ?? Date()
            case .queued:
                status = .queued
            case .running, .cancelling:
                status = .failed("O processamento foi interrompido. Use tentar novamente.")
                completedAt = completedAt ?? Date()
            case .succeeded:
                guard let path = manifest.outputPath,
                      fileManager.fileExists(atPath: path) else {
                    status = .failed("A saída registrada não foi encontrada. O áudio foi preservado.")
                    completedAt = completedAt ?? Date()
                    break
                }
                status = .succeeded(URL(fileURLWithPath: path))
            case .failed:
                status = .failed(manifest.error ?? "Falha de transcrição. O áudio foi preservado.")
            }

            let mic = manifest.micPath.flatMap { fileManager.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
            let system = manifest.systemPath.flatMap { fileManager.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
            return TranscriptionJob(
                id: manifest.id,
                title: manifest.title,
                language: manifest.language,
                micURL: mic,
                systemURL: system,
                outputDir: URL(fileURLWithPath: manifest.outputDirectory),
                sysOffsetMs: manifest.sysOffsetMs,
                createdAt: manifest.createdAt,
                startedAt: manifest.startedAt,
                completedAt: completedAt,
                status: status,
                progress: manifest.progress,
                exportedToSecondBrain: manifest.exportedToSecondBrain,
                captureIntegrity: manifest.captureIntegrity
            )
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func recoverInProgressAudio(
        in directory: URL,
        manifest: inout DurableSessionManifest
    ) -> (recoveredRoles: [String], issues: [String]) {
        var recoveredRoles: [String] = []
        var issues: [String] = []
        for role in ["mic", "system"] {
            let source = directory.appendingPathComponent("\(role).inprogress.wav")
            let destination = directory.appendingPathComponent("\(role).wav")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try WAVWriter.finalizeInProgressFile(at: source, to: destination)
                if role == "mic" { manifest.micPath = destination.path }
                else { manifest.systemPath = destination.path }
                recoveredRoles.append(role == "mic" ? "microfone" : "sistema")
            } catch {
                issues.append("Não foi possível finalizar \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (recoveredRoles, issues)
    }

    func sessionDirectory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("manifest.json")
    }

    private func readManifest(id: UUID) throws -> DurableSessionManifest {
        try decodeManifest(at: manifestURL(for: id))
    }

    private func readManifest(at directory: URL) throws -> DurableSessionManifest {
        try decodeManifest(at: directory.appendingPathComponent("manifest.json"))
    }

    private func decodeManifest(at url: URL) throws -> DurableSessionManifest {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(DurableSessionManifest.self, from: data)
    }

    private func write(_ manifest: DurableSessionManifest) throws {
        let directory = sessionDirectory(for: manifest.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(manifest)
        try data.write(to: manifestURL(for: manifest.id), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
