import Foundation
import XCTest
@testable import Manas

private struct StubSource: ActivitySource {
    let name: String
    let activities: [WorkActivity]
    let error: (any Error)?
    /// Delay lets tests exercise genuinely concurrent completion.
    let delay: Duration

    init(name: String, activities: [WorkActivity] = [], error: (any Error)? = nil, delay: Duration = .zero) {
        self.name = name
        self.activities = activities
        self.error = error
        self.delay = delay
    }

    func fetchActivities(for date: Date) async throws -> [WorkActivity] {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
        return activities
    }
}

private struct StubError: Error {}

final class ActivityAggregatorTests: XCTestCase {
    private let day = IngestionFixtures.day

    private func activity(summary: String, startingAt iso: String, source: WorkSource = .claude) -> WorkActivity {
        WorkActivity(source: source, summary: summary, startedAt: IngestionFixtures.date(iso))
    }

    func testMergesConcurrentSourcesSortedByStartTime() async {
        let aggregator = ActivityAggregator(sources: [
            StubSource(
                name: "Claude Code",
                activities: [activity(summary: "afternoon work", startingAt: "2026-07-10T15:00:00Z")],
                delay: .milliseconds(30)
            ),
            StubSource(
                name: "Codex",
                activities: [activity(summary: "morning work", startingAt: "2026-07-10T09:00:00Z", source: .codex)]
            ),
        ])

        let result = await aggregator.fetchActivities(for: day)

        XCTAssertEqual(result.syncedSourceCount, 2)
        XCTAssertEqual(result.failedSourceNames, [])
        XCTAssertEqual(result.activities.map(\.summary), ["morning work", "afternoon work"])
    }

    func testDegradesGracefullyWhenOneSourceFails() async {
        let aggregator = ActivityAggregator(sources: [
            StubSource(name: "Claude Code", activities: [activity(summary: "real work", startingAt: "2026-07-10T10:00:00Z")]),
            StubSource(name: "Codex", error: StubError()),
            StubSource(name: "Granola", activities: []),
        ])

        let result = await aggregator.fetchActivities(for: day)

        // The empty-but-successful source still counts as synced.
        XCTAssertEqual(result.syncedSourceCount, 2)
        XCTAssertEqual(result.failedSourceNames, ["Codex"])
        XCTAssertEqual(result.activities.map(\.summary), ["real work"])
    }

    func testAllSourcesFailingStillReturnsAResult() async {
        let aggregator = ActivityAggregator(sources: [
            StubSource(name: "Claude Code", error: StubError()),
            StubSource(name: "Codex", error: StubError()),
        ])

        let result = await aggregator.fetchActivities(for: day)

        XCTAssertEqual(result.syncedSourceCount, 0)
        XCTAssertEqual(result.failedSourceNames, ["Claude Code", "Codex"])
        XCTAssertEqual(result.activities, [])
    }

    func testNoSources() async {
        let result = await ActivityAggregator(sources: []).fetchActivities(for: day)
        XCTAssertEqual(result, AggregatedActivities())
    }

    func testStandardLineupCoversClaudeAndCodex() {
        XCTAssertEqual(ActivityAggregator.standard.sources.map(\.name), ["Claude Code", "Codex"])
    }
}
