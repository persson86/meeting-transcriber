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
final class WAVWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var tempURL: URL?
    private(set) var byteCount: UInt32 = 0     // tamanho do bloco `data` (bytes de PCM já no disco)

    private func ensureOpen() throws {
        guard handle == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: Data(count: 44))   // placeholder de header (reescrito no save)
        handle = h
        tempURL = url
    }

    func append(_ data: Data) {
        lock.withLock {
            do {
                try ensureOpen()
                try handle?.write(contentsOf: data)
                byteCount &+= UInt32(data.count)   // só conta o que realmente foi ao disco
            } catch {
                // Falha de escrita no callback de áudio não pode propagar; manter
                // byteCount consistente com os bytes efetivamente gravados.
            }
        }
    }

    var isEmpty: Bool { lock.withLock { byteCount == 0 } }

    func save(to url: URL) throws {
        try lock.withLock {
            guard let h = handle, let temp = tempURL else { return }   // nada gravado
            try h.seek(toOffset: 0)
            try h.write(contentsOf: makeHeader(dataSize: byteCount))    // corrige RIFF/data size
            try h.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)                // destino limpo
            try FileManager.default.moveItem(at: temp, to: url)         // rename ~atômico (mesmo volume)
            tempURL = nil
        }
    }

    /// Header WAV de 44 bytes: RIFF/WAVEfmt /data, 16 kHz mono Int16.
    private func makeHeader(dataSize: UInt32) -> Data {
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
        // Se a gravação foi abortada sem `save`, não deixa arquivo temporário órfão.
        try? handle?.close()
        if let temp = tempURL {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}

// MARK: - Buffer conversion: any AVAudioPCMBuffer → Int16 mono 16kHz Data

func convertToInt16Mono(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
    let ratio = 16000.0 / input.format.sampleRate
    let outFrames = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outFrames) else { return nil }

    var inputDone = false
    let ref = input
    var err: NSError?
    converter.convert(to: outBuf, error: &err) { _, status in
        if inputDone { status.pointee = .noDataNow; return nil }
        inputDone = true; status.pointee = .haveData; return ref
    }
    guard err == nil, let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 else { return nil }
    return Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2)
}
