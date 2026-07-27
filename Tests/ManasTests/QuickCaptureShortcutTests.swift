import XCTest
@testable import Manas

final class QuickCaptureShortcutTests: XCTestCase {
    func testTwoCapsLockTapsWithinWindowTriggerOnce() {
        var detector = DoubleTapDetector(maximumInterval: 0.45)

        XCTAssertFalse(detector.registerTap(at: 10))
        XCTAssertTrue(detector.registerTap(at: 10.4))
        XCTAssertNil(detector.firstTapAt)
    }

    func testSlowSecondTapStartsANewPair() {
        var detector = DoubleTapDetector(maximumInterval: 0.45)

        XCTAssertFalse(detector.registerTap(at: 10))
        XCTAssertFalse(detector.registerTap(at: 10.6))
        XCTAssertEqual(detector.firstTapAt, 10.6)
        XCTAssertTrue(detector.registerTap(at: 10.9))
    }

    func testThirdTapDoesNotRetriggerPreviousPair() {
        var detector = DoubleTapDetector(maximumInterval: 0.45)

        XCTAssertFalse(detector.registerTap(at: 10))
        XCTAssertTrue(detector.registerTap(at: 10.2))
        XCTAssertFalse(detector.registerTap(at: 10.3))
    }

    func testOutOfOrderTimestampRestartsPair() {
        var detector = DoubleTapDetector(maximumInterval: 0.45)

        XCTAssertFalse(detector.registerTap(at: 10))
        XCTAssertFalse(detector.registerTap(at: 9))
        XCTAssertEqual(detector.firstTapAt, 9)
    }
}
