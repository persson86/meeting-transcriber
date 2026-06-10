import AVFoundation
import Foundation

final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writer = WAVWriter()
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!

    /// Mach absolute time do primeiro buffer recebido. Usado para calcular offset entre trilhas.
    private(set) var firstBufferTime: UInt64?

    func start() throws {
        let inputNode = engine.inputNode
        let srcFmt = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw NSError(domain: "MicRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create mic audio converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: srcFmt) { [weak self] buf, time in
            guard let self else { return }
            if self.firstBufferTime == nil {
                self.firstBufferTime = time.hostTime   // AVAudioTime.hostTime é mach_absolute_time
            }
            if let data = convertToInt16Mono(buf, using: converter) {
                self.writer.append(data)
            }
        }

        try engine.start()
    }

    func stop(saveTo url: URL) throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if !writer.isEmpty {
            try writer.save(to: url)
        }
    }
}
