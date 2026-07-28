import AVFoundation
import ScreenCaptureKit
import Foundation

final class SystemAudioRecorder: @unchecked Sendable {
    private var stream: SCStream?
    private let delegate: SysDelegate
    private let writer = WAVWriter()

    /// Mach absolute time do primeiro buffer recebido. Usado para calcular offset entre trilhas.
    var firstBufferTime: UInt64? { delegate.firstBufferTime }

    init() {
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
        if #available(macOS 15, *) {
            config.captureMicrophone = false
        }
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .audio,
                                   sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop(saveTo url: URL) async throws {
        // stopCapture() throws if the stream already died mid-recording (e.g. the
        // OS tears it down after dropped frames). That's a signal, not a reason to
        // discard whatever the writer already buffered — best-effort stop, then
        // always try to save.
        try? await stream?.stopCapture()
        stream = nil
        if !writer.isEmpty {
            try writer.save(to: url)
        }
    }
}

// MARK: - SCStream delegate

private final class SysDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: WAVWriter
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private(set) var firstBufferTime: UInt64?

    init(writer: WAVWriter) { self.writer = writer; super.init() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let fmtDesc = sb.formatDescription else { return }

        if firstBufferTime == nil {
            firstBufferTime = mach_absolute_time()
        }

        let srcFmt = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
        if converter == nil {
            converter = AVAudioConverter(from: srcFmt, to: dstFmt)
        }
        guard let conv = converter else { return }

        let frameCount = AVAudioFrameCount(sb.numSamples)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frameCount) else { return }
        srcBuf.frameLength = frameCount

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frameCount), into: srcBuf.mutableAudioBufferList
        ) == noErr else { return }

        if let data = convertToInt16Mono(srcBuf, using: conv) {
            writer.append(data)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream stopped unexpectedly — recording will still be saved on stop()
    }
}
