import XCTest
@testable import Manas

@MainActor
final class UsageAnalyticsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "UsageAnalyticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeAnalytics(defaults: UserDefaults) -> UsageAnalytics {
        UsageAnalytics(
            defaults: defaults,
            projectToken: "phc_test_public_project_token",
            sender: { _ in }
        )
    }

    func testCollectionIsOffUntilExplicitConsent() {
        let defaults = makeDefaults()
        let analytics = makeAnalytics(defaults: defaults)

        XCTAssertFalse(analytics.isEnabled)
        XCTAssertFalse(analytics.hasAskedForConsent)
        XCTAssertNil(analytics.request(for: .appOpened))

        analytics.setEnabled(true)

        XCTAssertTrue(analytics.isEnabled)
        XCTAssertTrue(analytics.hasAskedForConsent)
        XCTAssertNotNil(analytics.request(for: .appOpened))
    }

    func testTodoEventContainsOnlyCoarseAllowlistedProperties() throws {
        let analytics = makeAnalytics(defaults: makeDefaults())
        analytics.setEnabled(true)

        let request = try XCTUnwrap(analytics.request(
            for: .todoCreated(day: .future, hasGroup: true),
            timestamp: Date(timeIntervalSince1970: 1_752_000_000)
        ))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "manas_todo_created")
        XCTAssertEqual(properties["day"] as? String, "future")
        XCTAssertEqual(properties["has_group"] as? Bool, true)
        XCTAssertEqual(properties["product"] as? String, "manas")
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        XCTAssertNil(properties["text"])
        XCTAssertNil(properties["group"])
        XCTAssertNil(properties["phone"])
        XCTAssertNil(properties["email"])
        XCTAssertNil(properties["url"])
    }

    func testOptOutStopsCaptureAndRotatesAnonymousIdentifier() throws {
        let analytics = makeAnalytics(defaults: makeDefaults())
        analytics.setEnabled(true)
        let first = try distinctID(in: XCTUnwrap(analytics.request(for: .appOpened)))

        analytics.setEnabled(false)
        XCTAssertNil(analytics.request(for: .appOpened))

        analytics.setEnabled(true)
        let second = try distinctID(in: XCTUnwrap(analytics.request(for: .appOpened)))
        XCTAssertNotEqual(first, second)
    }

    func testMissingProjectTokenDisablesConsentAndCapture() {
        let analytics = UsageAnalytics(
            defaults: makeDefaults(),
            projectToken: "",
            sender: { _ in }
        )

        XCTAssertFalse(analytics.isConfigured)
        XCTAssertFalse(analytics.shouldRequestConsent)
        analytics.setEnabled(true)
        XCTAssertFalse(analytics.isEnabled)
        XCTAssertNil(analytics.request(for: .appOpened))
    }

    func testCheckInFailureReasonIsACategoryAndNeverTheErrorText() throws {
        let analytics = makeAnalytics(defaults: makeDefaults())
        analytics.setEnabled(true)

        // stderr here is the shape of the thing that must not escape: the CLI
        // quotes the user's own todos back in its error output.
        let leaky = JudgeError.nonZeroExit(
            code: 1,
            stderr: "todo \"call mum about the flat\" could not be judged"
        )
        let request = try XCTUnwrap(analytics.request(
            for: .checkInFailed(automatic: true, reason: leaky.analyticsReason)
        ))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "manas_check_in_failed")
        XCTAssertEqual(properties["trigger"] as? String, "automatic")
        XCTAssertEqual(properties["reason"] as? String, "non_zero_exit")

        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertFalse(body.contains("call mum"))
        XCTAssertFalse(body.contains("flat"))
    }

    func testEveryJudgeErrorHasADistinctConstantReason() {
        let errors: [JudgeError] = [
            .cliNotFound,
            .launchFailed("boom"),
            .nonZeroExit(code: 1, stderr: "boom"),
            .timedOut(seconds: 900),
            .malformedCLIOutput("boom"),
            .malformedModelOutput("boom"),
            .cliReportedError("boom"),
        ]
        let reasons = errors.map(\.analyticsReason)

        XCTAssertEqual(Set(reasons).count, errors.count, "reasons must distinguish the cases")
        for reason in reasons {
            XCTAssertFalse(reason.contains("boom"), "\(reason) interpolated the payload")
            XCTAssertFalse(reason.isEmpty)
        }
    }

    private func distinctID(in request: URLRequest) throws -> String {
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        return try XCTUnwrap(json["distinct_id"] as? String)
    }
}
