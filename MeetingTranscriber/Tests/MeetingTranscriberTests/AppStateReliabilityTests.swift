import XCTest
@testable import MeetingTranscriber

@MainActor
final class AppStateReliabilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-reliability-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStartingStatePreventsReentrantRecording() {
        XCTAssertFalse(RecordingStatus.starting.canStartRecording)
        XCTAssertTrue(RecordingStatus.starting.isBusy)
    }

    func testDurationIntegrityFindsOneTruncatedTrack() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 1)
        let system = try writeWAV(name: "system.wav", seconds: 60)

        let issues = AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60
        )

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("microfone"))
    }

    func testDurationIntegrityFindsBothTracksStoppedEarly() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 1)
        let system = try writeWAV(name: "system.wav", seconds: 1)

        let issues = AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60
        )

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("duas trilhas"))
    }

    func testDurationIntegrityAllowsSmallFinalizeDifference() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 60)
        let system = try writeWAV(name: "system.wav", seconds: 59)

        XCTAssertTrue(AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60
        ).isEmpty)
    }

    func testDurationIntegrityAccountsForTrackStartOffset() throws {
        let mic = try writeWAV(name: "mic.wav", seconds: 60)
        let system = try writeWAV(name: "system.wav", seconds: 50)

        XCTAssertTrue(AppState.durationIntegrityIssues(
            micURL: mic,
            systemURL: system,
            sessionDuration: 60,
            sysOffsetMs: 10_000
        ).isEmpty)
    }

    func testHealthIssuesExposeWriterRearmAndStreamFailures() {
        let mic = AudioCaptureHealth(
            receivedBufferCount: 2,
            writtenByteCount: 10,
            firstBufferHostTime: 1,
            lastBufferHostTime: 2,
            firstErrorDescription: "disco cheio",
            recoveryAttemptCount: 1,
            recoveryErrorDescription: "rearm falhou",
            streamStopErrorDescription: nil
        )
        let system = AudioCaptureHealth(
            receivedBufferCount: 2,
            writtenByteCount: 10,
            firstBufferHostTime: 1,
            lastBufferHostTime: 2,
            firstErrorDescription: nil,
            recoveryAttemptCount: 0,
            recoveryErrorDescription: nil,
            streamStopErrorDescription: "stream morreu"
        )

        let issues = AppState.healthIssues(mic: mic, system: system)

        XCTAssertEqual(issues.count, 3)
        XCTAssertTrue(issues.contains { $0.contains("disco cheio") })
        XCTAssertTrue(issues.contains { $0.contains("rearm falhou") })
        XCTAssertTrue(issues.contains { $0.contains("stream morreu") })
    }

    func testHealthIssuesExposeMaterialTimelineGap() {
        let mic = AudioCaptureHealth(
            receivedBufferCount: 2,
            writtenByteCount: 64_000,
            firstBufferHostTime: 1,
            lastBufferHostTime: 2,
            firstErrorDescription: nil,
            recoveryAttemptCount: 0,
            recoveryErrorDescription: nil,
            streamStopErrorDescription: nil,
            insertedSilenceByteCount: 32_002
        )

        let issues = AppState.healthIssues(mic: mic, system: nil)

        XCTAssertTrue(issues.contains { $0.contains("silêncio foi inserido") })
    }

    private func writeWAV(name: String, seconds: Int) throws -> URL {
        let output = directory.appendingPathComponent(name)
        let writer = WAVWriter()
        XCTAssertTrue(writer.append(Data(repeating: 0, count: seconds * 16_000 * 2)))
        try writer.save(to: output)
        return output
    }
}
