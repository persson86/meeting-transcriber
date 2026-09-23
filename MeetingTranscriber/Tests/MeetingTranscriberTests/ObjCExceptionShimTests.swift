import XCTest
import ObjCExceptionCatcher
@testable import MeetingTranscriber

/// O rearme do microfone depende do shim: uma NSException do AVAudioEngine
/// precisa virar erro Swift em vez de abortar o app (crash de 16/set).
final class ObjCExceptionShimTests: XCTestCase {
    func testObjCExceptionBecomesSwiftError() {
        XCTAssertThrowsError(try MTObjCExceptionCatcher.raiseTestException(withReason: "required condition is false")) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, MTObjCExceptionErrorDomain)
            XCTAssertEqual(nsError.userInfo[MTObjCExceptionReasonKey] as? String, "required condition is false")
        }
    }

    func testPerformRunsBlockWithoutError() throws {
        var ran = false
        try MTObjCExceptionCatcher.perform { ran = true }
        XCTAssertTrue(ran)
    }
}
