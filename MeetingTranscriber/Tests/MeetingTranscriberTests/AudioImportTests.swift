import AVFoundation
import Foundation
import XCTest
@testable import MeetingTranscriber

/// Importação de gravações do iPhone (m4a/AAC, 44,1 kHz estéreo) e de WAV em
/// outra taxa: o pipeline só lê WAV 16 kHz Int16.
final class AudioImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testM4AStereoBecomes16kMonoWAVWithSameDuration() throws {
        let source = directory.appendingPathComponent("gravacao.m4a")
        try writeTone(to: source, seconds: 3, sampleRate: 44_100, channels: 2, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
        ])
        let output = directory.appendingPathComponent("mic.wav")

        try transcodeAudioFileToWAV16kMono(from: source, to: output)

        try assertPipelineWAV(output, expectedSeconds: 3)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("mic.importing.wav").path))
    }

    func testWAVAt48kIsResampled() throws {
        let source = directory.appendingPathComponent("gravacao.wav")
        try writeTone(to: source, seconds: 2, sampleRate: 48_000, channels: 1, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let output = directory.appendingPathComponent("mic.wav")

        try transcodeAudioFileToWAV16kMono(from: source, to: output)

        try assertPipelineWAV(output, expectedSeconds: 2)
    }

    func testNonAudioFileFailsWithoutLeavingOutput() throws {
        let source = directory.appendingPathComponent("nota.m4a")
        try Data("não é áudio".utf8).write(to: source)
        let output = directory.appendingPathComponent("mic.wav")

        XCTAssertThrowsError(try transcodeAudioFileToWAV16kMono(from: source, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Helpers

    private func writeTone(
        to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
        settings: [String: Any]
    ) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) {
                data[channel][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    /// Mesmo contrato do `load_audio` do pipeline: 16 kHz, mono, Int16, com sinal.
    private func assertPipelineWAV(_ url: URL, expectedSeconds: Double) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        let seconds = Double(file.length) / format.sampleRate
        // AAC acrescenta priming/padding de alguns ms.
        XCTAssertEqual(seconds, expectedSeconds, accuracy: 0.1)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertTrue(pcmHasSignal(data.dropFirst(44)))
    }
}
