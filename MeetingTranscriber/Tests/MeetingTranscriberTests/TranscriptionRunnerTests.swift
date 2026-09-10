import XCTest
@testable import MeetingTranscriber

final class TranscriptionRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-runner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStreamsProgressAndReturnsDeclaredOutput() async throws {
        let script = directory.appendingPathComponent("fake-transcriber.sh")
        let output = directory.appendingPathComponent("result.md")
        let jsonl = directory.appendingPathComponent("result.jsonl")
        let sessionID = UUID()
        let body = """
        #!/bin/sh
        printf 'PROGRESS: 10\\n'
        printf 'PROGRESS: 80\\n'
        printf '# result\\n' > '\(output.path)'
        printf '%s\\n' '{"type":"meta","session_id":"\(sessionID.uuidString)"}' > '\(jsonl.path)'
        printf 'Output: \(output.path)\\n'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let runner = TranscriptionRunner(python: "/bin/sh", script: script.path)
        let progress = ProgressRecorder()
        let result = try await runner.run(
            micURL: nil,
            systemURL: nil,
            title: "Teste",
            outputDir: directory,
            sessionID: sessionID,
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(result, output)
        XCTAssertEqual(progress.values, [10, 80])
    }

    func testNonzeroExitReturnsBoundedFailure() async throws {
        let script = directory.appendingPathComponent("failing-transcriber.sh")
        let body = """
        #!/bin/sh
        printf 'falha controlada\\n' >&2
        exit 7
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let runner = TranscriptionRunner(python: "/bin/sh", script: script.path)
        do {
            _ = try await runner.run(
                micURL: nil,
                systemURL: nil,
                title: "Teste",
                outputDir: directory
            )
            XCTFail("expected process failure")
        } catch let error as TranscriptionError {
            guard case .processFailed(let code, let detail) = error else {
                return XCTFail("unexpected transcription error: \(error)")
            }
            XCTAssertEqual(code, 7)
            XCTAssertTrue(detail.contains("falha controlada"))
        }
    }

    func testZeroExitWithMissingDeclaredFileIsRejected() async throws {
        let script = directory.appendingPathComponent("missing-output.sh")
        let output = directory.appendingPathComponent("missing.md")
        let body = """
        #!/bin/sh
        printf 'Output: \(output.path)\\n'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let runner = TranscriptionRunner(python: "/bin/sh", script: script.path)
        do {
            _ = try await runner.run(
                micURL: nil,
                systemURL: nil,
                title: "Teste",
                outputDir: directory
            )
            XCTFail("expected invalid output")
        } catch let error as TranscriptionError {
            guard case .invalidOutput = error else {
                return XCTFail("unexpected transcription error: \(error)")
            }
        }
    }

    func testZeroExitWithMissingCompanionJSONLIsRejected() async throws {
        let script = directory.appendingPathComponent("partial-output.sh")
        let output = directory.appendingPathComponent("partial.md")
        let body = """
        #!/bin/sh
        printf '# parcial\\n' > '\(output.path)'
        printf 'Output: \(output.path)\\n'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let runner = TranscriptionRunner(python: "/bin/sh", script: script.path)
        do {
            _ = try await runner.run(
                micURL: nil,
                systemURL: nil,
                title: "Teste",
                outputDir: directory
            )
            XCTFail("expected invalid companion")
        } catch let error as TranscriptionError {
            guard case .invalidOutput = error else {
                return XCTFail("unexpected transcription error: \(error)")
            }
        }
    }

    func testCancellationReturnsOnlyAfterProcessTerminates() async throws {
        let script = directory.appendingPathComponent("cancellable.sh")
        let started = directory.appendingPathComponent("started")
        let terminated = directory.appendingPathComponent("terminated")
        let body = """
        #!/bin/sh
        trap "printf stopped > '\(terminated.path)'; exit 143" TERM
        printf started > '\(started.path)'
        while true; do sleep 1; done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let runner = TranscriptionRunner(python: "/bin/sh", script: script.path)
        let task = Task {
            try await runner.run(
                micURL: nil,
                systemURL: nil,
                title: "Teste",
                outputDir: directory
            )
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))

        runner.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as TranscriptionError {
            guard case .cancelled = error else {
                return XCTFail("unexpected transcription error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminated.path))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] { lock.withLock { storage } }

    func append(_ value: Int) {
        lock.withLock { storage.append(value) }
    }
}
