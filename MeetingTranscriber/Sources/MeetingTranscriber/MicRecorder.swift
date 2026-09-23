import AVFoundation
import Foundation
import ObjCExceptionCatcher

final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writer: WAVWriter
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private let healthLock = NSLock()
    private var configObserver: NSObjectProtocol?

    /// Mach absolute time do primeiro buffer recebido. Usado para calcular offset entre trilhas.
    private var firstBufferHostTime: UInt64?
    private var lastReceivedBufferHostTime: UInt64?
    private var lastSuccessfulWriteHostTime: UInt64?
    private var lastSuccessfulWriteByteCount: Int = 0
    private var receivedBufferCount: UInt64 = 0
    private var processingErrorDescription: String?
    private var recoveryAttemptCount: UInt64 = 0
    private var recoveryErrorDescription: String?
    private var insertedSilenceByteCount: UInt32 = 0
    private var cappedGapCount: UInt64 = 0

    var firstBufferTime: UInt64? { healthLock.withLock { firstBufferHostTime } }

    var health: AudioCaptureHealth {
        let writerHealth = writer.health
        return healthLock.withLock {
            AudioCaptureHealth(
                receivedBufferCount: receivedBufferCount,
                writtenByteCount: writerHealth.byteCount,
                firstBufferHostTime: firstBufferHostTime,
                lastBufferHostTime: lastSuccessfulWriteHostTime,
                firstErrorDescription: processingErrorDescription ?? writerHealth.firstErrorDescription,
                recoveryAttemptCount: recoveryAttemptCount,
                recoveryErrorDescription: recoveryErrorDescription,
                streamStopErrorDescription: nil,
                lastReceivedBufferHostTime: lastReceivedBufferHostTime,
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                processingErrorDescription: processingErrorDescription,
                insertedSilenceByteCount: insertedSilenceByteCount,
                cappedGapCount: cappedGapCount
            )
        }
    }

    init(
        stagingDirectory: URL? = nil,
        stagingFileName: String = "mic.inprogress.wav",
        preserveOnDeinit: Bool? = nil
    ) {
        self.writer = WAVWriter(
            stagingDirectory: stagingDirectory,
            stagingFileName: stagingDirectory == nil ? nil : stagingFileName,
            preserveOnDeinit: preserveOnDeinit
        )
    }

    init(writer: WAVWriter) {
        self.writer = writer
    }

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
            // AVAudioEngine sinaliza estados inválidos (ex.: formato do hardware em
            // transição quando o app de call assume o mic) com NSException, que Swift
            // não captura: foi o crash de 16/set. O shim ObjC converte em erro, e o
            // rearme falho vira aviso de captura parcial em vez de derrubar o app.
            var inputNode: AVAudioInputNode?
            var srcFmt: AVAudioFormat?
            try MTObjCExceptionCatcher.perform {
                let node = self.engine.inputNode
                inputNode = node
                srcFmt = node.outputFormat(forBus: 0)
            }
            guard let inputNode, let srcFmt, srcFmt.sampleRate > 0, srcFmt.channelCount > 0 else {
                throw NSError(domain: "MicRecorder", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Nenhum dispositivo de entrada de áudio disponível"])
            }

            guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
                throw NSError(domain: "MicRecorder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot create mic audio converter"])
            }

            try MTObjCExceptionCatcher.perform {
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: srcFmt) { [weak self] buf, time in
                    guard let self else { return }
                    let hostTime = time.isHostTimeValid ? time.hostTime : nil
                    self.recordReceivedBuffer(hostTime: hostTime)
                    switch convertToInt16MonoResult(buf, using: converter) {
                    case .success(let data):
                        self.appendConvertedPCM(data, hostTime: hostTime)
                    case .failure(let error):
                        self.recordProcessingFailure(error)
                    }
                }
            }

            var startError: Error?
            try MTObjCExceptionCatcher.perform {
                guard !self.engine.isRunning else { return }
                do { try self.engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        }
    }

    private func handleConfigurationChange() {
        // O engine já se parou ao trocar de configuração; reconstrói o tap com o novo
        // formato de entrada e retoma a captura. Se falhar, a trilha vazia é detectada
        // e sinalizada ao usuário em AppState.stopRecording().
        healthLock.withLock { recoveryAttemptCount &+= 1 }
        do {
            try installTapAndStart()
        } catch {
            recordRearmFailure(error)
        }
    }

    func recordRearmFailure(_ error: Error) {
        healthLock.withLock {
            if recoveryErrorDescription == nil {
                recoveryErrorDescription = error.localizedDescription
            }
        }
    }

    func recordReceivedBuffer(hostTime: UInt64?) {
        healthLock.withLock {
            if firstBufferHostTime == nil { firstBufferHostTime = hostTime }
            if let hostTime { lastReceivedBufferHostTime = hostTime }
            receivedBufferCount &+= 1
        }
    }

    func recordProcessingFailure(_ error: Error) {
        healthLock.withLock {
            if processingErrorDescription == nil {
                processingErrorDescription = error.localizedDescription
            }
        }
    }

    private func appendConvertedPCM(_ data: Data, hostTime: UInt64?) {
        let gap = healthLock.withLock {
            PCMGapFiller.silenceBeforeBuffer(
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                lastSuccessfulWriteByteCount: lastSuccessfulWriteByteCount,
                nextBufferHostTime: hostTime
            )
        }
        if !gap.silence.isEmpty {
            guard writer.append(gap.silence) else { return }
            healthLock.withLock {
                insertedSilenceByteCount &+= UInt32(gap.silence.count)
                if gap.wasCapped {
                    cappedGapCount &+= 1
                    if processingErrorDescription == nil {
                        processingErrorDescription = "Um intervalo sem callbacks excedeu \(Int(PCMGapFiller.maxSilenceSeconds)) segundos e foi limitado."
                    }
                }
            }
        }
        guard writer.append(data) else { return }
        recordSuccessfulWrite(hostTime: hostTime, byteCount: data.count)
    }

    func recordSuccessfulWrite(hostTime: UInt64?, byteCount: Int) {
        healthLock.withLock {
            lastSuccessfulWriteHostTime = hostTime
            lastSuccessfulWriteByteCount = byteCount
        }
    }

    func stop(saveTo url: URL) throws {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        lock.withLock {
            try? MTObjCExceptionCatcher.perform {
                self.engine.stop()
                self.engine.inputNode.removeTap(onBus: 0)
            }
        }
        if !writer.isEmpty || writer.firstErrorDescription != nil {
            try writer.save(to: url)
        }
    }
}
