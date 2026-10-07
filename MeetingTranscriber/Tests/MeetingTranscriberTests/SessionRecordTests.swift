import XCTest
@testable import MeetingTranscriber

final class SessionRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-record-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Faixa de pipeline (F9)

    func testPipelineInsideSupportedRangeIsAccepted() {
        XCTAssertNil(PipelineGuard.blockingMessage(forVersion: "0.10.0"))
        XCTAssertNil(PipelineGuard.blockingMessage(forVersion: "0.10.7"))
    }

    func testPipelineOutsideRangeBlocksWithAMessage() {
        for version in ["0.9.1", "0.11.0", "1.0.0"] {
            let message = PipelineGuard.blockingMessage(forVersion: version)
            XCTAssertNotNil(message, version)
            XCTAssertTrue(message?.contains("fora da faixa suportada") == true)
            XCTAssertTrue(message?.contains("áudio foi preservado") == true)
        }
        XCTAssertNotNil(PipelineGuard.blockingMessage(forVersion: nil))
        XCTAssertNotNil(PipelineGuard.blockingMessage(forVersion: "abc"))
    }

    // MARK: Manifest v2 (F7)

    func testRecordSurvivesSaveAndLoad() throws {
        let store = SessionStore(rootDirectory: root)
        let id = UUID()
        var record = SessionRecord.starting(at: Date(timeIntervalSince1970: 1_000))
        record.stopReason = "user"
        record.asrAttempts = [ASRAttempt(startedAt: Date(timeIntervalSince1970: 2_000), endedAt: nil, exitCode: nil, pausedSeconds: 3.5, overlappedRecording: true)]
        _ = try store.prepareRecording(
            id: id, title: "t", language: "pt", outputDirectory: root,
            createdAt: Date(timeIntervalSince1970: 1_000), record: record
        )
        let loaded = try XCTUnwrap(store.loadJobs().first { $0.id == id })
        XCTAssertEqual(loaded.record?.recordingStartedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(loaded.record?.asrAttempts.first?.pausedSeconds, 3.5)
        // O diário já escrito sobrevive a um app morto antes do stop.
        XCTAssertNotNil(loaded.record?.appVersion)
    }

    func testV1ManifestLoadsWithoutRecord() throws {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"captureIntegrity":{"details":[],"status":"complete"},"createdAt":"2026-10-01T12:00:00Z",
         "exportedToSecondBrain":false,"hidden":false,"id":"\(id.uuidString)","language":"pt",
         "outputDirectory":"\(root.path)","progress":0,"schemaVersion":1,"state":"queued",
         "sysOffsetMs":0,"title":"t"}
        """
        try json.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let job = try XCTUnwrap(SessionStore(rootDirectory: root).loadJobs().first)
        XCTAssertNil(job.record)
        XCTAssertNil(job.captureIntegrity.measured)
    }

    func testLoadingJobsDoesNotRewriteOldManifests() throws {
        let store = SessionStore(rootDirectory: root)
        let id = UUID()
        _ = try store.prepareRecording(id: id, title: "t", language: "pt", outputDirectory: root, createdAt: Date())
        // Uma sessão concluída e íntegra não muda de conteúdo ao reabrir o app.
        var job = try XCTUnwrap(store.loadJobs().first)
        job.status = .queued
        try store.save(job)
        let manifest = root.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")
        let before = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        _ = store.loadJobs()
        _ = store.loadJobs()
        let after = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    // MARK: Runner

    func testCaptureLossArgumentsListEachMeasuredInterval() {
        var integrity = CaptureIntegrity.degraded(["x"])
        integrity.measured = IntegrityReport(ruleVersion: 2, tracks: [
            "mic": TrackIntegrity(startDelayS: 6.7, trailingS: 0, gapsS: 3, lossS: 9.7, intervals: [
                LossInterval(kind: .start, atS: 0, durS: 6.7),
                LossInterval(kind: .gap, atS: 750.04, durS: 3),
            ]),
            "system": TrackIntegrity(startDelayS: 0.4, trailingS: 0, gapsS: 0, lossS: 0, intervals: []),
        ], sessionDurationS: 600)
        XCTAssertEqual(TranscriptionRunner.captureLossArguments(integrity), [
            "--capture-loss", "mic:start:0.0:6.7",
            "--capture-loss", "mic:gap:750.0:3.0",
        ])
        XCTAssertTrue(TranscriptionRunner.captureLossArguments(.complete).isEmpty)
    }

    func testPipelineLogKeepsTheTailUpToOneMegabyte() throws {
        let url = root.appendingPathComponent("s/pipeline.log")
        let text = String(repeating: "a", count: 2_000_000) + "FIM"
        TranscriptionRunner.writeLog(text, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 1_048_576)
        XCTAssertTrue(String(decoding: data.suffix(3), as: UTF8.self) == "FIM")
        TranscriptionRunner.writeLog("", to: root.appendingPathComponent("vazio.log"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("vazio.log").path))
    }
}
