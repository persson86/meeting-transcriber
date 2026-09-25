import XCTest
@testable import MeetingTranscriber

final class AppVersionTests: XCTestCase {
    func testReadsPipelineVersionDeclaredInScript() {
        let source = "import os\n\nPIPELINE_VERSION = \"0.9.0\"\nOTHER = \"1\"\n"
        XCTAssertEqual(AppVersion.pipelineVersion(in: source), "0.9.0")
    }

    func testIgnoresScriptWithoutVersionOrMissingFile() {
        XCTAssertNil(AppVersion.pipelineVersion(in: "# PIPELINE_VERSION = \"x\" só em comentário\n"))
        XCTAssertNil(AppVersion.pipelineVersion(atPath: "/nonexistent/transcribe_meeting.py"))
    }

    func testPipelineVersionOfThisCheckoutIsReadable() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("transcribe_meeting.py")
        XCTAssertNotNil(AppVersion.pipelineVersion(atPath: script.path))
    }
}
