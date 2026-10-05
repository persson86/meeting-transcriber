import Foundation
import CoreMedia
import XCTest
@testable import MeetingTranscriber

final class AudioCaptureReliabilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTranscriberTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWriterSavesHeaderAndHealth() throws {
        let output = directory.appendingPathComponent("mic.wav")
        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: "mic.inprogress.wav")

        XCTAssertTrue(writer.append(Data([1, 0, 2, 0])))
        XCTAssertEqual(writer.health.byteCount, 4)
        XCTAssertEqual(writer.health.appendCount, 1)
        XCTAssertNil(writer.health.firstErrorDescription)

        try writer.save(to: output)

        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.count, 48)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(littleEndianUInt32(data, at: 40), 4)
        XCTAssertNil(writer.recoverableTemporaryURL)
    }

    func testFinalizesNamedInProgressFileAfterAbruptEnd() throws {
        let source = directory.appendingPathComponent("system.inprogress.wav")
        let output = directory.appendingPathComponent("system.wav")

        do {
            let writer = WAVWriter(stagingDirectory: directory, stagingFileName: source.lastPathComponent)
            XCTAssertTrue(writer.append(Data([3, 0, 4, 0, 5, 0])))
            XCTAssertEqual(writer.recoverableTemporaryURL, source)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try WAVWriter.finalizeInProgressFile(at: source, to: output)

        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.count, 50)
        XCTAssertEqual(littleEndianUInt32(data, at: 40), 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testWriterKeepsFirstWriteErrorVisible() throws {
        let notADirectory = directory.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: notADirectory.path, contents: Data()))
        let writer = WAVWriter(stagingDirectory: notADirectory, stagingFileName: "mic.inprogress.wav")

        XCTAssertFalse(writer.append(Data([1, 0])))
        XCTAssertEqual(writer.health.byteCount, 0)
        XCTAssertEqual(writer.health.appendCount, 0)
        XCTAssertNotNil(writer.health.firstErrorDescription)
        XCTAssertThrowsError(try writer.save(to: directory.appendingPathComponent("mic.wav")))
    }

    func testWriterKeepsFinalizationErrorAndStagedAudio() throws {
        let source = directory.appendingPathComponent("mic.inprogress.wav")
        let output = directory.appendingPathComponent("mic.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: Data([9])))
        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: source.lastPathComponent)

        XCTAssertTrue(writer.append(Data([1, 0])))
        XCTAssertThrowsError(try writer.save(to: output))

        XCTAssertNotNil(writer.health.firstErrorDescription)
        XCTAssertEqual(writer.recoverableTemporaryURL, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: output), Data([9]))
    }

    func testMicHealthTracksBuffersAndRearmFailureWithoutHardware() {
        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: "mic.inprogress.wav")
        let recorder = MicRecorder(writer: writer)

        recorder.recordReceivedBuffer(hostTime: 100)
        recorder.recordReceivedBuffer(hostTime: 140)
        recorder.recordRearmFailure(TestError.rearm)

        XCTAssertEqual(recorder.firstBufferTime, 100)
        XCTAssertEqual(recorder.health.receivedBufferCount, 2)
        XCTAssertEqual(recorder.health.firstBufferHostTime, 100)
        XCTAssertEqual(recorder.health.lastReceivedBufferHostTime, 140)
        XCTAssertNil(recorder.health.lastBufferHostTime)
        XCTAssertEqual(recorder.health.recoveryAttemptCount, 0)
        XCTAssertEqual(recorder.health.recoveryErrorDescription, TestError.rearm.localizedDescription)
        XCTAssertFalse(recorder.health.hasAudio)
    }

    func testGapFillerPreservesTenSecondTimelineInWAV() throws {
        let firstTime = hostTime(seconds: 0)
        let secondTime = hostTime(seconds: 10)
        let first = Data([1, 0])
        let second = Data([2, 0])
        let gap = PCMGapFiller.silenceBeforeBuffer(
            lastSuccessfulWriteHostTime: firstTime,
            lastSuccessfulWriteByteCount: first.count,
            nextBufferHostTime: secondTime
        )

        XCTAssertFalse(gap.isEmpty)
        XCTAssertFalse(gap.wasCapped)
        let writer = WAVWriter(stagingDirectory: directory, stagingFileName: "gap.inprogress.wav")
        XCTAssertTrue(writer.append(first))
        XCTAssertTrue(writer.appendSilence(byteCount: gap.byteCount))
        XCTAssertTrue(writer.append(second))
        let output = directory.appendingPathComponent("gap.wav")
        try writer.save(to: output)

        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.count, 44 + first.count + gap.byteCount + second.count)
        XCTAssertEqual(Double(data.count - 44) / Double(PCMGapFiller.bytesPerSecond), 10, accuracy: 0.01)
        XCTAssertEqual(data[44], 1)
        XCTAssertEqual(data[44 + first.count + gap.byteCount], 2)
    }

    func testGapFillerCapsUnboundedSilence() {
        let gap = PCMGapFiller.silenceBeforeBuffer(
            lastSuccessfulWriteHostTime: hostTime(seconds: 0),
            lastSuccessfulWriteByteCount: 0,
            nextBufferHostTime: hostTime(seconds: PCMGapFiller.maxSilenceSeconds + 1)
        )

        XCTAssertTrue(gap.wasCapped)
        XCTAssertEqual(gap.byteCount, Int(PCMGapFiller.maxSilenceSeconds) * PCMGapFiller.bytesPerSecond)
    }

    func testHealthDistinguishesReceivedCallbackFromSuccessfulWrite() {
        let recorder = MicRecorder(writer: WAVWriter())
        recorder.recordReceivedBuffer(hostTime: 100)
        recorder.recordProcessingFailure(TestError.conversion)

        XCTAssertEqual(recorder.health.lastReceivedBufferHostTime, 100)
        XCTAssertNil(recorder.health.lastSuccessfulWriteHostTime)
        XCTAssertNil(recorder.health.lastBufferHostTime)
        XCTAssertEqual(recorder.health.firstErrorDescription, TestError.conversion.localizedDescription)

        recorder.recordSuccessfulWrite(hostTime: 120, byteCount: 2)
        XCTAssertEqual(recorder.health.lastSuccessfulWriteHostTime, 120)
        XCTAssertEqual(recorder.health.lastBufferHostTime, 120)
    }

    func testSilentCallbacksDoNotReportSignalOrRecovery() {
        let recorder = MicRecorder(writer: WAVWriter())
        recorder.recordRecoveryAttempt()
        recorder.recordReceivedBuffer(hostTime: 100)
        recorder.appendConvertedPCM(Data(count: 2_048), hostTime: 100)

        XCTAssertEqual(recorder.health.receivedBufferCount, 1)
        XCTAssertEqual(recorder.health.writtenByteCount, 2_048)
        XCTAssertNil(recorder.health.firstSignalHostTime)
        XCTAssertNil(recorder.health.lastSignalHostTime)
        XCTAssertNil(recorder.health.initialAudioDelaySeconds)
        XCTAssertTrue(recorder.health.recoveryPending)
        XCTAssertFalse(recorder.health.events.contains { $0.contains("áudio com sinal chegando") })

        recorder.recordReceivedBuffer(hostTime: 200)
        recorder.appendConvertedPCM(Data([1, 0]), hostTime: 200)
        XCTAssertEqual(recorder.health.firstSignalHostTime, 200)
        XCTAssertEqual(recorder.health.lastSignalHostTime, 200)
        XCTAssertNotNil(recorder.health.initialAudioDelaySeconds)
        XCTAssertFalse(recorder.health.recoveryPending)
        XCTAssertEqual(recorder.health.events.filter { $0.contains("áudio com sinal chegando") }.count, 1)
    }

    func testFailedPCMWriteDoesNotCountAsCapturedSignal() throws {
        let notADirectory = directory.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: notADirectory.path, contents: Data()))
        let writer = WAVWriter(stagingDirectory: notADirectory, stagingFileName: "mic.inprogress.wav")
        let recorder = MicRecorder(writer: writer)
        recorder.recordRecoveryAttempt()
        recorder.recordReceivedBuffer(hostTime: 100)
        recorder.appendConvertedPCM(Data([1, 0]), hostTime: 100)

        XCTAssertNil(recorder.health.firstSignalHostTime)
        XCTAssertNil(recorder.health.lastSignalHostTime)
        XCTAssertNil(recorder.health.lastSuccessfulWriteHostTime)
        XCTAssertNotNil(recorder.health.firstErrorDescription)
        XCTAssertTrue(recorder.health.recoveryPending)
    }

    func testPreviousTapCannotWriteOrConfirmNewRecovery() {
        let recorder = MicRecorder(writer: WAVWriter())
        let oldGeneration = recorder.beginTapGeneration()
        XCTAssertTrue(recorder.recordReceivedBuffer(hostTime: 100, generation: oldGeneration))
        recorder.appendConvertedPCM(Data([1, 0]), hostTime: 100, generation: oldGeneration)

        recorder.recordRecoveryAttempt()
        let newGeneration = recorder.beginTapGeneration()
        let beforeLateCallback = recorder.health

        // Simula o resultado de uma conversão antiga que terminou depois do
        // rearme, além de outro callback já enfileirado no tap antigo.
        recorder.appendConvertedPCM(Data([9, 0]), hostTime: hostTime(seconds: 10), generation: oldGeneration)
        XCTAssertFalse(recorder.recordReceivedBuffer(hostTime: 300, generation: oldGeneration))
        recorder.recordProcessingFailure(TestError.conversion, generation: oldGeneration)
        XCTAssertEqual(recorder.health, beforeLateCallback)
        XCTAssertTrue(recorder.health.recoveryPending)

        XCTAssertTrue(recorder.recordReceivedBuffer(hostTime: 140, generation: newGeneration))
        recorder.appendConvertedPCM(Data([0, 0]), hostTime: 140, generation: newGeneration)
        XCTAssertTrue(recorder.health.recoveryPending)
        XCTAssertEqual(recorder.health.lastSignalHostTime, 100)

        XCTAssertTrue(recorder.recordReceivedBuffer(hostTime: 180, generation: newGeneration))
        recorder.appendConvertedPCM(Data([2, 0]), hostTime: 180, generation: newGeneration)
        XCTAssertFalse(recorder.health.recoveryPending)
        XCTAssertEqual(recorder.health.firstSignalHostTime, 100)
        XCTAssertEqual(recorder.health.lastSignalHostTime, 180)
        XCTAssertEqual(recorder.health.writtenByteCount, 6)
        XCTAssertEqual(recorder.health.receivedBufferCount, 3)
    }

    func testSystemHealthTracksUnexpectedStopWithoutCapturePermission() {
        let recorder = SystemAudioRecorder(
            stagingDirectory: directory,
            stagingFileName: "system.inprogress.wav"
        )

        recorder.recordStreamStopError(TestError.streamStopped)

        XCTAssertEqual(recorder.health.receivedBufferCount, 0)
        XCTAssertEqual(recorder.health.streamStopErrorDescription, TestError.streamStopped.localizedDescription)
        XCTAssertFalse(recorder.health.hasAudio)
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
    }

    private func hostTime(seconds: Double) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(
            CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        )
    }

    private enum TestError: LocalizedError {
        case rearm
        case streamStopped
        case conversion

        var errorDescription: String? {
            switch self {
            case .rearm: return "rearm falhou"
            case .streamStopped: return "stream parou"
            case .conversion: return "conversão falhou"
            }
        }
    }
}
