// Protótipo (Astra, 07/out/2026): cliente HAL direto no mic embutido, fora do
// AVAudioEngine. Experimental: `defaults write io.github.meetingtranscriber.app micCaptureBackend raw`.
import Foundation
import CoreAudio
import AVFoundation

final class RawMicCapture: @unchecked Sendable {
    typealias PCMHandler = @Sendable (Data, UInt64?) -> Void
    private let uid: String
    private let queue = DispatchQueue(label: "RawMicCapture.IO")
    private let lifecycle = NSLock()
    private let state: State
    private var device = AudioDeviceID(0)
    private var proc: AudioDeviceIOProcID?

    init(uid: String,
         onBuffer: @escaping @Sendable (UInt64?) -> Bool = { _ in true },
         onPCM: @escaping PCMHandler,
         onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.uid = uid
        state = State(onBuffer, onPCM, onError)
    }

    var counts: (callbacks: UInt64, errors: UInt64) {
        queue.sync { (state.callbacks, state.errors) }
    }
    var isRunning: Bool { queue.sync { state.enabled } }
    var inputFormat: AVAudioFormat? { queue.sync { state.native } }

    func start() throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        lifecycle.lock()
        defer { lifecycle.unlock() }
        do {
            guard proc == nil else { throw Self.failure("IOProc ainda existente") }
            device = try Self.resolve(uid)
            var asbd = AudioStreamBasicDescription()
            try Self.read(device, kAudioDevicePropertyStreamFormat,
                          kAudioDevicePropertyScopeInput, &asbd)
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  asbd.mBitsPerChannel == 32, asbd.mFramesPerPacket == 1,
                  asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
                  asbd.mChannelsPerFrame > 0,
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: asbd.mSampleRate, channels: 1, interleaved: false),
                  let dst = AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: 16_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: mono, to: dst)
            else {
                // Visto em 07/out: outro processo com voice processing muda o formato
                // do embutido e o rearme raw passa a cair aqui.
                throw Self.failure(String(format: "Formato nativo não suportado (%.0f Hz, fmt %08x, flags %08x, %d ch, %d bits)",
                                          asbd.mSampleRate, asbd.mFormatID, asbd.mFormatFlags,
                                          asbd.mChannelsPerFrame, asbd.mBitsPerChannel))
            }
            converter.primeMethod = .none
            // Só para relatório: com 3 canais (voice processing de outro processo,
            // 07/out) `AVAudioFormat(streamDescription:)` devolve nil sem layout;
            // o consumo usa a contagem de canais, não este objeto.
            let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let native = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                       channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                                       interleaved: interleaved) ?? mono
            let nativeChannels = Int(asbd.mChannelsPerFrame)
            queue.sync {
                state.native = native; state.nativeChannels = nativeChannels; state.mono = mono
                state.dst = dst; state.converter = converter
            }
            let captured = state
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(
                &proc, device, queue
            ) { _, input, inputTime, _, _ in
                captured.consume(input, inputTime.pointee)
            }, "CreateIOProc")
            queue.sync { state.enabled = true }
            do {
                try Self.check(AudioDeviceStart(device, proc), "Start")
            } catch {
                let original = error
                do { try close() }
                catch { queue.sync { state.report(error) } }
                throw original
            }
        } catch {
            queue.sync { state.report(error) }
            throw error
        }
    }

    func stop() throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        lifecycle.lock()
        defer { lifecycle.unlock() }
        do { try close() }
        catch {
            queue.sync { state.report(error) }
            throw error
        }
    }

    private func close() throws {
        queue.sync { state.enabled = false }
        guard let proc else { return }
        let stopped = AudioDeviceStop(device, proc)
        let destroyed = AudioDeviceDestroyIOProcID(device, proc)
        if destroyed == noErr { self.proc = nil }
        queue.sync {}
        guard stopped == noErr, destroyed == noErr else {
            throw Self.failure("Stop=\(stopped); DestroyIOProc=\(destroyed)")
        }
    }

    deinit { try? stop() }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "RawMicCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw failure("\(operation): \(status)") }
    }
    private static func read<T>(_ object: AudioObjectID,
                                _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope,
                                _ value: inout T) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "Read \(selector)")
    }
    private static func resolve(_ value: String) throws -> AudioDeviceID {
        var uid = value as CFString
        var id = AudioDeviceID(0)
        try withUnsafeMutablePointer(to: &uid) { source in
            try withUnsafeMutablePointer(to: &id) { destination in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(source),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(destination),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size))
                try read(AudioObjectID(kAudioObjectSystemObject),
                         kAudioHardwarePropertyDeviceForUID,
                         kAudioObjectPropertyScopeGlobal, &translation)
            }
        }
        guard id != kAudioObjectUnknown else { throw failure("UID indisponível") }
        return id
    }

    private final class State: @unchecked Sendable {
        var enabled = false
        var callbacks: UInt64 = 0, errors: UInt64 = 0
        var native: AVAudioFormat?, mono: AVAudioFormat?, dst: AVAudioFormat?
        var nativeChannels = 0
        var converter: AVAudioConverter?
        /// Diagnóstico: `-micRawDump <caminho>` grava os floats mono nativos antes da conversão.
        let dump: FileHandle? = UserDefaults.standard.string(forKey: "micRawDump").flatMap {
            FileManager.default.createFile(atPath: $0, contents: nil); return FileHandle(forWritingAtPath: $0)
        }
        let received: @Sendable (UInt64?) -> Bool
        let deliver: PCMHandler
        let failed: @Sendable (Error) -> Void
        init(_ received: @escaping @Sendable (UInt64?) -> Bool,
             _ deliver: @escaping PCMHandler,
             _ failed: @escaping @Sendable (Error) -> Void) {
            self.received = received; self.deliver = deliver; self.failed = failed
        }
        func report(_ error: Error) { errors &+= 1; failed(error) }
        func consume(_ input: UnsafePointer<AudioBufferList>, _ time: AudioTimeStamp) {
            callbacks &+= 1
            guard enabled else { return }
            let host: UInt64? = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil
            guard received(host) else { return }
            do {
                guard let mono, let dst, let converter else {
                    throw RawMicCapture.failure("Conversor indisponível")
                }
                let buffers = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: input))
                let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
                guard channels == nativeChannels, let first = buffers.first,
                      first.mNumberChannels > 0 else {
                    throw RawMicCapture.failure("Layout de entrada mudou")
                }
                let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
                guard frames > 0 else { return }
                guard frames <= 1_048_576,
                      let source = AVAudioPCMBuffer(pcmFormat: mono,
                          frameCapacity: AVAudioFrameCount(frames)) else {
                    throw RawMicCapture.failure("Buffer de entrada inválido")
                }
                source.frameLength = AVAudioFrameCount(frames)
                let samples = source.floatChannelData![0]
                for frame in 0..<frames { samples[frame] = 0 }
                for buffer in buffers {
                    let count = Int(buffer.mNumberChannels)
                    guard count > 0, Int(buffer.mDataByteSize) == frames * count * 4,
                          let data = buffer.mData else {
                        throw RawMicCapture.failure("AudioBuffer incompatível")
                    }
                    let floats = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        for channel in 0..<count {
                            samples[frame] += floats[frame * count + channel] / Float(channels)
                        }
                    }
                }
                dump?.write(Data(bytes: samples, count: frames * 4))
                guard let output = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 4096)
                else { throw RawMicCapture.failure("Sem buffer de saída") }
                var cursor = 0, pcm = Data()
                while true {
                    var error: NSError?, allocationFailed = false
                    let status = converter.convert(to: output, error: &error) { requested, flag in
                        let n = min(Int(requested), frames - cursor)
                        guard n > 0 else { flag.pointee = .noDataNow; return nil }
                        guard let chunk = AVAudioPCMBuffer(pcmFormat: mono,
                            frameCapacity: AVAudioFrameCount(n)) else {
                            allocationFailed = true; flag.pointee = .noDataNow; return nil
                        }
                        chunk.frameLength = AVAudioFrameCount(n)
                        chunk.floatChannelData![0].update(from: samples + cursor, count: n)
                        cursor += n; flag.pointee = .haveData; return chunk
                    }
                    if let error { throw error }
                    guard status != .error, !allocationFailed else {
                        throw RawMicCapture.failure("Conversão falhou")
                    }
                    pcm.append(Data(bytes: output.int16ChannelData![0],
                                    count: Int(output.frameLength) * 2))
                    if status != .haveData { break }
                    guard output.frameLength > 0 else {
                        throw RawMicCapture.failure("Conversor sem progresso")
                    }
                }
                if !pcm.isEmpty { deliver(pcm, host) }
            } catch { report(error) }
        }
    }
}
