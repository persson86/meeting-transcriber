import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import MeetingTranscriber

/// Fallback AVCaptureSession sem hardware: fábrica primária e de fallback falsas,
/// relógio falso e fila de controle injetada (fakes em MicRecoveryTests.swift).
final class MicFallbackTests: XCTestCase {
    private var directory: URL!
    private var scheduler: FakeMicScheduler!
    private var controlQueue: DispatchQueue!
    private var primaries: [FakeCaptureEngine] = []
    private var fallbacks: [FakeCaptureEngine] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scheduler = FakeMicScheduler()
        controlQueue = DispatchQueue(label: "MicFallbackTests.control")
        primaries = []
        fallbacks = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecorder(writer: WAVWriter? = nil, withFallback: Bool = true) -> MicRecorder {
        let fallbackFactory: (() -> MicCaptureEngine)? = withFallback
            ? { [unowned self] in
                let engine = FakeCaptureEngine()
                engine.backendName = "captureSession"
                engine.inputDevice = MicInputDevice(name: "Fallback Mic", uid: "fallback-uid", transport: "built-in")
                self.fallbacks.append(engine)
                return engine
            }
            : nil
        return MicRecorder(
            writer: writer ?? WAVWriter(),
            engineFactory: { [unowned self] in
                let engine = FakeCaptureEngine()
                self.primaries.append(engine)
                return engine
            },
            fallbackEngineFactory: fallbackFactory,
            scheduler: scheduler,
            controlQueue: controlQueue
        )
    }

    // MARK: - Política de troca

    func testSwitchesToCaptureSessionAfterTwoSilentRebuildsAndStaysThere() throws {
        let recorder = makeRecorder()
        try recorder.start()
        XCTAssertEqual(recorder.health.captureBackend, "audioEngine")

        scheduler.advance(to: 4.0)   // stall → rebuild 1 (primário)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 1)
        XCTAssertEqual(primaries.count, 2)
        XCTAssertEqual(fallbacks.count, 0)

        scheduler.advance(to: 4.5)   // rebuild 2 (primário)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 2)
        XCTAssertEqual(primaries.count, 3)
        XCTAssertEqual(fallbacks.count, 0)
        XCTAssertEqual(recorder.health.captureBackend, "audioEngine")
        XCTAssertEqual(recorder.health.fallbackActivatedCount, 0)

        scheduler.advance(to: 5.5)   // rebuild 3 → fallback
        var health = recorder.health
        XCTAssertEqual(health.recoveryAttemptCount, 3)
        XCTAssertEqual(health.rebuildCount, 3)
        XCTAssertEqual(primaries.count, 3)
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertEqual(health.captureBackend, "captureSession")
        XCTAssertEqual(health.fallbackActivatedCount, 1)
        XCTAssertEqual(health.currentDeviceName, "Fallback Mic")
        XCTAssertEqual(primaries[2].removeTapCount, 1)
        XCTAssertEqual(primaries[2].stopCount, 1)
        XCTAssertEqual(fallbacks[0].startCount, 1)

        scheduler.advance(to: 7.5)   // fallback também mudo: backoff normal, sem voltar ao primário
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 4)
        XCTAssertEqual(primaries.count, 3)
        XCTAssertEqual(fallbacks.count, 2)

        scheduler.advance(to: 7.6)
        fallbacks.last?.emitBuffer(hostTimeSeconds: 7.6)
        health = recorder.health
        XCTAssertEqual(health.recoverySuccessCount, 1)
        XCTAssertEqual(health.captureBackend, "captureSession")
        XCTAssertFalse(health.isStalled)

        scheduler.advance(to: 11.0)  // novo stall depois do fallback funcionar: continua nele
        health = recorder.health
        XCTAssertEqual(health.recoveryAttemptCount, 5)
        XCTAssertEqual(primaries.count, 3)
        XCTAssertEqual(fallbacks.count, 3)
        XCTAssertEqual(health.fallbackActivatedCount, 1)
        XCTAssertEqual(health.captureBackend, "captureSession")
    }

    func testBufferBetweenRebuildsResetsTheSilentRebuildCounter() throws {
        let recorder = makeRecorder()
        try recorder.start()

        scheduler.advance(to: 4.0)   // rebuild 1
        XCTAssertEqual(primaries.count, 2)
        scheduler.advance(to: 4.2)
        primaries[1].emitBuffer(hostTimeSeconds: 4.2)   // buffer aceito zera a contagem

        scheduler.advance(to: 8.0)   // 3,8 s sem buffer → rebuild 2, mas conta como 1º sem buffer
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 2)
        XCTAssertEqual(primaries.count, 3)
        XCTAssertEqual(fallbacks.count, 0)

        scheduler.advance(to: 8.5)   // 2º sem buffer, ainda primário
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 3)
        XCTAssertEqual(primaries.count, 4)
        XCTAssertEqual(fallbacks.count, 0)
        XCTAssertEqual(recorder.health.captureBackend, "audioEngine")

        scheduler.advance(to: 9.5)   // 3º sem buffer → fallback
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 4)
        XCTAssertEqual(primaries.count, 4)
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertEqual(recorder.health.captureBackend, "captureSession")
        XCTAssertEqual(recorder.health.fallbackActivatedCount, 1)
    }

    func testWithoutFallbackFactoryKeepsRebuildingThePrimary() throws {
        let recorder = makeRecorder(withFallback: false)
        try recorder.start()

        scheduler.advance(to: 5.5)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 3)
        XCTAssertEqual(primaries.count, 4)
        XCTAssertEqual(fallbacks.count, 0)
        XCTAssertEqual(recorder.health.captureBackend, "audioEngine")
        XCTAssertEqual(recorder.health.fallbackActivatedCount, 0)
    }

    // MARK: - Stop e gerações no fallback

    func testStopDuringFallbackRetiresFallbackEngineAndSaves() throws {
        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: "mic.inprogress.wav")
        let recorder = makeRecorder(writer: writer)
        try recorder.start()
        primaries[0].emitBuffer(hostTimeSeconds: 0.1)

        scheduler.advance(to: 5.5)   // fallback ativo
        XCTAssertEqual(fallbacks.count, 1)
        scheduler.advance(to: 5.6)
        fallbacks[0].emitBuffer(hostTimeSeconds: 5.6)
        XCTAssertEqual(recorder.health.recoverySuccessCount, 1)
        let lateTap = fallbacks[0].tapBlock
        let bytesBeforeStop = Int(recorder.health.writtenByteCount)

        let output = directory.appendingPathComponent("mic.wav")
        try recorder.stop(saveTo: output)
        scheduler.advance(to: 30.0)

        XCTAssertEqual(fallbacks[0].removeTapCount, 1)
        XCTAssertEqual(fallbacks[0].stopCount, 1)
        XCTAssertEqual(fallbacks[0].handlerClearedCount, 1)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 3)
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertEqual(primaries.count, 3)
        XCTAssertEqual(try Data(contentsOf: output).count, 44 + bytesBeforeStop)

        lateTap?(FakeCaptureEngine.makeBuffer(), AVAudioTime(hostTime: hostTicks(6.0)))
        XCTAssertEqual(recorder.health.receivedBufferCount, 2)
        XCTAssertEqual(try Data(contentsOf: output).count, 44 + bytesBeforeStop)
    }

    func testPrimaryBuffersAreIgnoredAfterFallbackTakesOver() throws {
        let recorder = makeRecorder()
        try recorder.start()

        scheduler.advance(to: 4.5)
        XCTAssertEqual(primaries.count, 3)
        let stalePrimaryTap = primaries[2].tapBlock

        scheduler.advance(to: 5.5)
        XCTAssertEqual(fallbacks.count, 1)

        stalePrimaryTap?(FakeCaptureEngine.makeBuffer(), AVAudioTime(hostTime: hostTicks(5.6)))
        XCTAssertEqual(recorder.health.receivedBufferCount, 0)
        XCTAssertFalse(recorder.health.hasAudio)

        fallbacks[0].emitBuffer(hostTimeSeconds: 5.7)
        XCTAssertEqual(recorder.health.receivedBufferCount, 1)
        XCTAssertTrue(recorder.health.hasAudio)
    }

    // MARK: - Conversão de CMSampleBuffer

    func testMakesPCMBufferAndHostTimeFromSyntheticSampleBuffer() throws {
        let pts = CMTime(seconds: 2.0, preferredTimescale: 1_000_000_000)
        let sampleBuffer = try makeSampleBuffer(frames: 160, sampleRate: 16_000, value: 0.5, pts: pts)

        guard let pcm = CaptureSessionEngine.makePCMBuffer(from: sampleBuffer) else {
            return XCTFail("CMSampleBuffer sintético não virou AVAudioPCMBuffer")
        }
        XCTAssertEqual(pcm.frameLength, 160)
        XCTAssertEqual(pcm.format.sampleRate, 16_000)
        XCTAssertEqual(pcm.format.channelCount, 1)
        XCTAssertEqual(pcm.floatChannelData?[0][0], 0.5)
        XCTAssertEqual(pcm.floatChannelData?[0][159], 0.5)

        let expectedTicks = CMClockConvertHostTimeToSystemUnits(pts)
        XCTAssertEqual(CaptureSessionEngine.hostTicks(forPresentationTime: pts, sessionClock: nil), expectedTicks)
        XCTAssertEqual(
            CaptureSessionEngine.hostTicks(forPresentationTime: pts, sessionClock: CMClockGetHostTimeClock()),
            expectedTicks
        )
        XCTAssertNil(CaptureSessionEngine.hostTicks(forPresentationTime: .invalid, sessionClock: nil))

        // Mesmo pipeline do tap: o conversor por geração aceita o buffer do fallback.
        let converter = TapConverter(destination: AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        )!)
        guard case .success(let data) = converter.convert(pcm) else {
            return XCTFail("conversão do buffer do fallback falhou")
        }
        XCTAssertEqual(data.count, 320)
    }

    func testTransportNamesMapKnownCoreAudioCodes() {
        XCTAssertEqual(CaptureSessionEngine.transportName(Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)), "built-in")
        XCTAssertEqual(CaptureSessionEngine.transportName(Int32(bitPattern: kAudioDeviceTransportTypeVirtual)), "virtual")
        XCTAssertEqual(CaptureSessionEngine.transportName(Int32(bitPattern: kAudioDeviceTransportTypeUSB)), "usb")
        XCTAssertNil(CaptureSessionEngine.transportName(0))
    }

    // MARK: - Helpers

    private enum SampleBufferError: Error {
        case failed(String, OSStatus)
    }

    private func makeSampleBuffer(frames: Int, sampleRate: Double, value: Float, pts: CMTime) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw SampleBufferError.failed("format description", status)
        }

        let byteCount = frames * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw SampleBufferError.failed("block buffer", status)
        }
        status = CMBlockBufferAssureBlockMemory(blockBuffer)
        guard status == noErr else { throw SampleBufferError.failed("assure memory", status) }

        var samples = [Float](repeating: value, count: frames)
        status = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: UnsafeRawPointer(raw.baseAddress!),
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == noErr else { throw SampleBufferError.failed("replace bytes", status) }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw SampleBufferError.failed("sample buffer", status)
        }
        return sampleBuffer
    }
}
