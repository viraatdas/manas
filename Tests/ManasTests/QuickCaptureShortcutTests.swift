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

/// The Accessibility grant behind the Caps Lock shortcut, and what happens to
/// it across an update.
@MainActor
final class QuickCaptureAccessibilityTests: XCTestCase {
    private let suite = "manas.tests.quickcapture.accessibility"

    private func scratchDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// The bug this guards: macOS drops an Accessibility grant when the app's
    /// signature changes, which is what every Sparkle update does. The prompt
    /// had already fired once and was recorded forever, so it never fired
    /// again — and a global event monitor without trust is silent rather than
    /// failing, so Caps Lock simply stopped working with nothing to explain it.
    func testAnUpdateThatCostsTheGrantLetsTheAppAskAgain() {
        let defaults = scratchDefaults()
        let controller = QuickCaptureShortcutController()
        let promptKey = QuickCaptureShortcutController.permissionPromptKey

        controller.rearmPromptIfTrustWasLost(defaults, trusted: true)
        defaults.set(true, forKey: promptKey)

        controller.rearmPromptIfTrustWasLost(defaults, trusted: false)

        XCTAssertFalse(
            defaults.bool(forKey: promptKey),
            "losing a grant we used to hold has to re-arm the prompt, or the shortcut is dead for good"
        )
    }

    /// The other half: someone who has never granted it should not be asked on
    /// every launch. Only a grant that existed and then vanished re-arms.
    func testNeverHavingGrantedItDoesNotNagOnEveryLaunch() {
        let defaults = scratchDefaults()
        let controller = QuickCaptureShortcutController()
        let promptKey = QuickCaptureShortcutController.permissionPromptKey

        defaults.set(true, forKey: promptKey)
        controller.rearmPromptIfTrustWasLost(defaults, trusted: false)

        XCTAssertTrue(
            defaults.bool(forKey: promptKey),
            "a declined prompt should stay declined until a grant is actually seen"
        )
    }

    /// Granting it records the fact, which is what makes a later loss legible.
    func testGrantingItIsRemembered() {
        let defaults = scratchDefaults()
        let controller = QuickCaptureShortcutController()

        controller.rearmPromptIfTrustWasLost(defaults, trusted: true)

        XCTAssertTrue(defaults.bool(forKey: QuickCaptureShortcutController.grantedBeforeKey))
    }
}
