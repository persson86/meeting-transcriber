import AVFoundation
import Foundation

final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writer = WAVWriter()
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var configObserver: NSObjectProtocol?

    /// Mach absolute time do primeiro buffer recebido. Usado para calcular offset entre trilhas.
    private(set) var firstBufferTime: UInt64?

    func start() throws {
        try installTapAndStart()

        // Se a rota/dispositivo de entrada mudar no meio da reunião (ex.: conectar
        // AirPods/headset), o AVAudioEngine para e o tap silenciosamente deixa de
        // entregar buffers — foi assim que uma gravação perdeu a trilha do microfone
        // inteira. Reinstalamos o tap para o novo formato e reiniciamos o engine.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func installTapAndStart() throws {
        try lock.withLock {
            let inputNode = engine.inputNode
            let srcFmt = inputNode.outputFormat(forBus: 0)

            guard srcFmt.sampleRate > 0, srcFmt.channelCount > 0 else {
                throw NSError(domain: "MicRecorder", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Nenhum dispositivo de entrada de áudio disponível"])
            }

            guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
                throw NSError(domain: "MicRecorder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot create mic audio converter"])
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: srcFmt) { [weak self] buf, time in
                guard let self else { return }
                if self.firstBufferTime == nil {
                    self.firstBufferTime = time.hostTime   // AVAudioTime.hostTime é mach_absolute_time
                }
                if let data = convertToInt16Mono(buf, using: converter) {
                    self.writer.append(data)
                }
            }

            if !engine.isRunning {
                try engine.start()
            }
        }
    }

    private func handleConfigurationChange() {
        // O engine já se parou ao trocar de configuração; reconstrói o tap com o novo
        // formato de entrada e retoma a captura. Se falhar, a trilha vazia é detectada
        // e sinalizada ao usuário em AppState.stopRecording().
        try? installTapAndStart()
    }

    func stop(saveTo url: URL) throws {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        lock.withLock {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        if !writer.isEmpty {
            try writer.save(to: url)
        }
    }
}
