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

    private func distinctID(in request: URLRequest) throws -> String {
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        return try XCTUnwrap(json["distinct_id"] as? String)
    }
}
