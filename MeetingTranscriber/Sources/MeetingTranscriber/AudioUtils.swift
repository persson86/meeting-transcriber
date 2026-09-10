import AVFoundation
import Foundation

// MARK: - NSLock helper

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

// MARK: - WAV writer (thread-safe, 16kHz mono Int16, streaming para disco)

/// Grava PCM incrementalmente num arquivo temporário e só renomeia para o destino
/// no `save`, mantendo memória plana durante a gravação (antes o áudio inteiro ficava
/// em `Data` e era duplicado no save). O destino nunca vê um WAV parcial: o header é
/// corrigido no temp e o `moveItem` é atômico no mesmo volume.
struct WAVWriterHealth: Equatable, Sendable {
    let byteCount: UInt32
    let appendCount: UInt64
    let firstErrorDescription: String?
}

/// Estado mínimo, serializável e consultável pela camada de sessão. Contadores de
/// buffer indicam atividade da fonte; bytes indicam o que chegou ao disco.
struct AudioCaptureHealth: Equatable, Sendable {
    let receivedBufferCount: UInt64
    let writtenByteCount: UInt32
    let firstBufferHostTime: UInt64?
    let lastReceivedBufferHostTime: UInt64?
    /// Mantido como o último write efetivo para compatibilidade com o watchdog.
    let lastBufferHostTime: UInt64?
    let lastSuccessfulWriteHostTime: UInt64?
    let firstErrorDescription: String?
    let processingErrorDescription: String?
    let recoveryAttemptCount: UInt64
    let recoveryErrorDescription: String?
    let streamStopErrorDescription: String?
    let insertedSilenceByteCount: UInt32
    let cappedGapCount: UInt64

    var hasAudio: Bool { writtenByteCount > 0 }

    init(
        receivedBufferCount: UInt64,
        writtenByteCount: UInt32,
        firstBufferHostTime: UInt64?,
        lastBufferHostTime: UInt64?,
        firstErrorDescription: String?,
        recoveryAttemptCount: UInt64,
        recoveryErrorDescription: String?,
        streamStopErrorDescription: String?,
        lastReceivedBufferHostTime: UInt64? = nil,
        lastSuccessfulWriteHostTime: UInt64? = nil,
        processingErrorDescription: String? = nil,
        insertedSilenceByteCount: UInt32 = 0,
        cappedGapCount: UInt64 = 0
    ) {
        self.receivedBufferCount = receivedBufferCount
        self.writtenByteCount = writtenByteCount
        self.firstBufferHostTime = firstBufferHostTime
        self.lastReceivedBufferHostTime = lastReceivedBufferHostTime
        self.lastBufferHostTime = lastBufferHostTime
        self.lastSuccessfulWriteHostTime = lastSuccessfulWriteHostTime
        self.firstErrorDescription = firstErrorDescription
        self.processingErrorDescription = processingErrorDescription
        self.recoveryAttemptCount = recoveryAttemptCount
        self.recoveryErrorDescription = recoveryErrorDescription
        self.streamStopErrorDescription = streamStopErrorDescription
        self.insertedSilenceByteCount = insertedSilenceByteCount
        self.cappedGapCount = cappedGapCount
    }
}

enum AudioConversionError: LocalizedError {
    case invalidInputFormat
    case cannotAllocateOutputBuffer
    case converterFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "O buffer de áudio tem formato de entrada inválido."
        case .cannotAllocateOutputBuffer:
            return "Não foi possível alocar o buffer de conversão de áudio."
        case .converterFailed(let detail):
            return "A conversão de áudio falhou: \(detail)"
        case .emptyOutput:
            return "A conversão de áudio não produziu amostras."
        }
    }
}

struct PCMGapFill: Equatable {
    let silence: Data
    let wasCapped: Bool
}

/// Mantém o relógio do WAV alinhado a timestamps de host. Gaps muito longos são
/// limitados para evitar crescimento ilimitado do arquivo e ficam explícitos em
/// `AudioCaptureHealth.cappedGapCount`.
enum PCMGapFiller {
    static let bytesPerSecond = 32_000
    static let maxSilenceSeconds = 30.0

    static func silenceBeforeBuffer(
        lastSuccessfulWriteHostTime: UInt64?,
        lastSuccessfulWriteByteCount: Int,
        nextBufferHostTime: UInt64?
    ) -> PCMGapFill {
        guard let lastSuccessfulWriteHostTime, let nextBufferHostTime,
              lastSuccessfulWriteByteCount >= 0 else {
            return PCMGapFill(silence: Data(), wasCapped: false)
        }

        let previousStart = CMClockMakeHostTimeFromSystemUnits(lastSuccessfulWriteHostTime)
        let previousDuration = CMTime(value: Int64(lastSuccessfulWriteByteCount), timescale: CMTimeScale(bytesPerSecond))
        let expectedNextStart = CMTimeAdd(previousStart, previousDuration)
        let nextStart = CMClockMakeHostTimeFromSystemUnits(nextBufferHostTime)
        let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(nextStart, expectedNextStart))
        guard gapSeconds.isFinite, gapSeconds > 1.0 / Double(bytesPerSecond) else {
            return PCMGapFill(silence: Data(), wasCapped: false)
        }

        let cappedSeconds = min(gapSeconds, maxSilenceSeconds)
        var byteCount = Int((cappedSeconds * Double(bytesPerSecond)).rounded())
        byteCount -= byteCount % 2 // PCM Int16 sempre termina em amostra completa.
        return PCMGapFill(silence: Data(count: byteCount), wasCapped: gapSeconds > maxSilenceSeconds)
    }
}

enum WAVWriterError: LocalizedError {
    case cannotCreateTemporaryFile(URL)
    case stagingFileAlreadyExists(URL)
    case invalidWAVFile(URL)
    case fileTooLarge(URL)
    case destinationAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .cannotCreateTemporaryFile(let url):
            return "Não foi possível criar o arquivo de áudio temporário em \(url.path)."
        case .stagingFileAlreadyExists(let url):
            return "Já existe uma gravação pendente em \(url.path)."
        case .invalidWAVFile(let url):
            return "O arquivo WAV pendente é inválido: \(url.path)."
        case .fileTooLarge(let url):
            return "O arquivo de áudio excede o tamanho suportado: \(url.path)."
        case .destinationAlreadyExists(let url):
            return "O destino do áudio já existe: \(url.path)."
        }
    }
}

final class WAVWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let stagingDirectory: URL?
    private let stagingFileName: String?
    private let preserveOnDeinit: Bool
    private var handle: FileHandle?
    private var tempURL: URL?
    private var firstError: Error?
    private(set) var byteCount: UInt32 = 0     // tamanho do bloco `data` (bytes de PCM já no disco)
    private var appendCount: UInt64 = 0

    /// Com stagingDirectory, o WAV parcial recebe um nome estável e é preservado no
    /// encerramento inesperado para recuperação pela sessão persistente.
    init(
        stagingDirectory: URL? = nil,
        stagingFileName: String? = nil,
        preserveOnDeinit: Bool? = nil
    ) {
        self.stagingDirectory = stagingDirectory
        self.stagingFileName = stagingFileName
        self.preserveOnDeinit = preserveOnDeinit ?? (stagingDirectory != nil)
    }

    var health: WAVWriterHealth {
        lock.withLock {
            WAVWriterHealth(
                byteCount: byteCount,
                appendCount: appendCount,
                firstErrorDescription: firstError?.localizedDescription
            )
        }
    }

    var firstErrorDescription: String? { health.firstErrorDescription }
    var recoverableTemporaryURL: URL? { lock.withLock { tempURL } }

    private func rememberFirstError(_ error: Error) -> Error {
        if firstError == nil { firstError = error }
        return firstError ?? error
    }

    private func ensureOpen() throws {
        guard handle == nil else { return }
        let directory = stagingDirectory ?? FileManager.default.temporaryDirectory
        let name = stagingFileName ?? "wavwriter-\(UUID().uuidString).wav"
        let url = directory.appendingPathComponent(name)
        if stagingFileName != nil, FileManager.default.fileExists(atPath: url.path) {
            throw WAVWriterError.stagingFileAlreadyExists(url)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WAVWriterError.cannotCreateTemporaryFile(url)
        }
        tempURL = url
        let h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: Data(count: 44))   // placeholder de header (reescrito no save)
        handle = h
    }

    @discardableResult
    func append(_ data: Data) -> Bool {
        lock.withLock {
            do {
                guard data.count <= Int(UInt32.max) - Int(byteCount) else {
                    throw WAVWriterError.fileTooLarge(tempURL ?? stagingDirectory ?? FileManager.default.temporaryDirectory)
                }
                try ensureOpen()
                try handle?.write(contentsOf: data)
                byteCount &+= UInt32(data.count)   // só conta o que realmente foi ao disco
                appendCount &+= 1
                return true
            } catch {
                // O callback de áudio não pode propagar, mas a falha fica visível no
                // health e volta a ser lançada ao finalizar a captura.
                _ = rememberFirstError(error)
                return false
            }
        }
    }

    var isEmpty: Bool { lock.withLock { byteCount == 0 } }

    func save(to url: URL) throws {
        try lock.withLock {
            guard let h = handle, let temp = tempURL else {
                if let firstError { throw firstError }
                return
            }
            do {
                try h.seek(toOffset: 0)
                try h.write(contentsOf: Self.makeHeader(dataSize: byteCount))
                try h.close()
                handle = nil
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw WAVWriterError.destinationAlreadyExists(url)
                }
                try FileManager.default.moveItem(at: temp, to: url)
                tempURL = nil
            } catch {
                try? h.close()
                handle = nil
                throw rememberFirstError(error)
            }

            // O áudio que chegou até o disco foi preservado no destino, mas uma
            // falha anterior continua sendo material para a integridade da sessão.
            if let firstError { throw firstError }
        }
    }

    /// Recupera um WAV deixado por um encerramento abrupto. O writer sempre reserva
    /// os primeiros 44 bytes para o header, então basta recalcular os tamanhos antes
    /// de mover o arquivo. O move é atômico quando origem e destino estão no volume
    /// da pasta de sessão.
    static func finalizeInProgressFile(at sourceURL: URL, to destinationURL: URL) throws {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 44 else {
            throw WAVWriterError.invalidWAVFile(sourceURL)
        }
        guard fileSize - 44 <= Int(UInt32.max) else {
            throw WAVWriterError.fileTooLarge(sourceURL)
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WAVWriterError.destinationAlreadyExists(destinationURL)
        }

        let handle = try FileHandle(forUpdating: sourceURL)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: makeHeader(dataSize: UInt32(fileSize - 44)))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    /// Header WAV de 44 bytes: RIFF/WAVEfmt /data, 16 kHz mono Int16.
    private static func makeHeader(dataSize: UInt32) -> Data {
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }

        h += "RIFF".data(using: .ascii)!
        u32(36 + dataSize)
        h += "WAVEfmt ".data(using: .ascii)!
        u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        h += "data".data(using: .ascii)!
        u32(dataSize)
        return h
    }

    deinit {
        // Um staging explícito pertence à recuperação da sessão após crash. O temp
        // padrão continua sendo descartado ao abortar uma gravação normal.
        try? handle?.close()
        if !preserveOnDeinit, let temp = tempURL {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}

// MARK: - Buffer conversion: any AVAudioPCMBuffer → Int16 mono 16kHz Data

func convertToInt16MonoResult(
    _ input: AVAudioPCMBuffer,
    using converter: AVAudioConverter
) -> Result<Data, AudioConversionError> {
    guard input.format.sampleRate > 0 else { return .failure(.invalidInputFormat) }
    let ratio = 16000.0 / input.format.sampleRate
    let outFrames = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outFrames) else {
        return .failure(.cannotAllocateOutputBuffer)
    }

    var inputDone = false
    let ref = input
    var err: NSError?
    let status = converter.convert(to: outBuf, error: &err) { _, status in
        if inputDone { status.pointee = .noDataNow; return nil }
        inputDone = true; status.pointee = .haveData; return ref
    }
    if let err {
        return .failure(.converterFailed(err.localizedDescription))
    }
    guard status != .error else {
        return .failure(.converterFailed("status \(status.rawValue)"))
    }
    guard let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 else {
        return .failure(.emptyOutput)
    }
    return .success(Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2))
}

func convertToInt16Mono(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
    guard case .success(let data) = convertToInt16MonoResult(input, using: converter) else { return nil }
    return data
}
