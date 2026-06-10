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
        u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        h += "data".data(using: .ascii)!
        u32(size)

        // .atomic: ou o WAV completo aparece no disco, ou nada — nunca arquivo parcial
        try (h + pcm).write(to: url, options: .atomic)
    }

    var isEmpty: Bool { lock.withLock { pcm.isEmpty } }
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
