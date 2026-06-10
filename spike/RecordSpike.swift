// RecordSpike.swift — Spike de captura de áudio (mic + sistema) para meeting-transcriber
// Compile: swiftc RecordSpike.swift -framework ScreenCaptureKit -framework AVFoundation -strict-concurrency=minimal -o RecordSpike
// Usage:   ./RecordSpike <duration_seconds>
// Needs:   Microphone + Screen Recording permissions granted to Terminal in System Settings

import AVFoundation
import ScreenCaptureKit
import Foundation

// MARK: - NSLock helper

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

// MARK: - WAV writer (thread-safe, 16kHz mono Int16)

final class WAVWriter: @unchecked Sendable {
    private var pcm = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.withLock { pcm.append(data) }
    }

    func save(to url: URL) throws {
        let size = UInt32(pcm.count)
        var h = Data()

        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }

        h += "RIFF".data(using: .ascii)!
        u32(36 + size)
        h += "WAVEfmt ".data(using: .ascii)!
        u32(16); u16(1); u16(1)            // chunk size, PCM, 1 channel
        u32(16000); u32(32000); u16(2); u16(16)  // sampleRate, byteRate, blockAlign, bitsPerSample
        h += "data".data(using: .ascii)!
        u32(size)

        try (h + pcm).write(to: url)

        let secs = pcm.count / 32000
        let kb = pcm.count / 1024
        print("  \(url.lastPathComponent): \(secs)s, \(kb) KB")
    }
}

// MARK: - Format conversion: AVAudioPCMBuffer → Int16 mono 16kHz data

func convertToInt16Mono(_ input: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data? {
    let ratio = 16000.0 / input.format.sampleRate
    let outFrames = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outFrames) else { return nil }

    var inputDone = false
    let inputRef = input
    var convError: NSError?

    converter.convert(to: outBuf, error: &convError) { _, status in
        if inputDone { status.pointee = .noDataNow; return nil }
        inputDone = true
        status.pointee = .haveData
        return inputRef
    }

    if let err = convError { print("  Converter error: \(err.localizedDescription)"); return nil }
    guard let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 else { return nil }
    return Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2)
}

// MARK: - Mic recorder

func startMicRecorder(writer: WAVWriter) throws -> (stop: () -> Void, firstMachTime: () -> UInt64) {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let srcFmt = inputNode.outputFormat(forBus: 0)
    let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
        throw NSError(domain: "RecordSpike", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create mic converter from \(srcFmt)"])
    }

    var firstTime: UInt64 = 0
    let timeLock = NSLock()

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: srcFmt) { buf, _ in
        timeLock.withLock { if firstTime == 0 { firstTime = mach_absolute_time() } }
        if let data = convertToInt16Mono(buf, converter: converter) { writer.append(data) }
    }

    try engine.start()
    print("  Mic started (src: \(Int(srcFmt.sampleRate))Hz \(srcFmt.channelCount)ch)")

    return (
        stop: { engine.stop() },
        firstMachTime: { timeLock.withLock { firstTime } }
    )
}

// MARK: - System audio capture (SCStream delegate)

final class SysAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: WAVWriter
    private let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var firstTime: UInt64 = 0
    private let lock = NSLock()

    init(writer: WAVWriter) { self.writer = writer; super.init() }

    var firstMachTime: UInt64 { lock.withLock { firstTime } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let fmtDesc = sb.formatDescription else { return }

        lock.withLock { if firstTime == 0 { firstTime = mach_absolute_time() } }

        let srcFmt = AVAudioFormat(cmAudioFormatDescription: fmtDesc)

        if converter == nil {
            guard let conv = AVAudioConverter(from: srcFmt, to: dstFmt) else {
                print("  Cannot create system audio converter from \(srcFmt)")
                return
            }
            converter = conv
            print("  Sys audio format: \(Int(srcFmt.sampleRate))Hz \(srcFmt.channelCount)ch")
        }

        let frameCount = AVAudioFrameCount(sb.numSamples)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frameCount) else { return }
        srcBuf.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0,
                                                                   frameCount: Int32(frameCount),
                                                                   into: srcBuf.mutableAudioBufferList)
        guard status == noErr else { return }

        if let data = convertToInt16Mono(srcBuf, converter: converter!) {
            writer.append(data)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("  SCStream stopped: \(error.localizedDescription)")
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 2, let duration = Double(args[1]), duration > 0 else {
    fputs("Usage: RecordSpike <duration_seconds>\nexample: ./RecordSpike 30\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: "/tmp/meeting-spike")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let micWriter = WAVWriter()
let sysWriter = WAVWriter()
let anchorMachTime = mach_absolute_time()

print("=== RecordSpike — \(Int(duration))s ===")
print("Anchor: \(anchorMachTime) Mach units")
print("Output: /tmp/meeting-spike/\n")

let done = DispatchSemaphore(value: 0)

Task {
    do {
        // 1. Start mic
        print("[1] Starting mic recorder...")
        let (stopMic, micFirstTime) = try startMicRecorder(writer: micWriter)

        // 2. Enumerate display content for system audio
        print("[2] Requesting screen content for system audio...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw NSError(domain: "RecordSpike", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        // 3. Configure SCStream for audio only
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        // Request 48kHz stereo — we convert to 16kHz mono in the delegate
        config.sampleRate = 48000
        config.channelCount = 2
        // Minimal video to satisfy SCStream requirement (audio-only mode not available pre-macOS 15)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // max 1fps video
        config.showsCursor = false

        let sysCapture = SysAudioCapture(writer: sysWriter)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: sysCapture)
        try stream.addStreamOutput(sysCapture, type: .audio,
                                   sampleHandlerQueue: .global(qos: .userInteractive))

        // 4. Start system stream
        print("[3] Starting system audio stream...")
        try await stream.startCapture()
        print("    SCStream started\n")

        print(">>> Recording \(Int(duration))s — speak and play audio now <<<\n")

        // 5. Wait
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        // 6. Stop
        print("\n[4] Stopping streams...")
        try await stream.stopCapture()
        stopMic()

        // 7. Report timing
        let mf = micFirstTime()
        let sf = sysCapture.firstMachTime
        print("\nTiming (Mach units after anchor):")
        print("  mic first buffer: +\(mf >= anchorMachTime ? mf - anchorMachTime : 0)")
        print("  sys first buffer: +\(sf >= anchorMachTime ? sf - anchorMachTime : 0)")

        // Approximate drift in milliseconds (assuming 1 Mach unit ≈ 1ns on M-series, but convert properly)
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let micOffsetNs = mf >= anchorMachTime ? (mf - anchorMachTime) * UInt64(info.numer) / UInt64(info.denom) : 0
        let sysOffsetNs = sf >= anchorMachTime ? (sf - anchorMachTime) * UInt64(info.numer) / UInt64(info.denom) : 0
        let driftMs = Int64(micOffsetNs) - Int64(sysOffsetNs)
        print("  drift (mic - sys): \(driftMs / 1_000_000) ms")

        // 8. Save WAVs
        print("\n[5] Saving WAV files...")
        try micWriter.save(to: outputDir.appendingPathComponent("mic.wav"))
        try sysWriter.save(to: outputDir.appendingPathComponent("system.wav"))
        print("\nDone. Verify with:")
        print("  afplay /tmp/meeting-spike/mic.wav")
        print("  afplay /tmp/meeting-spike/system.wav")

        done.signal()

    } catch {
        print("\nError: \(error.localizedDescription)")
        done.signal()
    }
}

done.wait()
