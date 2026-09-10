import XCTest
@testable import MeetingTranscriber

@MainActor
final class SessionStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcriber-store-tests-\(UUID().uuidString)")
        store = SessionStore(rootDirectory: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testQueuedJobSurvivesReloadWithCaptureIntegrity() throws {
        let job = try makeJob(status: .queued, integrity: .degraded(["microfone interrompido"]))

        try store.save(job)
        let loaded = try XCTUnwrap(store.loadJobs().first)

        XCTAssertEqual(loaded.id, job.id)
        XCTAssertEqual(loaded.status, .queued)
        XCTAssertEqual(loaded.captureIntegrity, job.captureIntegrity)
        XCTAssertEqual(loaded.micURL, job.micURL)
    }

    func testRunningJobReturnsAsInterruptedInsteadOfStartingTwice() throws {
        try store.save(makeJob(status: .running))

        let loaded = try XCTUnwrap(store.loadJobs().first)

        guard case .failed(let message) = loaded.status else {
            return XCTFail("expected interrupted job to require retry")
        }
        XCTAssertTrue(message.contains("interrompido"))
    }

    func testInterruptedRecordingFinalizesInProgressAudioForRetry() throws {
        let id = UUID()
        let sessionDirectory = try store.prepareRecording(
            id: id,
            title: "Interrompida",
            language: "pt",
            outputDirectory: temporaryDirectory.appendingPathComponent("output"),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        do {
            let writer = WAVWriter(
                stagingDirectory: sessionDirectory,
                stagingFileName: "mic.inprogress.wav"
            )
            XCTAssertTrue(writer.append(Data([1, 0, 2, 0])))
        }

        let loaded = try XCTUnwrap(store.loadJobs().first)

        guard case .failed = loaded.status else { return XCTFail("expected interrupted failure") }
        let recovered = try XCTUnwrap(loaded.micURL)
        XCTAssertEqual(recovered.lastPathComponent, "mic.wav")
        XCTAssertEqual(try Data(contentsOf: recovered).count, 48)
        XCTAssertEqual(loaded.captureIntegrity.status, .degraded)
    }

    func testQueuedSessionAlsoRecoversInvisibleInProgressTrack() throws {
        let id = UUID()
        let sessionDirectory = store.sessionDirectory(for: id)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        do {
            let writer = WAVWriter(
                stagingDirectory: sessionDirectory,
                stagingFileName: "system.inprogress.wav"
            )
            XCTAssertTrue(writer.append(Data([1, 0, 2, 0])))
        }
        let job = TranscriptionJob(
            id: id,
            title: "Recuperação tardia",
            language: "pt",
            micURL: nil,
            systemURL: nil,
            outputDir: temporaryDirectory.appendingPathComponent("output"),
            sysOffsetMs: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            status: .queued
        )
        try store.save(job)

        let loaded = try XCTUnwrap(store.loadJobs().first)

        XCTAssertEqual(loaded.status, .queued)
        XCTAssertEqual(loaded.systemURL?.lastPathComponent, "system.wav")
        XCTAssertEqual(loaded.captureIntegrity.status, .degraded)
    }

    func testExclusiveLeaseRejectsSecondOwnerUntilRelease() throws {
        var first: SessionStoreLease? = try store.acquireExclusiveLease()

        XCTAssertThrowsError(try store.acquireExclusiveLease())

        first = nil
        XCTAssertNoThrow(try store.acquireExclusiveLease())
        XCTAssertNil(first)
    }

    func testSucceededJobWithMissingOutputBecomesRecoverableFailure() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing.md")
        try store.save(makeJob(status: .succeeded(missing)))

        let loaded = try XCTUnwrap(store.loadJobs().first)

        guard case .failed(let message) = loaded.status else {
            return XCTFail("expected missing output failure")
        }
        XCTAssertTrue(message.contains("não foi encontrada"))
        XCTAssertNotNil(loaded.micURL)
    }

    func testHidingJobRemovesItFromReloadWithoutDeletingAudio() throws {
        let job = try makeJob(status: .failed("erro"))
        try store.save(job)

        try store.hide(id: job.id)

        XCTAssertTrue(store.loadJobs().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(job.micURL).path))
    }

    private func makeJob(
        status: TranscriptionJobStatus,
        integrity: CaptureIntegrity = .complete
    ) throws -> TranscriptionJob {
        let id = UUID()
        let directory = store.sessionDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mic = directory.appendingPathComponent("mic.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: mic.path, contents: Data(repeating: 0, count: 48)))
        return TranscriptionJob(
            id: id,
            title: "Sessão de teste",
            language: "pt",
            micURL: mic,
            systemURL: nil,
            outputDir: temporaryDirectory.appendingPathComponent("output"),
            sysOffsetMs: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            startedAt: nil,
            completedAt: nil,
            status: status,
            captureIntegrity: integrity
        )
    }
}
