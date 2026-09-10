import AVFoundation
import ScreenCaptureKit
import Foundation

final class SystemAudioRecorder: @unchecked Sendable {
    private var stream: SCStream?
    private let delegate: SysDelegate
    private let writer: WAVWriter
    private let sampleHandlerQueue = DispatchQueue(label: "MeetingTranscriber.SystemAudioRecorder.audio", qos: .userInitiated)

    /// PTS do ScreenCaptureKit convertido pelo synchronizationClock oficial para
    /// host time. Não usa o instante tardio em que o callback foi escalonado.
    var firstBufferTime: UInt64? { delegate.firstBufferHostTime }
    var firstBufferPresentationTime: CMTime? { delegate.firstBufferPresentationTime }
    var health: AudioCaptureHealth { delegate.health }

    func recordStreamStopError(_ error: Error) {
        delegate.recordStreamStopError(error)
    }

    init(
        stagingDirectory: URL? = nil,
        stagingFileName: String = "system.inprogress.wav",
        preserveOnDeinit: Bool? = nil
    ) {
        self.writer = WAVWriter(
            stagingDirectory: stagingDirectory,
            stagingFileName: stagingDirectory == nil ? nil : stagingFileName,
            preserveOnDeinit: preserveOnDeinit
        )
        self.delegate = SysDelegate(writer: writer)
    }

    init(writer: WAVWriter) {
        self.writer = writer
        self.delegate = SysDelegate(writer: writer)
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found for audio capture"])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        delegate.setSynchronizationClock(stream.synchronizationClock)
        try stream.addStreamOutput(delegate, type: .audio,
                                   sampleHandlerQueue: sampleHandlerQueue)
        try await stream.startCapture()
        delegate.setSynchronizationClock(stream.synchronizationClock)
        self.stream = stream
    }

    func stop(saveTo url: URL) async throws {
        // stopCapture() throws if the stream already died mid-recording (e.g. the
        // OS tears it down after dropped frames). That's a signal, not a reason to
        // discard whatever the writer already buffered — best-effort stop, then
        // always try to save.
        do {
            try await stream?.stopCapture()
        } catch {
            recordStreamStopError(error)
        }
        stream = nil
        if !writer.isEmpty || writer.firstErrorDescription != nil {
            try writer.save(to: url)
        }
    }
}

// MARK: - SCStream delegate

private final class SysDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: WAVWriter
    private let lock = NSLock()
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var receivedBufferCount: UInt64 = 0
    private var firstBufferHostTimeStorage: UInt64?
    private var lastReceivedBufferHostTime: UInt64?
    private var lastSuccessfulWriteHostTime: UInt64?
    private var lastSuccessfulWriteByteCount: Int = 0
    private var firstBufferPresentationTimeStorage: CMTime?
    private var synchronizationClock: CMClock?
    private var streamStopErrorDescription: String?
    private var processingErrorDescription: String?
    private var insertedSilenceByteCount: UInt32 = 0
    private var cappedGapCount: UInt64 = 0

    var firstBufferHostTime: UInt64? { lock.withLock { firstBufferHostTimeStorage } }
    var firstBufferPresentationTime: CMTime? { lock.withLock { firstBufferPresentationTimeStorage } }
    var health: AudioCaptureHealth {
        let writerHealth = writer.health
        return lock.withLock {
            AudioCaptureHealth(
                receivedBufferCount: receivedBufferCount,
                writtenByteCount: writerHealth.byteCount,
                firstBufferHostTime: firstBufferHostTimeStorage,
                lastBufferHostTime: lastSuccessfulWriteHostTime,
                firstErrorDescription: processingErrorDescription ?? writerHealth.firstErrorDescription,
                recoveryAttemptCount: 0,
                recoveryErrorDescription: nil,
                streamStopErrorDescription: streamStopErrorDescription,
                lastReceivedBufferHostTime: lastReceivedBufferHostTime,
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                processingErrorDescription: processingErrorDescription,
                insertedSilenceByteCount: insertedSilenceByteCount,
                cappedGapCount: cappedGapCount
            )
        }
    }

    init(writer: WAVWriter) { self.writer = writer; super.init() }

    func setSynchronizationClock(_ clock: CMClock?) {
        lock.withLock {
            synchronizationClock = clock
            if firstBufferHostTimeStorage == nil,
               let presentationTime = firstBufferPresentationTimeStorage {
                firstBufferHostTimeStorage = hostTimeLocked(for: presentationTime)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let fmtDesc = sb.formatDescription else {
            recordProcessingFailure(NSError(
                domain: "SystemAudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "O callback do áudio do sistema não contém formato PCM."]
            ))
            return
        }

        recordReceivedBuffer(presentationTime: sb.presentationTimeStamp)

        let srcFmt = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
        if converter == nil {
            converter = AVAudioConverter(from: srcFmt, to: dstFmt)
        }
        guard let conv = converter else {
            recordProcessingFailure(NSError(
                domain: "SystemAudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Não foi possível criar o conversor do áudio do sistema."]
            ))
            return
        }

        let frameCount = AVAudioFrameCount(sb.numSamples)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frameCount) else {
            recordProcessingFailure(AudioConversionError.cannotAllocateOutputBuffer)
            return
        }
        srcBuf.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frameCount), into: srcBuf.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            recordProcessingFailure(NSError(
                domain: "SystemAudioRecorder",
                code: Int(copyStatus),
                userInfo: [NSLocalizedDescriptionKey: "Não foi possível copiar o PCM do áudio do sistema."]
            ))
            return
        }

        switch convertToInt16MonoResult(srcBuf, using: conv) {
        case .success(let data):
            appendConvertedPCM(data, hostTime: hostTime(for: sb.presentationTimeStamp))
        case .failure(let error):
            recordProcessingFailure(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordStreamStopError(error)
    }

    func recordStreamStopError(_ error: Error) {
        lock.withLock {
            if streamStopErrorDescription == nil {
                streamStopErrorDescription = error.localizedDescription
            }
        }
    }

    private func recordProcessingFailure(_ error: Error) {
        lock.withLock {
            if processingErrorDescription == nil {
                processingErrorDescription = error.localizedDescription
            }
        }
    }

    private func recordReceivedBuffer(presentationTime: CMTime) {
        lock.withLock {
            if firstBufferPresentationTimeStorage == nil {
                firstBufferPresentationTimeStorage = presentationTime
            }
            if firstBufferHostTimeStorage == nil,
               let firstPresentationTime = firstBufferPresentationTimeStorage {
                firstBufferHostTimeStorage = hostTimeLocked(for: firstPresentationTime)
            }
            lastReceivedBufferHostTime = hostTimeLocked(for: presentationTime)
            receivedBufferCount &+= 1
        }
    }

    private func appendConvertedPCM(_ data: Data, hostTime: UInt64?) {
        let gap = lock.withLock {
            PCMGapFiller.silenceBeforeBuffer(
                lastSuccessfulWriteHostTime: lastSuccessfulWriteHostTime,
                lastSuccessfulWriteByteCount: lastSuccessfulWriteByteCount,
                nextBufferHostTime: hostTime
            )
        }
        if !gap.silence.isEmpty {
            guard writer.append(gap.silence) else { return }
            lock.withLock {
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

    private func recordSuccessfulWrite(hostTime: UInt64?, byteCount: Int) {
        lock.withLock {
            lastSuccessfulWriteHostTime = hostTime
            lastSuccessfulWriteByteCount = byteCount
        }
    }

    private func hostTime(for presentationTime: CMTime) -> UInt64? {
        lock.withLock { hostTimeLocked(for: presentationTime) }
    }

    private func hostTimeLocked(for presentationTime: CMTime) -> UInt64? {
        guard presentationTime.isValid, let synchronizationClock else { return nil }
        let hostTime = CMSyncConvertTime(
            presentationTime,
            from: synchronizationClock,
            to: CMClockGetHostTimeClock()
        )
        guard hostTime.isValid else { return nil }
        return CMClockConvertHostTimeToSystemUnits(hostTime)
    }
}
